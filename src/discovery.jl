using Logging

const DEFAULT_DISCOVERY_PATHS = DEFAULT_MANIFEST_PATHS

const DISCOVERY_TIMEOUT = (connecttimeout=10, readtimeout=20)

function discover_server(
    base_url::AbstractString;
    path::Union{Nothing,AbstractString}=nothing,
    headers=nothing,
    http=HTTP,
    verbose::Bool=false,
)
    ensure_http_url(base_url, "base_url")
    header_pairs = normalize_headers(headers)
    manifest, manifest_url = fetch_manifest(
        base_url;
        path=path,
        headers=header_pairs,
        http=http,
        verbose=verbose,
    )
    transports, preferred = parse_transports(manifest, manifest_url)
    return MCPDiscovery(
        manifest=manifest,
        transports=transports,
        default_transport=preferred,
    )
end

function fetch_manifest(
    base_url::AbstractString;
    path,
    headers::Vector{HeaderPair},
    http::Module,
    verbose::Bool,
)
    candidates = path === nothing ? DEFAULT_DISCOVERY_PATHS : (path,)
    last_error = nothing
    for candidate in candidates
        request_url = is_absolute_http_url(candidate) ? String(candidate) : absolute_url(base_url, String(candidate))
        try
            manifest = perform_manifest_request(request_url, headers; http=http, verbose=verbose)
            manifest === nothing && continue
            return manifest, request_url
        catch err
            if err isa MCPAuthenticationRequired
                rethrow(err)
            elseif err isa MCPError
                last_error = err
            else
                last_error = MCPError(:discovery_error, sprint(showerror, err))
            end
        end
    end
    last_error === nothing && throw(mcp_error(:discovery_failed, "Unable to discover MCP manifest at $(base_url)"))
    throw(last_error)
end

function perform_manifest_request(url::String, headers::Vector{HeaderPair}; http::Module, verbose::Bool)
    request_headers = build_headers(headers)
    if verbose
        printable_request = HTTP.Request("GET", url, headers_to_pairs(request_headers), "")
        println("MCP discovery HTTP request:")
        println(printable_request)
    end
    response = http.request("GET", url; headers=request_headers, status_exception=false, DISCOVERY_TIMEOUT...)
    if verbose
        body_text = try
            String(response.body)
        catch err
            string("(unavailable: ", sprint(showerror, err), ")")
        end
        header_pairs = headers_to_pairs(response.headers)
        printable_response = HTTP.Response(response.status, header_pairs, body_text)
        println("MCP discovery HTTP response:")
        println(printable_response)
    end
    status = response.status
    if status in 200:299
        return parse_manifest_body(response.body)
    elseif status == 401
        challenges = extract_auth_challenges(response.headers)
        body = String(response.body)
        throw(MCPAuthenticationRequired(status, challenges, isempty(body) ? nothing : body))
    elseif status in (404, 405)
        return nothing
    else
        throw(mcp_error(:http_error, "Discovery request to $(url) failed with status $(status)"))
    end
end

function parse_manifest_body(body)
    data = JSON.parse(String(body))
    data isa AbstractDict || throw(mcp_error(:json_error, "Manifest response must be a JSON object"))
    manifest = JSONDict()
    for (k, v) in data
        manifest[String(k)] = v
    end
    return manifest
end

function parse_transports(manifest::JSONDict, manifest_url::String)
    transports = MCPTransportDescriptor[]
    preferred = nothing
    for entry in collect_transport_entries(manifest)
        descriptor = maybe_transport_descriptor(entry, manifest_url)
        descriptor === nothing && continue
        push!(transports, descriptor)
        if preferred === nothing && transport_preferred(entry)
            preferred = descriptor
        end
    end
    isempty(transports) && throw(mcp_error(:transport_missing, "Manifest does not include any MCP transports"))
    preferred === nothing && (preferred = first(transports))
    return transports, preferred
end

function collect_transport_entries(manifest::JSONDict)
    entries = Any[]
    if haskey(manifest, "model_context_protocols")
        push!(entries, manifest["model_context_protocols"])
    end
    if haskey(manifest, "model_context_protocol")
        push!(entries, manifest["model_context_protocol"])
    end
    if haskey(manifest, "model_context")
        block = manifest["model_context"]
        if block isa AbstractDict
            haskey(block, "transport") && push!(entries, block["transport"])
            haskey(block, "transports") && push!(entries, block["transports"])
        end
    end
    normalized = Any[]
    for entry in entries
        append!(normalized, normalize_entry(entry))
    end
    return normalized
end

function normalize_entry(entry)
    if entry isa AbstractVector
        normalized = Any[]
        for item in entry
            append!(normalized, normalize_entry(item))
        end
        return normalized
    elseif entry isa AbstractDict
        return [entry]
    else
        return Any[]
    end
end

function maybe_transport_descriptor(entry, manifest_url::String)
    entry isa AbstractDict || return nothing
    transport_block = entry
    if haskey(entry, "transport") && entry["transport"] isa AbstractDict
        transport_block = entry["transport"]
    end
    url_value = find_string(transport_block, ("url", "endpoint", "uri", "base_url", "address"))
    url_value === nothing && return nothing
    url = String(url_value)
    transport_url = is_absolute_http_url(url) ? url : absolute_url(manifest_url, url)
    ensure_http_url(transport_url, "transport url")
    protocol_value = find_string(entry, ("protocol", "protocol_version", "model_context_protocol"))
    version_value = find_string(entry, ("version", "protocol_version", "schema_version"))
    serialization_value = find_string(transport_block, ("serialization", "encoding", "content_type"))
    capabilities = collect_strings(fetch_value(entry, "capabilities"))
    raw = to_json_dict(entry)
    descriptor = MCPTransportDescriptor(
        kind=infer_transport_kind(transport_block, entry),
        url=transport_url,
        protocol=protocol_value === nothing ? nothing : String(protocol_value),
        version=version_value === nothing ? nothing : String(version_value),
        serialization=serialization_value === nothing ? nothing : String(serialization_value),
        capabilities=capabilities,
        raw=raw,
    )
    return descriptor
end

function infer_transport_kind(block::AbstractDict, parent::AbstractDict)
    value = find_string(block, ("kind", "type", "transport", "name"))
    value === nothing && (value = find_string(parent, ("kind", "type", "transport", "name")))
    value === nothing && return :http
    token = lowercase(String(value))
    token in ("https", "http") && return :http
    token in ("sse", "eventsource") && return :sse
    token in ("ws", "wss", "websocket") && return :websocket
    return Symbol(token)
end

function transport_preferred(entry)
    for key in ("default", "primary", "preferred")
        value = fetch_value(entry, key)
        if value isa Bool
            value && return true
        elseif value isa AbstractString
            lowered = lowercase(String(value))
            lowered in ("true", "yes", "1") && return true
        end
    end
    return false
end

function find_string(data, keys::Tuple)
    for key in keys
        value = fetch_value(data, key)
        value isa AbstractString && return value
    end
    return nothing
end

function fetch_value(data, key)
    data isa AbstractDict || return nothing
    if haskey(data, key)
        return data[key]
    end
    if key isa String
        sym = Symbol(key)
        haskey(data, sym) && return data[sym]
    elseif key isa Symbol
        str = String(key)
        haskey(data, str) && return data[str]
    end
    return nothing
end
