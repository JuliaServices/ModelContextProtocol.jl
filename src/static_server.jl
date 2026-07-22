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
        haskey(indices, tool.name) &&
            throw(ArgumentError("Duplicate static MCP tool name: $(tool.name)"))
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

const StaticJSONRPCID = Union{String,Int64,Nothing}

@defaults struct StaticJSONRPCRequest
    jsonrpc::String=""
    id::StaticJSONRPCID=nothing
    method::String=""
end

struct StaticToolCallParams
    name::String
    arguments::JSON.JSONText
end

# StructUtils' trim-specialized tier is available on newer releases and on
# applications that pin its trim branch. Keep this package compatible with
# older supported StructUtils versions while opting these parser DTOs into the
# concrete tier whenever the host environment provides it.
if isdefined(StructUtils, Symbol("@hot"))
    @eval StructUtils.@hot StaticJSONRPCRequest
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
_static_id_json(id::Int64)::String = string(id)

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

function _static_tool_call_params(body::String)::StaticToolCallParams
    params = JSON.lazy(body)["params"]
    name = JSON.parse(params["name"], String)
    arguments = try
        JSON.parse(params["arguments"], JSON.JSONText)
    catch err
        err isa KeyError || rethrow()
        JSON.JSONText("{}")
    end
    return StaticToolCallParams(name, arguments)
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
    print(io, "}],\"structuredContent\":", result.structured_content.value)
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
    rpc = try
        JSON.parse(body, StaticJSONRPCRequest)
    catch
        return _static_response(400, _static_error(nothing, -32700, "Invalid JSON-RPC request"))
    end
    rpc.jsonrpc == "2.0" ||
        return _static_response(400, _static_error(rpc.id, -32600, "jsonrpc must be 2.0"))

    if rpc.method == "initialize"
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
        session.initialized = true
        return HTTP.Response(202, Pair{String,String}[], UInt8[])
    elseif !session.initialized
        return _static_response(
            400,
            _static_error(rpc.id, -32002, "MCP session is not initialized"),
        )
    elseif rpc.method == "ping"
        return _static_response(200, _static_success(rpc.id, "{}"))
    elseif rpc.method == "tools/list"
        return _static_response(200, _static_success(rpc.id, _static_tools_result(server)))
    elseif rpc.method == "tools/call"
        params = try
            _static_tool_call_params(body)
        catch
            return _static_response(200, _static_error(rpc.id, -32602, "Invalid tool arguments"))
        end
        index = get(server.tool_indices, params.name, 0)
        index == 0 &&
            return _static_response(200, _static_error(rpc.id, -32602, "Unknown tool"))
        context = StaticMCPRequestContext(request=req, session_id=session_id)
        result = server.tools[index].handler(context, params.arguments)
        return _static_response(200, _static_success(rpc.id, _static_tool_result(result)))
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
