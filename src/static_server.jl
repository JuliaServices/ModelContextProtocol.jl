const STATIC_MCP_SESSION_HEADER = "MCP-Session-Id"
const STATIC_MCP_PROTOCOL_HEADER = "MCP-Protocol-Version"

"A raw-JSON tool result for the statically dispatchable MCP server."
Base.@kwdef struct StaticMCPToolResult
    text::String
    structured_content::JSON.JSONText=JSON.JSONText("null")
    is_error::Bool=false
end

"Request context passed to a static MCP tool handler."
Base.@kwdef struct StaticMCPRequestContext
    request::HTTP.Request
    session_id::String
end

"A tool whose handler has a concrete callable type."
Base.@kwdef struct StaticMCPTool{H}
    name::String
    handler::H
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    input_schema::JSON.JSONText=JSON.JSONText("{\"type\":\"object\"}")
    annotations::JSON.JSONText=JSON.JSONText("{}")
end

Base.@kwdef mutable struct StaticMCPSession
    id::String
    initialized::Bool=false
end

"A tools-only MCP server whose entire request graph has concrete types."
mutable struct StaticMCPServer{H}
    name::String
    version::String
    description::Union{String,Nothing}
    instructions::Union{String,Nothing}
    protocol_version::String
    tools::Vector{StaticMCPTool{H}}
    tool_indices::Dict{String,Int}
    sessions::Dict{String,StaticMCPSession}
    lock::ReentrantLock
end

function StaticMCPServer(
    tools::Vector{StaticMCPTool{H}};
    name::AbstractString,
    version::AbstractString,
    description::Union{AbstractString,Nothing}=nothing,
    instructions::Union{AbstractString,Nothing}=nothing,
    protocol_version::AbstractString=DEFAULT_PROTOCOL_VERSION,
) where {H}
    isempty(tools) && throw(ArgumentError("A static MCP server requires at least one tool"))
    indices = Dict{String,Int}()
    for index in eachindex(tools)
        tool = tools[index]
        isempty(tool.name) && throw(ArgumentError("A static MCP tool name cannot be empty"))
        haskey(indices, tool.name) &&
            throw(ArgumentError("Duplicate static MCP tool name: $(tool.name)"))
        _static_is_json_object(tool.input_schema.value) ||
            throw(ArgumentError("Static MCP tool input_schema must be a JSON object"))
        _static_is_json_object(tool.annotations.value) ||
            throw(ArgumentError("Static MCP tool annotations must be a JSON object"))
        indices[tool.name] = index
    end
    return StaticMCPServer{H}(
        String(name),
        String(version),
        description === nothing ? nothing : String(description),
        instructions === nothing ? nothing : String(instructions),
        String(protocol_version),
        tools,
        indices,
        Dict{String,StaticMCPSession}(),
        ReentrantLock(),
    )
end

struct StaticJSONRPCNumberID
    value::String
end

const StaticJSONRPCID = Union{String,StaticJSONRPCNumberID,Nothing}

"Parsed JSON-RPC envelope; params is retained as a raw byte offset into the body."
struct StaticJSONRPCRequest
    ok::Bool
    jsonrpc::String
    has_id::Bool
    id::StaticJSONRPCID
    has_method::Bool
    method::String
    params_start::Int
end

const _STATIC_PARSE_ERROR = StaticJSONRPCRequest(false, "", false, nothing, false, "", 0)

# --- minimal hand-rolled JSON scanning --------------------------------------
# The static server scans requests itself instead of using JSON.lazy/typed
# parse: those paths reach Parsers' recursive float parsing and repr()-based
# error formatting, neither of which is trim-verifiable.

_static_is_ws(b::UInt8) = b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r')

function _static_skip_ws(s::String, i::Int)::Int
    n = ncodeunits(s)
    while i <= n && _static_is_ws(codeunit(s, i))
        i += 1
    end
    return i
end

_static_is_utf8_continuation(b::UInt8) = 0x80 <= b <= 0xbf

# Return the index after one valid non-ASCII UTF-8 scalar, or 0 on error.
function _static_utf8_end(s::String, i::Int)::Int
    n = ncodeunits(s)
    i <= n || return 0
    b = codeunit(s, i)
    if 0xc2 <= b <= 0xdf
        i + 1 <= n && _static_is_utf8_continuation(codeunit(s, i + 1)) || return 0
        return i + 2
    elseif 0xe0 <= b <= 0xef
        i + 2 <= n || return 0
        b2 = codeunit(s, i + 1)
        b3 = codeunit(s, i + 2)
        second_valid = if b == 0xe0
            0xa0 <= b2 <= 0xbf
        elseif b == 0xed
            0x80 <= b2 <= 0x9f
        else
            _static_is_utf8_continuation(b2)
        end
        second_valid && _static_is_utf8_continuation(b3) || return 0
        return i + 3
    elseif 0xf0 <= b <= 0xf4
        i + 3 <= n || return 0
        b2 = codeunit(s, i + 1)
        second_valid = if b == 0xf0
            0x90 <= b2 <= 0xbf
        elseif b == 0xf4
            0x80 <= b2 <= 0x8f
        else
            _static_is_utf8_continuation(b2)
        end
        second_valid || return 0
        _static_is_utf8_continuation(codeunit(s, i + 2)) || return 0
        _static_is_utf8_continuation(codeunit(s, i + 3)) || return 0
        return i + 4
    end
    return 0
end

# i points at the opening quote; returns the index just past the closing quote, or 0 on error
function _static_string_end(s::String, i::Int)::Int
    n = ncodeunits(s)
    (i <= n && codeunit(s, i) == UInt8('"')) || return 0
    i += 1
    while i <= n
        b = codeunit(s, i)
        if b == UInt8('"')
            return i + 1
        elseif b == UInt8('\\')
            i + 1 <= n || return 0
            e = codeunit(s, i + 1)
            if e in (UInt8('"'), UInt8('\\'), UInt8('/'), UInt8('b'), UInt8('f'), UInt8('n'), UInt8('r'), UInt8('t'))
                i += 2
            elseif e == UInt8('u')
                code = _static_hex4(s, i + 2)
                (code < 0 || 0xdc00 <= code <= 0xdfff) && return 0
                i += 6
                if 0xd800 <= code <= 0xdbff
                    (i + 1 <= n && codeunit(s, i) == UInt8('\\') && codeunit(s, i + 1) == UInt8('u')) || return 0
                    low = _static_hex4(s, i + 2)
                    0xdc00 <= low <= 0xdfff || return 0
                    i += 6
                end
            else
                return 0
            end
        elseif b < 0x20
            return 0
        elseif b < 0x80
            i += 1
        else
            i = _static_utf8_end(s, i)
            i == 0 && return 0
        end
    end
    return 0
end

function _static_hex_digit(b::UInt8)::Int
    UInt8('0') <= b <= UInt8('9') && return Int(b - UInt8('0'))
    UInt8('a') <= b <= UInt8('f') && return Int(b - UInt8('a')) + 10
    UInt8('A') <= b <= UInt8('F') && return Int(b - UInt8('A')) + 10
    return -1
end

# i points at the first of four hex digits; returns the code unit or -1 on error
function _static_hex4(s::String, i::Int)::Int
    i + 3 <= ncodeunits(s) || return -1
    code = 0
    for k in 0:3
        d = _static_hex_digit(codeunit(s, i + k))
        d < 0 && return -1
        code = code * 16 + d
    end
    return code
end

# i points at the opening quote; returns (unescaped value, index past closing quote), index 0 on error
function _static_scan_string(s::String, i::Int)::Tuple{String,Int}
    n = ncodeunits(s)
    io = IOBuffer()
    i += 1
    while i <= n
        b = codeunit(s, i)
        if b == UInt8('"')
            return String(take!(io)), i + 1
        elseif b == UInt8('\\')
            i + 1 <= n || return "", 0
            e = codeunit(s, i + 1)
            if e == UInt8('"')
                write(io, UInt8('"')); i += 2
            elseif e == UInt8('\\')
                write(io, UInt8('\\')); i += 2
            elseif e == UInt8('/')
                write(io, UInt8('/')); i += 2
            elseif e == UInt8('b')
                write(io, 0x08); i += 2
            elseif e == UInt8('f')
                write(io, 0x0c); i += 2
            elseif e == UInt8('n')
                write(io, UInt8('\n')); i += 2
            elseif e == UInt8('r')
                write(io, UInt8('\r')); i += 2
            elseif e == UInt8('t')
                write(io, UInt8('\t')); i += 2
            elseif e == UInt8('u')
                code = _static_hex4(s, i + 2)
                (code < 0 || 0xdc00 <= code <= 0xdfff) && return "", 0
                i += 6
                if 0xd800 <= code <= 0xdbff
                    (i + 1 <= n && codeunit(s, i) == UInt8('\\') && codeunit(s, i + 1) == UInt8('u')) || return "", 0
                    low = _static_hex4(s, i + 2)
                    (0xdc00 <= low <= 0xdfff) || return "", 0
                    code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00)
                    i += 6
                end
                print(io, Char(code))
            else
                return "", 0
            end
        elseif b < 0x20
            return "", 0
        elseif b < 0x80
            write(io, b)
            i += 1
        else
            next_i = _static_utf8_end(s, i)
            next_i == 0 && return "", 0
            while i < next_i
                write(io, codeunit(s, i))
                i += 1
            end
        end
    end
    return "", 0
end

function _static_number_end(s::String, i::Int)::Int
    n = ncodeunits(s)
    i <= n || return 0
    if codeunit(s, i) == UInt8('-')
        i += 1
        i <= n || return 0
    end
    if codeunit(s, i) == UInt8('0')
        i += 1
        i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9') && return 0
    elseif UInt8('1') <= codeunit(s, i) <= UInt8('9')
        i += 1
        while i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9')
            i += 1
        end
    else
        return 0
    end
    if i <= n && codeunit(s, i) == UInt8('.')
        i += 1
        (i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9')) || return 0
        while i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9')
            i += 1
        end
    end
    if i <= n && codeunit(s, i) in (UInt8('e'), UInt8('E'))
        i += 1
        if i <= n && codeunit(s, i) in (UInt8('+'), UInt8('-'))
            i += 1
        end
        (i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9')) || return 0
        while i <= n && UInt8('0') <= codeunit(s, i) <= UInt8('9')
            i += 1
        end
    end
    return i
end

function _static_literal_end(s::String, i::Int, lit::String)::Int
    len = ncodeunits(lit)
    i + len - 1 <= ncodeunits(s) || return 0
    for k in 1:len
        codeunit(s, i + k - 1) == codeunit(lit, k) || return 0
    end
    return i + len
end

# returns the index just past the value starting at (or after whitespace from) i, or 0 on error
function _static_value_end(s::String, i::Int, depth::Int=0)::Int
    depth <= 128 || return 0
    n = ncodeunits(s)
    i = _static_skip_ws(s, i)
    i <= n || return 0
    b = codeunit(s, i)
    if b == UInt8('"')
        return _static_string_end(s, i)
    elseif b == UInt8('{')
        i = _static_skip_ws(s, i + 1)
        i <= n || return 0
        codeunit(s, i) == UInt8('}') && return i + 1
        while true
            codeunit(s, i) == UInt8('"') || return 0
            i = _static_string_end(s, i)
            i == 0 && return 0
            i = _static_skip_ws(s, i)
            (i <= n && codeunit(s, i) == UInt8(':')) || return 0
            i = _static_value_end(s, i + 1, depth + 1)
            i == 0 && return 0
            i = _static_skip_ws(s, i)
            i <= n || return 0
            if codeunit(s, i) == UInt8(',')
                i = _static_skip_ws(s, i + 1)
                i <= n || return 0
            elseif codeunit(s, i) == UInt8('}')
                return i + 1
            else
                return 0
            end
        end
    elseif b == UInt8('[')
        i = _static_skip_ws(s, i + 1)
        i <= n || return 0
        codeunit(s, i) == UInt8(']') && return i + 1
        while true
            i = _static_value_end(s, i, depth + 1)
            i == 0 && return 0
            i = _static_skip_ws(s, i)
            i <= n || return 0
            if codeunit(s, i) == UInt8(',')
                i = _static_skip_ws(s, i + 1)
                i <= n || return 0
            elseif codeunit(s, i) == UInt8(']')
                return i + 1
            else
                return 0
            end
        end
    elseif b == UInt8('t')
        return _static_literal_end(s, i, "true")
    elseif b == UInt8('f')
        return _static_literal_end(s, i, "false")
    elseif b == UInt8('n')
        return _static_literal_end(s, i, "null")
    elseif b == UInt8('-') || UInt8('0') <= b <= UInt8('9')
        return _static_number_end(s, i)
    else
        return 0
    end
end

function _static_parse_request(s::String)::StaticJSONRPCRequest
    n = ncodeunits(s)
    i = _static_skip_ws(s, 1)
    (i <= n && codeunit(s, i) == UInt8('{')) || return _STATIC_PARSE_ERROR
    jsonrpc = ""
    has_id = false
    id::StaticJSONRPCID = nothing
    has_method = false
    method = ""
    params_start = 0
    has_jsonrpc = false
    has_params = false
    i = _static_skip_ws(s, i + 1)
    i <= n || return _STATIC_PARSE_ERROR
    if codeunit(s, i) == UInt8('}')
        _static_skip_ws(s, i + 1) == n + 1 || return _STATIC_PARSE_ERROR
        return StaticJSONRPCRequest(true, jsonrpc, has_id, id, has_method, method, params_start)
    end
    while true
        (i <= n && codeunit(s, i) == UInt8('"')) || return _STATIC_PARSE_ERROR
        key, i = _static_scan_string(s, i)
        i == 0 && return _STATIC_PARSE_ERROR
        i = _static_skip_ws(s, i)
        (i <= n && codeunit(s, i) == UInt8(':')) || return _STATIC_PARSE_ERROR
        i = _static_skip_ws(s, i + 1)
        i <= n || return _STATIC_PARSE_ERROR
        value_start = i
        if key == "jsonrpc"
            has_jsonrpc && return _STATIC_PARSE_ERROR
            has_jsonrpc = true
            codeunit(s, i) == UInt8('"') || return _STATIC_PARSE_ERROR
            jsonrpc, i = _static_scan_string(s, i)
            i == 0 && return _STATIC_PARSE_ERROR
        elseif key == "id"
            has_id && return _STATIC_PARSE_ERROR
            has_id = true
            b = codeunit(s, i)
            if b == UInt8('"')
                idstr, i = _static_scan_string(s, i)
                i == 0 && return _STATIC_PARSE_ERROR
                id = idstr
            elseif b == UInt8('n')
                i = _static_literal_end(s, i, "null")
                i == 0 && return _STATIC_PARSE_ERROR
                id = nothing
            else
                i = _static_number_end(s, i)
                i > value_start || return _STATIC_PARSE_ERROR
                id = StaticJSONRPCNumberID(String(SubString(s, value_start, i - 1)))
            end
        elseif key == "method"
            has_method && return _STATIC_PARSE_ERROR
            has_method = true
            codeunit(s, i) == UInt8('"') || return _STATIC_PARSE_ERROR
            method, i = _static_scan_string(s, i)
            i == 0 && return _STATIC_PARSE_ERROR
        else
            if key == "params"
                has_params && return _STATIC_PARSE_ERROR
                has_params = true
                codeunit(s, i) in (UInt8('{'), UInt8('[')) || return _STATIC_PARSE_ERROR
                params_start = i
            end
            i = _static_value_end(s, i)
            i == 0 && return _STATIC_PARSE_ERROR
        end
        i = _static_skip_ws(s, i)
        i <= n || return _STATIC_PARSE_ERROR
        if codeunit(s, i) == UInt8(',')
            i = _static_skip_ws(s, i + 1)
        elseif codeunit(s, i) == UInt8('}')
            _static_skip_ws(s, i + 1) == n + 1 || return _STATIC_PARSE_ERROR
            return StaticJSONRPCRequest(true, jsonrpc, has_id, id, has_method, method, params_start)
        else
            return _STATIC_PARSE_ERROR
        end
    end
end

function _static_is_json_object(s::String)::Bool
    i = _static_skip_ws(s, 1)
    i <= ncodeunits(s) && codeunit(s, i) == UInt8('{') || return false
    value_end = _static_value_end(s, i)
    return value_end != 0 && _static_skip_ws(s, value_end) == ncodeunits(s) + 1
end

function _static_is_json_null(s::String)::Bool
    i = _static_skip_ws(s, 1)
    value_end = _static_literal_end(s, i, "null")
    return value_end != 0 && _static_skip_ws(s, value_end) == ncodeunits(s) + 1
end

function _static_implementation_ok(s::String, start::Int)::Bool
    n = ncodeunits(s)
    (start <= n && codeunit(s, start) == UInt8('{')) || return false
    i = _static_skip_ws(s, start + 1)
    has_name = false
    has_version = false
    while i <= n && codeunit(s, i) != UInt8('}')
        codeunit(s, i) == UInt8('"') || return false
        key, i = _static_scan_string(s, i)
        i == 0 && return false
        i = _static_skip_ws(s, i)
        (i <= n && codeunit(s, i) == UInt8(':')) || return false
        i = _static_skip_ws(s, i + 1)
        i <= n || return false
        if key == "name" || key == "version"
            key == "name" && has_name && return false
            key == "version" && has_version && return false
            codeunit(s, i) == UInt8('"') || return false
            _, i = _static_scan_string(s, i)
            i == 0 && return false
            key == "name" ? (has_name = true) : (has_version = true)
        else
            i = _static_value_end(s, i)
            i == 0 && return false
        end
        i = _static_skip_ws(s, i)
        i <= n || return false
        if codeunit(s, i) == UInt8(',')
            i = _static_skip_ws(s, i + 1)
            (i <= n && codeunit(s, i) != UInt8('}')) || return false
        elseif codeunit(s, i) != UInt8('}')
            return false
        end
    end
    return i <= n && codeunit(s, i) == UInt8('}') && has_name && has_version
end

function _static_initialize_params(s::String, params_start::Int)::Bool
    params_start == 0 && return false
    n = ncodeunits(s)
    (params_start <= n && codeunit(s, params_start) == UInt8('{')) || return false
    i = _static_skip_ws(s, params_start + 1)
    has_protocol_version = false
    has_capabilities = false
    has_client_info = false
    while i <= n && codeunit(s, i) != UInt8('}')
        codeunit(s, i) == UInt8('"') || return false
        key, i = _static_scan_string(s, i)
        i == 0 && return false
        i = _static_skip_ws(s, i)
        (i <= n && codeunit(s, i) == UInt8(':')) || return false
        i = _static_skip_ws(s, i + 1)
        i <= n || return false
        if key == "protocolVersion"
            has_protocol_version && return false
            codeunit(s, i) == UInt8('"') || return false
            _, i = _static_scan_string(s, i)
            i == 0 && return false
            has_protocol_version = true
        elseif key == "capabilities"
            has_capabilities && return false
            codeunit(s, i) == UInt8('{') || return false
            value_end = _static_value_end(s, i)
            value_end == 0 && return false
            i = value_end
            has_capabilities = true
        elseif key == "clientInfo"
            has_client_info && return false
            _static_implementation_ok(s, i) || return false
            i = _static_value_end(s, i)
            i == 0 && return false
            has_client_info = true
        else
            i = _static_value_end(s, i)
            i == 0 && return false
        end
        i = _static_skip_ws(s, i)
        i <= n || return false
        if codeunit(s, i) == UInt8(',')
            i = _static_skip_ws(s, i + 1)
            (i <= n && codeunit(s, i) != UInt8('}')) || return false
        elseif codeunit(s, i) != UInt8('}')
            return false
        end
    end
    return i <= n && codeunit(s, i) == UInt8('}') &&
           has_protocol_version && has_capabilities && has_client_info
end

# Extracts params.name and raw params.arguments JSON from the request body.
# Returns (name, arguments); name == "" signals missing/invalid params.
function _static_tool_call_params(s::String, params_start::Int)::Tuple{String,JSON.JSONText}
    arguments = JSON.JSONText("{}")
    params_start == 0 && return "", arguments
    n = ncodeunits(s)
    i = params_start
    (i <= n && codeunit(s, i) == UInt8('{')) || return "", arguments
    name = ""
    i = _static_skip_ws(s, i + 1)
    i <= n || return "", arguments
    codeunit(s, i) == UInt8('}') && return name, arguments
    while true
        (i <= n && codeunit(s, i) == UInt8('"')) || return "", arguments
        key, i = _static_scan_string(s, i)
        i == 0 && return "", arguments
        i = _static_skip_ws(s, i)
        (i <= n && codeunit(s, i) == UInt8(':')) || return "", arguments
        i = _static_skip_ws(s, i + 1)
        i <= n || return "", arguments
        value_start = i
        if key == "name"
            codeunit(s, i) == UInt8('"') || return "", arguments
            name, i = _static_scan_string(s, i)
            i == 0 && return "", arguments
        elseif key == "arguments"
            codeunit(s, value_start) == UInt8('{') || return "", arguments
            i = _static_value_end(s, i)
            i == 0 && return "", arguments
            arguments = JSON.JSONText(s[value_start:i - 1])
        else
            i = _static_value_end(s, i)
            i == 0 && return "", arguments
        end
        i = _static_skip_ws(s, i)
        i <= n || return "", arguments
        if codeunit(s, i) == UInt8(',')
            i = _static_skip_ws(s, i + 1)
        elseif codeunit(s, i) == UInt8('}')
            return name, arguments
        else
            return "", arguments
        end
    end
end

function _static_write_json_string(io::IO, value::String)
    print(io, '"')
    for ch in value
        if ch == '"'
            print(io, "\\\"")
        elseif ch == '\\'
            print(io, "\\\\")
        elseif ch == '\b'
            print(io, "\\b")
        elseif ch == '\f'
            print(io, "\\f")
        elseif ch == '\n'
            print(io, "\\n")
        elseif ch == '\r'
            print(io, "\\r")
        elseif ch == '\t'
            print(io, "\\t")
        elseif UInt32(ch) < 0x20
            print(io, "\\u00")
            code = UInt8(ch)
            print(io, string(code >> 4; base=16))
            print(io, string(code & 0x0f; base=16))
        else
            print(io, ch)
        end
    end
    print(io, '"')
    return nothing
end

function _static_json_string(value::String)::String
    io = IOBuffer()
    _static_write_json_string(io, value)
    return String(take!(io))
end

function _static_response(
    status::Int,
    body::String;
    session_id::Union{String,Nothing}=nothing,
    protocol_version::Union{String,Nothing}=nothing,
)
    headers = Pair{String,String}["Content-Type" => "application/json"]
    session_id === nothing || push!(headers, STATIC_MCP_SESSION_HEADER => session_id)
    protocol_version === nothing ||
        push!(headers, STATIC_MCP_PROTOCOL_HEADER => protocol_version)
    return HTTP.Response(status, headers, Vector{UInt8}(codeunits(body)))
end

_static_id_json(::Nothing)::String = "null"
_static_id_json(id::String)::String = _static_json_string(id)
_static_id_json(id::StaticJSONRPCNumberID)::String = id.value

function _static_success(id::StaticJSONRPCID, result::String)::String
    id_json = _static_id_json(id)
    return string("{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"result\":", result, "}")
end

function _static_error(
    id::StaticJSONRPCID,
    code::Int,
    message::String,
)::String
    id_json = _static_id_json(id)
    return string(
        "{\"jsonrpc\":\"2.0\",\"id\":",
        id_json,
        ",\"error\":{\"code\":",
        code,
        ",\"message\":",
        _static_json_string(message),
        "}}",
    )
end

function _static_create_session!(server::StaticMCPServer)::StaticMCPSession
    session = StaticMCPSession(id=string(uuid4()))
    lock(server.lock)
    try
        server.sessions[session.id] = session
    finally
        unlock(server.lock)
    end
    return session
end

function _static_find_session(
    server::StaticMCPServer,
    session_id::String,
)::Union{StaticMCPSession,Nothing}
    lock(server.lock)
    try
        return get(server.sessions, session_id, nothing)
    finally
        unlock(server.lock)
    end
end

function _static_initialize_result(server::StaticMCPServer)::String
    io = IOBuffer()
    print(io, "{\"protocolVersion\":")
    _static_write_json_string(io, server.protocol_version)
    print(io, ",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":")
    _static_write_json_string(io, server.name)
    print(io, ",\"version\":")
    _static_write_json_string(io, server.version)
    print(io, '}')
    if server.description !== nothing
        print(io, ",\"description\":")
        _static_write_json_string(io, server.description::String)
    end
    if server.instructions !== nothing
        print(io, ",\"instructions\":")
        _static_write_json_string(io, server.instructions::String)
    end
    print(io, '}')
    return String(take!(io))
end

function _static_tools_result(server::StaticMCPServer)::String
    io = IOBuffer()
    print(io, "{\"tools\":[")
    for index in eachindex(server.tools)
        index == firstindex(server.tools) || print(io, ',')
        tool = server.tools[index]
        print(io, "{\"name\":")
        _static_write_json_string(io, tool.name)
        if tool.title !== nothing
            print(io, ",\"title\":")
            _static_write_json_string(io, tool.title::String)
        end
        if tool.description !== nothing
            print(io, ",\"description\":")
            _static_write_json_string(io, tool.description::String)
        end
        print(io, ",\"inputSchema\":", tool.input_schema.value)
        print(io, ",\"annotations\":", tool.annotations.value, '}')
    end
    print(io, "]}")
    return String(take!(io))
end

function _static_tool_result(result::StaticMCPToolResult)::String
    io = IOBuffer()
    print(io, "{\"content\":[{\"type\":\"text\",\"text\":")
    _static_write_json_string(io, result.text)
    print(io, "}]")
    if !_static_is_json_null(result.structured_content.value)
        _static_is_json_object(result.structured_content.value) ||
            error("Static MCP structured_content must be a JSON object or null")
        print(io, ",\"structuredContent\":", result.structured_content.value)
    end
    print(io, ",\"isError\":", result.is_error ? "true" : "false", '}')
    return String(take!(io))
end

function _static_session_id(req::HTTP.Request)::String
    return HTTP.header(req.headers, STATIC_MCP_SESSION_HEADER, "")
end

function _static_protocol_supported(server::StaticMCPServer, req::HTTP.Request)::Bool
    requested = HTTP.header(req.headers, STATIC_MCP_PROTOCOL_HEADER, "")
    return isempty(requested) || requested == server.protocol_version
end

function handle_static_jsonrpc_request(server::StaticMCPServer{H}, req::HTTP.Request) where {H}
    _static_protocol_supported(server, req) || return _static_response(
        400,
        _static_error(nothing, -32600, "Unsupported MCP protocol version"),
    )
    body = String(req.body)
    rpc = _static_parse_request(body)
    rpc.ok || return _static_response(400, _static_error(nothing, -32700, "Invalid JSON-RPC request"))
    rpc.jsonrpc == "2.0" ||
        return _static_response(400, _static_error(rpc.id, -32600, "jsonrpc must be 2.0"))
    rpc.has_method ||
        return _static_response(400, _static_error(rpc.id, -32600, "method is required"))

    if rpc.method == "initialize"
        rpc.has_id || return HTTP.Response(202)
        _static_initialize_params(body, rpc.params_start) ||
            return _static_response(200, _static_error(rpc.id, -32602, "Invalid initialize parameters"))
        session = _static_create_session!(server)
        body = _static_success(rpc.id, _static_initialize_result(server))
        return _static_response(
            200,
            body;
            session_id=session.id,
            protocol_version=server.protocol_version,
        )
    end

    session_id = _static_session_id(req)
    isempty(session_id) && return _static_response(
        400,
        _static_error(rpc.id, -32600, "MCP-Session-Id is required"),
    )
    session = _static_find_session(server, session_id)
    session === nothing && return _static_response(
        404,
        _static_error(rpc.id, -32600, "Unknown MCP session"),
    )

    if rpc.method == "notifications/initialized"
        rpc.has_id &&
            return _static_response(200, _static_error(rpc.id, -32600, "initialized must be a notification"))
        session.initialized = true
        return HTTP.Response(202, Pair{String,String}[], UInt8[])
    elseif !session.initialized
        return _static_response(
            400,
            _static_error(rpc.id, -32002, "MCP session is not initialized"),
        )
    elseif !rpc.has_id
        return HTTP.Response(202)
    elseif rpc.method == "ping"
        return _static_response(200, _static_success(rpc.id, "{}"))
    elseif rpc.method == "tools/list"
        return _static_response(200, _static_success(rpc.id, _static_tools_result(server)))
    elseif rpc.method == "tools/call"
        name, arguments = _static_tool_call_params(body, rpc.params_start)
        if isempty(name)
            return _static_response(200, _static_error(rpc.id, -32602, "Invalid tool arguments"))
        end
        index = get(server.tool_indices, name, 0)
        if index == 0
            return _static_response(200, _static_error(rpc.id, -32602, "Unknown tool"))
        end
        context = StaticMCPRequestContext(request=req, session_id=session_id)
        result_json = try
            result = server.tools[index].handler(context, arguments)
            _static_tool_result(result)
        catch err
            code = err isa ArgumentError ? -32602 : -32603
            message = err isa ArgumentError ? "Invalid tool arguments" : "Tool handler failed"
            return _static_response(200, _static_error(rpc.id, code, message))
        end
        return _static_response(200, _static_success(rpc.id, result_json))
    end

    return _static_response(200, _static_error(rpc.id, -32601, "Method not found"))
end

"Return 405 because the static tools server does not emit unsolicited messages."
function handle_static_stream_request(::StaticMCPServer, ::HTTP.Request)
    return HTTP.Response(405, ["Allow" => "POST, DELETE"], UInt8[])
end

function handle_static_session_delete(server::StaticMCPServer, req::HTTP.Request)
    session_id = _static_session_id(req)
    isempty(session_id) && return _static_response(
        400,
        _static_error(nothing, -32600, "MCP-Session-Id is required"),
    )
    deleted = false
    lock(server.lock)
    try
        deleted = pop!(server.sessions, session_id, nothing) !== nothing
    finally
        unlock(server.lock)
    end
    return deleted ? HTTP.Response(204) : HTTP.Response(404)
end
