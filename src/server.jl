using Logging
using Sockets
using UUIDs

struct MCPRequestContext
    server::MCPServer
    http_request::HTTP.Request
    method::String
    id::Any
    params::Any
    session::Union{MCPSession,Nothing}
    timeout_ms::Union{Int,Nothing}
end

struct MCPHTTPServer
    server::MCPServer
    router::HTTP.Router
    http::HTTP.Servers.Server
    host::String
    port::Int
end

canonical_transport_path(path::AbstractString) = startswith(path, "/") ? String(path) : string("/", path)

const MCP_LOG_LEVELS = ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
const DEFAULT_LOG_LEVEL = "info"
const MISSING_PROTOCOL_HEADER_BEHAVIORS = (:error, :warn, :ignore)

function normalize_missing_protocol_header_behavior(value)
    token =
        value isa Symbol ? String(value) :
        value isa AbstractString ? String(value) :
        throw(ArgumentError("missing_protocol_header must be provided as a Symbol or string"))
    normalized = Symbol(lowercase(token))
    normalized in MISSING_PROTOCOL_HEADER_BEHAVIORS ||
        throw(ArgumentError("missing_protocol_header must be one of :error, :warn, or :ignore (got $(value))"))
    return normalized
end

request_method_string(req::HTTP.Request) = try
    String(req.method)
catch
    string(req.method)
end

function request_target_string(req::HTTP.Request)
    target = req.target
    target === nothing && return ""
    try
        return String(target)
    catch
        return string(target)
    end
end

server_body_text(body) = body === nothing ? "" : body isa AbstractString ? String(body) : String(body)

function normalize_log_level(level)
    level === nothing && return DEFAULT_LOG_LEVEL
    lowered = lowercase(String(level))
    lowered == "warn" && return "warning"
    lowered == "trace" && return "debug"
    lowered in MCP_LOG_LEVELS || throw(mcp_error(:invalid_params, "Unsupported log level $(level)"))
    return lowered
end

function default_server_capabilities()
    return Dict{String,Any}()
end

function MCPServer(config::MCPServerConfig)
    capabilities = isempty(config.capabilities) ? default_server_capabilities() : copy(config.capabilities)
    info = isempty(config.server_info) ? Dict{String,Any}() : to_string_dict(config.server_info)
    haskey(info, "name") || (info["name"] = config.name)
    haskey(info, "version") || (info["version"] = config.version)
    transport_path = canonical_transport_path(config.transport_path)
    behavior = normalize_missing_protocol_header_behavior(config.missing_protocol_header)
    return MCPServer(
        config,
        transport_path,
        capabilities,
        info,
        Dict{String,MCPServerTool}(),
        Dict{String,MCPServerPrompt}(),
        Dict{String,MCPServerResource}(),
        Dict{String,MCPServerResourceTemplate}(),
        Dict{String,MCPSession}(),
        nothing,
        nothing,
        nothing,
        "info",
        behavior,
        nothing,
    )
end

function MCPServer(; kwargs...)
    config = MCPServerConfig(; kwargs...)
    return MCPServer(config)
end

function set_request_hook!(server::MCPServer, hook::Function)
    server.request_hook = hook
    return server
end

function set_request_hook!(hook::Function, server::MCPServer)
    return set_request_hook!(server, hook)
end

clear_request_hook!(server::MCPServer) = (server.request_hook = nothing; server)

function ensure_capability!(server::MCPServer, name::String)
    haskey(server.capabilities, name) || (server.capabilities[name] = Dict{String,Any}())
    return server.capabilities[name]
end

function set_cancellation_handler!(server::MCPServer, handler::Function)
    server.cancellation_handler = handler
    return server
end

clear_cancellation_handler!(server::MCPServer) = (server.cancellation_handler = nothing; server)

function set_cancellation_handler!(handler::Function, server::MCPServer)
    return set_cancellation_handler!(server, handler)
end

function ensure_logging_capability!(server::MCPServer)
    caps = ensure_capability!(server, "logging")
    caps isa AbstractDict || (server.capabilities["logging"] = Dict{String,Any}(); caps = server.capabilities["logging"])
    haskey(caps, "levels") || (caps["levels"] = MCP_LOG_LEVELS)
    caps["setLevel"] = true
    return caps
end

function set_logging_level!(server::MCPServer, level)
    normalized = normalize_log_level(level)
    server.logging_level = normalized
    return normalized
end

function set_logging_handler!(server::MCPServer, handler::Function; level=DEFAULT_LOG_LEVEL)
    ensure_logging_capability!(server)
    server.logging_handler = handler
    set_logging_level!(server, level)
    return server
end

function set_logging_handler!(handler::Function, server::MCPServer; level=DEFAULT_LOG_LEVEL)
    return set_logging_handler!(server, handler; level=level)
end

function clear_logging_handler!(server::MCPServer)
    server.logging_handler = nothing
    server.logging_level = DEFAULT_LOG_LEVEL
    return server
end

function ensure_completion_capability!(server::MCPServer)
    caps = ensure_capability!(server, "completions")
    caps isa AbstractDict || (server.capabilities["completions"] = Dict{String,Any}(); caps = server.capabilities["completions"])
    caps["structured"] = true
    return caps
end

function set_completion_handler!(server::MCPServer, handler::Function)
    ensure_completion_capability!(server)
    server.completion_handler = handler
    return server
end

function set_completion_handler!(handler::Function, server::MCPServer)
    return set_completion_handler!(server, handler)
end

function clear_completion_handler!(server::MCPServer)
    server.completion_handler = nothing
    return server
end

function normalize_dict(value, label)
    value === nothing && return nothing
    value isa Dict{String,Any} && return value
    if value isa AbstractDict
        result = Dict{String,Any}()
        for (k, v) in value
            result[String(k)] = v
        end
        return result
    end
    throw(ArgumentError("Expected $(label) to be a dictionary, got $(typeof(value))"))
end

normalize_dict_or_empty(value, label) = begin
    result = normalize_dict(value, label)
    result === nothing ? Dict{String,Any}() : result
end

function parse_positive_int(value, label)
    ivalue = if value isa Integer
        Int(value)
    elseif value isa AbstractString
        parsed = tryparse(Int, strip(value))
        parsed === nothing && throw(mcp_error(:invalid_params, "$(label) must be an integer"))
        parsed
    else
        throw(mcp_error(:invalid_params, "$(label) must be an integer"))
    end
    ivalue > 0 || throw(mcp_error(:invalid_params, "$(label) must be positive"))
    return ivalue
end

function paginate_vector(items::Vector, params::Dict{String,Any})
    total = length(items)
    cursor_value = get(params, "cursor", nothing)
    start_index = if cursor_value === nothing
        1
    else
        parse_positive_int(cursor_value, "cursor")
    end
    start_index < 1 && throw(mcp_error(:invalid_params, "cursor must be >= 1"))
    if start_index > total
        return Any[], nothing
    end
    limit_value = get(params, "limit", nothing)
    remaining = total - start_index + 1
    count = remaining
    if limit_value !== nothing
        limit = parse_positive_int(limit_value, "limit")
        count = min(count, limit)
    end
    end_index = start_index + count - 1
    page = count > 0 ? collect(@view items[start_index:end_index]) : Any[]
    next_cursor = end_index < total ? string(end_index + 1) : nothing
    return page, next_cursor
end

function paginate_collection(items::Vector, params::Dict{String,Any}, key::String)
    page, next_cursor = paginate_vector(items, params)
    response = Dict{String,Any}(key => page)
    next_cursor !== nothing && (response["nextCursor"] = next_cursor)
    return response
end

function log_message!(
    server::MCPServer;
    level=server.logging_level,
    message=nothing,
    data=message,
    logger=nothing,
    session::Union{MCPSession,Nothing}=nothing,
    session_id::Union{AbstractString,Nothing}=nothing,
    annotations=nothing,
    metadata=nothing,
)
    ensure_logging_capability!(server)
    lvl = normalize_log_level(level)
    payload = Dict{String,Any}(
        "level" => lvl,
        "data" => data === nothing ? "" : data,
    )
    logger !== nothing && (payload["logger"] = String(logger))
    ann = annotations === nothing ? Dict{String,Any}() : normalize_dict(annotations, "annotations")
    metadata !== nothing && begin
        meta = normalize_dict(metadata, "metadata")
        if meta !== nothing
            annotations_dict = ann === nothing ? Dict{String,Any}() : Dict{String,Any}(ann)
            merge!(annotations_dict, meta)
            ann = annotations_dict
        end
    end
    ann !== nothing && !isempty(ann) && (payload["annotations"] = ann)
    recipients = MCPSession[]
    if session !== nothing
        push!(recipients, session)
    elseif session_id !== nothing
        existing = find_session(server, session_id)
        existing !== nothing && push!(recipients, existing)
    else
        recipients = collect(values(server.sessions))
    end
    isempty(recipients) && return nothing
    broadcast_jsonrpc_notification!(server, JSONRPC_METHOD_NOTIFICATIONS_MESSAGE; params=payload, sessions=recipients)
    return nothing
end

function list_changed_method(capability::AbstractString)
    if capability == "tools"
        return JSONRPC_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED
    elseif capability == "prompts"
        return JSONRPC_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED
    elseif capability == "resources"
        return JSONRPC_METHOD_NOTIFICATIONS_RESOURCES_LIST_CHANGED
    elseif capability == "resources/templates"
        return JSONRPC_METHOD_NOTIFICATIONS_RESOURCE_TEMPLATES_LIST_CHANGED
    else
        return nothing
    end
end

function notify_list_changed!(server::MCPServer, capability::AbstractString)
    method = list_changed_method(capability)
    method === nothing && return nothing
    broadcast_jsonrpc_notification!(server, method)
    return nothing
end
function register_session!(server::MCPServer; session_id::Union{AbstractString,Nothing}=nothing)
    id = session_id === nothing ? string(uuid4()) : String(session_id)
    session = MCPSession(id=id)
    server.sessions[id] = session
    return session
end

function find_session(server::MCPServer, session_id)
    session_id === nothing && return nothing
    return get(server.sessions, String(session_id), nothing)
end

function next_event_id!(session::MCPSession)
    session.event_sequence += 1
    return string(session.event_sequence)
end

serialize_event_payload(payload) = payload isa AbstractString ? String(payload) : JSON.json(payload)

function enqueue_session_event!(session::MCPSession, event::Union{AbstractString,Nothing}, payload)
    event_id = next_event_id!(session)
    data = serialize_event_payload(payload)
    event_name = event === nothing ? nothing : String(event)
    push!(session.pending_events, MCPEvent(id=event_id, event=event_name, data=data))
    return event_id
end

function enqueue_server_event!(server::MCPServer, session::MCPSession, event::Union{AbstractString,Nothing}, payload)
    return enqueue_session_event!(session, event, payload)
end

function enqueue_server_event!(server::MCPServer, session_id::AbstractString, event::Union{AbstractString,Nothing}, payload)
    session = find_session(server, session_id)
    session === nothing && throw(mcp_error(:invalid_session, "Unknown MCP session $(String(session_id))"))
    return enqueue_session_event!(session, event, payload)
end

function broadcast_server_event!(server::MCPServer, event::Union{AbstractString,Nothing}, payload)
    for session in values(server.sessions)
        session.initialized || continue
        enqueue_session_event!(session, event, payload)
    end
    return nothing
end

function enqueue_jsonrpc_event!(server::MCPServer, session::MCPSession, envelope::Dict{String,Any})
    enqueue_server_event!(server, session, "jsonrpc", envelope)
    return nothing
end

function enqueue_jsonrpc_notification!(
    server::MCPServer,
    session::MCPSession,
    method::AbstractString;
    params::Union{Dict{String,Any},Nothing}=nothing,
)
    envelope = Dict{String,Any}(
        "jsonrpc" => JSONRPC_VERSION,
        "method" => String(method),
    )
    params !== nothing && !isempty(params) && (envelope["params"] = params)
    enqueue_jsonrpc_event!(server, session, envelope)
    return nothing
end

function broadcast_jsonrpc_notification!(
    server::MCPServer,
    method::AbstractString;
    params::Union{Dict{String,Any},Nothing}=nothing,
    sessions::Union{Nothing,Vector{MCPSession}}=nothing,
)
    recipients = sessions === nothing ? collect(values(server.sessions)) : sessions
    for session in recipients
        session.initialized || continue
        enqueue_jsonrpc_notification!(server, session, method; params=params)
    end
    return nothing
end

function prune_session_events!(session::MCPSession, last_event_id::AbstractString)
    parsed = try
        parse(Int, String(last_event_id))
    catch
        return
    end
    session.pending_events = MCPEvent[event for event in session.pending_events if try
        parse(Int, event.id) > parsed
    catch
        true
    end]
    return nothing
end

function parse_timeout_header(req::HTTP.Request)
    header = HTTP.header(req, "Mcp-Timeout-Ms")
    header === nothing && return nothing
    value_str = strip(String(header))
    isempty(value_str) && return nothing
    timeout = try
        parse(Int, value_str)
    catch
        throw(mcp_error(:invalid_request, "Mcp-Timeout-Ms header must be an integer"))
    end
    timeout > 0 || throw(mcp_error(:invalid_request, "Mcp-Timeout-Ms header must be positive"))
    return timeout
end

function ensure_session_for_request(server::MCPServer, req::HTTP.Request, method::AbstractString)
    raw_header = HTTP.header(req, "MCP-Session-Id")
    header_value = raw_header === nothing ? nothing : String(raw_header)
    header_blank = header_value === nothing ? true : isempty(strip(header_value))
    if method == JSONRPC_METHOD_INITIALIZE
        if header_blank
            return register_session!(server)
        else
            session = find_session(server, header_value)
            session === nothing && (session = register_session!(server; session_id=header_value))
            return session
        end
    else
        (header_value === nothing || header_blank) && throw(mcp_error(:session_required, "MCP-Session-Id header is required for $(method)"))
        session = find_session(server, header_value)
        session === nothing && throw(mcp_error(:invalid_session, "Unknown MCP session $(String(header_value))"))
        return session
    end
end

function ensure_session_initialized!(session::MCPSession, method::AbstractString)
    session.initialized || throw(mcp_error(:not_initialized, "Session $(session.id) is not initialized; cannot call $(method) yet"))
    return session
end

function validate_jsonrpc_headers(server::MCPServer, req::HTTP.Request)
    origin_error = validate_origin_header(server, req)
    origin_error !== nothing && return origin_error
    accept = HTTP.header(req, "Accept")
    accept_value = accept === nothing ? "" : lowercase(String(accept))
    if isempty(accept_value) || !occursin("application/json", accept_value)
        data = Dict("error" => "Request must accept application/json responses", "required" => "application/json, text/event-stream")
        return HTTP.Response(406, response_headers(server), JSON.json(data))
    end
    if !occursin("text/event-stream", accept_value)
        data = Dict("error" => "Request must accept text/event-stream responses", "required" => "application/json, text/event-stream")
        return HTTP.Response(406, response_headers(server), JSON.json(data))
    end
    version, missing_error = resolve_protocol_version(server, req, "JSON-RPC request")
    missing_error !== nothing && return missing_error
    if version != server.config.protocol_version
        data = Dict(
            "error" => "Unsupported MCP protocol version",
            "expected" => server.config.protocol_version,
            "received" => version,
        )
        return HTTP.Response(400, response_headers(server), JSON.json(data))
    end
    return nothing
end

function normalize_host_for_origin(host)
    host === nothing && return ""
    host_str = lowercase(String(host))
    isempty(host_str) && return ""
    if startswith(host_str, "[")
        closing = findfirst(']', host_str)
        closing === nothing && return host_str
        return host_str[1:closing]
    end
    return split(host_str, ':')[1]
end

function is_loopback_host(host)
    normalized = normalize_host_for_origin(host)
    return normalized in ("localhost", "127.0.0.1", "::1", "[::1]")
end

function is_loopback_origin(origin::AbstractString)
    uri = try
        HTTP.URI(String(origin))
    catch
        return false
    end
    scheme = uri.scheme === nothing ? "" : lowercase(String(uri.scheme))
    scheme in ("http", "https") || return false
    return is_loopback_host(uri.host)
end

function validate_origin_header(server::MCPServer, req::HTTP.Request)
    origin = HTTP.header(req, "Origin")
    origin === nothing && return nothing
    origin_str = strip(String(origin))
    isempty(origin_str) && return nothing
    allowed = server.config.allowed_origins
    if allowed !== nothing
        origin_str in allowed && return nothing
        return HTTP.Response(403, response_headers(server), JSON.json(Dict("error" => "Forbidden Origin header")))
    end
    request_host = HTTP.header(req, "Host")
    if is_loopback_origin(origin_str) && is_loopback_host(request_host)
        return nothing
    end
    return HTTP.Response(403, response_headers(server), JSON.json(Dict("error" => "Forbidden Origin header")))
end

function response_headers(
    server::MCPServer;
    content_type::Union{String,Nothing}="application/json",
    session::Union{MCPSession,Nothing}=nothing,
    extra::Vector{HeaderPair}=HeaderPair[],
)
    headers = HeaderPair[]
    content_type !== nothing && push!(headers, "Content-Type" => content_type)
    push!(headers, "MCP-Protocol-Version" => server.config.protocol_version)
    session !== nothing && push!(headers, "MCP-Session-Id" => session.id)
    append!(headers, extra)
    return headers
end

function resolve_protocol_version(server::MCPServer, req::HTTP.Request, context::AbstractString)
    protocol_raw = HTTP.header(req, "MCP-Protocol-Version")
    version = protocol_raw === nothing ? "" : String(protocol_raw)
    if isempty(strip(version))
        behavior = server.missing_protocol_header_behavior
        if behavior == :error
            data = Dict("error" => "Missing MCP-Protocol-Version header", "expected" => server.config.protocol_version)
            return nothing, HTTP.Response(400, response_headers(server), JSON.json(data))
        end
        if behavior == :warn
            @warn "MCP $(context) missing MCP-Protocol-Version header; defaulting to $(server.config.protocol_version)" method=request_method_string(req) target=request_target_string(req)
        end
        return server.config.protocol_version, nothing
    end
    return version, nothing
end

function validate_stream_headers(server::MCPServer, req::HTTP.Request)
    origin_error = validate_origin_header(server, req)
    origin_error !== nothing && return origin_error
    accept = HTTP.header(req, "Accept")
    accept_value = accept === nothing ? "" : lowercase(String(accept))
    if isempty(accept_value) || !occursin("text/event-stream", accept_value)
        data = Dict("error" => "Event stream must accept text/event-stream responses")
        return HTTP.Response(406, response_headers(server), JSON.json(data))
    end
    version, missing_error = resolve_protocol_version(server, req, "event stream request")
    missing_error !== nothing && return missing_error
    if version != server.config.protocol_version
        data = Dict(
            "error" => "Unsupported MCP protocol version",
            "expected" => server.config.protocol_version,
            "received" => version,
        )
        return HTTP.Response(400, response_headers(server), JSON.json(data))
    end
    return nothing
end

function format_sse_event(event::MCPEvent)
    buffer = IOBuffer()
    if event.event !== nothing && !isempty(event.event)
        println(buffer, "event: ", event.event)
    end
    println(buffer, "id: ", event.id)
    for line in split(event.data, '\n'; keepempty=true)
        println(buffer, "data: ", line)
    end
    println(buffer)
    return String(take!(buffer))
end

function register_tool!(server::MCPServer, tool::MCPServerTool)
    name = String(tool.name)
    haskey(server.tools, name) && throw(ArgumentError("Tool $(name) already registered"))
    server.tools[name] = MCPServerTool(
        name=name,
        handler=tool.handler,
        title=maybe_string(tool.title),
        description=maybe_string(tool.description),
        input_schema=normalize_dict(tool.input_schema, "input_schema"),
        output_schema=normalize_dict(tool.output_schema, "output_schema"),
        execution=normalize_dict_or_empty(tool.execution, "execution"),
        icons=[normalize_dict_or_empty(icon, "icon") for icon in tool.icons],
        annotations=normalize_dict_or_empty(tool.annotations, "annotations"),
        meta=normalize_dict_or_empty(tool.meta, "_meta"),
    )
    ensure_capability!(server, "tools")
    notify_list_changed!(server, "tools")
    return server.tools[name]
end

function register_tool!(
    server::MCPServer;
    name,
    handler::Function,
    title=nothing,
    description=nothing,
    input_schema=nothing,
    output_schema=nothing,
    execution=Dict{String,Any}(),
    icons=Dict{String,Any}[],
    annotations=Dict{String,Any}(),
    meta=Dict{String,Any}(),
    metadata=nothing,
)
    annotation_data = normalize_dict_or_empty(annotations, "annotations")
    if metadata !== nothing
        meta = normalize_dict(metadata, "metadata")
        meta !== nothing && merge!(annotation_data, meta)
    end
    tool = MCPServerTool(
        name=String(name),
        handler=handler,
        title=title,
        description=description,
        input_schema=input_schema,
        output_schema=output_schema,
        execution=normalize_dict_or_empty(execution, "execution"),
        icons=[normalize_dict_or_empty(icon, "icon") for icon in icons],
        annotations=annotation_data,
        meta=normalize_dict_or_empty(meta, "_meta"),
    )
    return register_tool!(server, tool)
end

function register_tools!(server::MCPServer, tools; kwargs...)
    for tool in tools
        register_tool!(server, tool; kwargs...)
    end
    return server
end

function register_prompt!(server::MCPServer, prompt::MCPServerPrompt)
    name = String(prompt.name)
    haskey(server.prompts, name) && throw(ArgumentError("Prompt $(name) already registered"))
    server.prompts[name] = MCPServerPrompt(
        name=name,
        handler=prompt.handler,
        title=maybe_string(prompt.title),
        description=maybe_string(prompt.description),
        arguments=[normalize_dict_or_empty(arg, "argument") for arg in prompt.arguments],
        icons=[normalize_dict_or_empty(icon, "icon") for icon in prompt.icons],
        annotations=normalize_dict_or_empty(prompt.annotations, "annotations"),
        meta=normalize_dict_or_empty(prompt.meta, "_meta"),
    )
    ensure_capability!(server, "prompts")
    notify_list_changed!(server, "prompts")
    return server.prompts[name]
end

function register_prompt!(server::MCPServer; name, handler::Function, title=nothing, description=nothing, arguments=Dict{String,Any}[], icons=Dict{String,Any}[], annotations=Dict{String,Any}(), meta=Dict{String,Any}(), metadata=nothing)
    annotation_data = normalize_dict_or_empty(annotations, "annotations")
    if metadata !== nothing
        meta = normalize_dict(metadata, "metadata")
        meta !== nothing && merge!(annotation_data, meta)
    end
    prompt = MCPServerPrompt(
        name=String(name),
        handler=handler,
        title=title,
        description=description,
        arguments=[normalize_dict_or_empty(arg, "argument") for arg in arguments],
        icons=[normalize_dict_or_empty(icon, "icon") for icon in icons],
        annotations=annotation_data,
        meta=normalize_dict_or_empty(meta, "_meta"),
    )
    return register_prompt!(server, prompt)
end

function register_resource!(server::MCPServer, resource::MCPServerResource)
    uri = String(resource.uri)
    haskey(server.resources, uri) && throw(ArgumentError("Resource $(uri) already registered"))
    size_value = resource.size === nothing ? nothing : Int(resource.size)
    server.resources[uri] = MCPServerResource(
        uri=uri,
        handler=resource.handler,
        name=maybe_string(resource.name),
        title=maybe_string(resource.title),
        description=maybe_string(resource.description),
        mime_type=maybe_string(resource.mime_type),
        size=size_value,
        icons=[normalize_dict_or_empty(icon, "icon") for icon in resource.icons],
        annotations=normalize_dict_or_empty(resource.annotations, "annotations"),
        meta=normalize_dict_or_empty(resource.meta, "_meta"),
    )
    ensure_capability!(server, "resources")
    notify_list_changed!(server, "resources")
    return server.resources[uri]
end

function register_resource!(
    server::MCPServer;
    uri,
    handler::Function,
    title=nothing,
    name=nothing,
    description=nothing,
    mime_type=nothing,
    size=nothing,
    icons=Dict{String,Any}[],
    annotations=Dict{String,Any}(),
    meta=Dict{String,Any}(),
    metadata=nothing,
)
    annotation_data = normalize_dict_or_empty(annotations, "annotations")
    if metadata !== nothing
        meta = normalize_dict(metadata, "metadata")
        meta !== nothing && merge!(annotation_data, meta)
    end
    effective_title = title === nothing ? name : title
    resource = MCPServerResource(
        uri=String(uri),
        handler=handler,
        name=name === nothing ? nothing : String(name),
        title=effective_title,
        description=description,
        mime_type=mime_type,
        size=size,
        icons=[normalize_dict_or_empty(icon, "icon") for icon in icons],
        annotations=annotation_data,
        meta=normalize_dict_or_empty(meta, "_meta"),
    )
    return register_resource!(server, resource)
end

function register_resource_template!(server::MCPServer, template::MCPServerResourceTemplate)
    name = String(template.name)
    haskey(server.resource_templates, name) && throw(ArgumentError("Resource template $(name) already registered"))
    server.resource_templates[name] = MCPServerResourceTemplate(
        name=name,
        handler=template.handler,
        uri_template=maybe_string(template.uri_template),
        title=maybe_string(template.title),
        description=maybe_string(template.description),
        mime_type=maybe_string(template.mime_type),
        icons=[normalize_dict_or_empty(icon, "icon") for icon in template.icons],
        annotations=normalize_dict_or_empty(template.annotations, "annotations"),
        input_schema=normalize_dict(template.input_schema, "input_schema"),
        meta=normalize_dict_or_empty(template.meta, "_meta"),
    )
    resources_cap = ensure_capability!(server, "resources")
    if resources_cap isa AbstractDict
        resources_cap["subscribe"] = true
    end
    notify_list_changed!(server, "resources/templates")
    return server.resource_templates[name]
end

function register_resource_template!(
    server::MCPServer;
    name,
    handler::Function,
    uri_template=nothing,
    title=nothing,
    description=nothing,
    mime_type=nothing,
    icons=Dict{String,Any}[],
    annotations=Dict{String,Any}(),
    meta=Dict{String,Any}(),
    metadata=nothing,
    input_schema=nothing,
)
    annotation_data = normalize_dict_or_empty(annotations, "annotations")
    if metadata !== nothing
        meta = normalize_dict(metadata, "metadata")
        meta !== nothing && merge!(annotation_data, meta)
    end
    template = MCPServerResourceTemplate(
        name=String(name),
        handler=handler,
        uri_template=uri_template,
        title=title,
        description=description,
        mime_type=mime_type,
        icons=[normalize_dict_or_empty(icon, "icon") for icon in icons],
        annotations=annotation_data,
        input_schema=input_schema,
        meta=normalize_dict_or_empty(meta, "_meta"),
    )
    return register_resource_template!(server, template)
end

function manifest_capabilities(server::MCPServer)
    capabilities = Dict{String,Any}()
    for (key, value) in server.capabilities
        name = String(key)
        if value isa AbstractDict
            capabilities[name] = deepcopy(value)
        else
            capabilities[name] = value
        end
    end
    function ensure_dict_capability!(caps::Dict{String,Any}, name::String)
        entry = get(caps, name, nothing)
        if entry === nothing
            entry = Dict{String,Any}()
            caps[name] = entry
        elseif !(entry isa AbstractDict)
            entry = Dict{String,Any}()
            caps[name] = entry
        end
        return entry
    end
    if !isempty(server.tools)
        tools_cap = ensure_dict_capability!(capabilities, "tools")
        tools_cap["listChanged"] = true
    end
    if !isempty(server.prompts)
        prompts_cap = ensure_dict_capability!(capabilities, "prompts")
        prompts_cap["listChanged"] = true
    end
    if !isempty(server.resources) || !isempty(server.resource_templates)
        resources_cap = ensure_dict_capability!(capabilities, "resources")
        resources_cap["listChanged"] = true
        resources_cap["subscribe"] = true
    end
    if server.logging_handler !== nothing || haskey(capabilities, "logging")
        logging_cap = ensure_dict_capability!(capabilities, "logging")
        haskey(logging_cap, "levels") || (logging_cap["levels"] = MCP_LOG_LEVELS)
        logging_cap["setLevel"] = true
    end
    if server.completion_handler !== nothing || haskey(capabilities, "completions")
        completion_cap = ensure_dict_capability!(capabilities, "completions")
        completion_cap["structured"] = true
    end
    return capabilities
end

function default_manifest(config::MCPServerConfig, server::MCPServer)
    transport = Dict{String,Any}(
        "type" => "http",
        "url" => server.transport_path,
        "serialization" => "json",
    )
    transport["accepts"] = ["application/json", "text/event-stream"]
    transport["supportsSession"] = true
    if !isempty(config.transport_metadata)
        for (k, v) in config.transport_metadata
            transport[String(k)] = v
        end
    end
    entry = Dict{String,Any}(
        "protocol" => "https://modelcontextprotocol.io/$(config.protocol_version)",
        "transport" => transport,
        "capabilities" => manifest_capabilities(server),
        "default" => true,
    )
    manifest = Dict{String,Any}(
        "schema_version" => config.protocol_version,
        "name_for_human" => config.name,
        "model_context_protocols" => [entry],
    )
    config.description === nothing || (manifest["description_for_human"] = maybe_string(config.description))
    config.description_for_model === nothing || (manifest["description_for_model"] = maybe_string(config.description_for_model))
    config.instructions === nothing || (manifest["instructions"] = maybe_string(config.instructions))
    config.instructions_url === nothing || (manifest["instructions_url"] = maybe_string(config.instructions_url))
    return manifest
end

function server_manifest(server::MCPServer)
    config_manifest = normalize_dict(server.config.manifest, "manifest")
    if config_manifest !== nothing && !isempty(config_manifest)
        return copy(config_manifest)
    end
    return default_manifest(server.config, server)
end

function manifest_response(server::MCPServer, req::HTTP.Request)
    data = server_manifest(server)
    body = JSON.json(data)
    response = HTTP.Response(200, response_headers(server), body)
    return response
end

function jsonrpc_success(server::MCPServer, session::Union{MCPSession,Nothing}, id, result)
    body = Dict(
        "jsonrpc" => JSONRPC_VERSION,
        "id" => id,
        "result" => result,
    )
    return HTTP.Response(200, response_headers(server; session=session), JSON.json(body))
end

function jsonrpc_error(server::MCPServer, session::Union{MCPSession,Nothing}, id, code::Int, message::AbstractString; data=nothing)
    error = Dict("code" => code, "message" => String(message))
    data === nothing || (error["data"] = data)
    body = Dict(
        "jsonrpc" => JSONRPC_VERSION,
        "id" => id,
        "error" => error,
    )
    return HTTP.Response(200, response_headers(server; session=session), JSON.json(body))
end

function params_dict(params)
    params === nothing && return Dict{String,Any}()
    params isa AbstractDict || throw(mcp_error(:invalid_params, "Expected params to be an object"))
    dict = Dict{String,Any}()
    for (k, v) in params
        dict[String(k)] = v
    end
    return dict
end

arguments_dict(params::Dict{String,Any}) = params_dict(get(params, "arguments", Dict{String,Any}()))

function tool_descriptor(tool::MCPServerTool)
    data = Dict{String,Any}("name" => tool.name)
    tool.title !== nothing && (data["title"] = tool.title)
    tool.description !== nothing && (data["description"] = tool.description)
    data["inputSchema"] = tool.input_schema === nothing ? Dict{String,Any}("type" => "object") : tool.input_schema
    tool.output_schema !== nothing && (data["outputSchema"] = tool.output_schema)
    !isempty(tool.execution) && (data["execution"] = tool.execution)
    !isempty(tool.icons) && (data["icons"] = tool.icons)
    if !isempty(tool.annotations)
        data["annotations"] = tool.annotations
    end
    !isempty(tool.meta) && (data["_meta"] = tool.meta)
    return data
end

function prompt_descriptor(prompt::MCPServerPrompt)
    data = Dict{String,Any}("name" => prompt.name)
    prompt.title !== nothing && (data["title"] = prompt.title)
    prompt.description !== nothing && (data["description"] = prompt.description)
    !isempty(prompt.arguments) && (data["arguments"] = prompt.arguments)
    !isempty(prompt.icons) && (data["icons"] = prompt.icons)
    if !isempty(prompt.annotations)
        data["annotations"] = prompt.annotations
    end
    !isempty(prompt.meta) && (data["_meta"] = prompt.meta)
    return data
end

function resource_descriptor(resource::MCPServerResource)
    data = Dict{String,Any}(
        "name" => resource.name === nothing ? resource.uri : resource.name,
        "uri" => resource.uri,
    )
    resource.title !== nothing && (data["title"] = resource.title)
    resource.description !== nothing && (data["description"] = resource.description)
    resource.mime_type !== nothing && (data["mimeType"] = resource.mime_type)
    resource.size !== nothing && (data["size"] = resource.size)
    !isempty(resource.icons) && (data["icons"] = resource.icons)
    if !isempty(resource.annotations)
        data["annotations"] = resource.annotations
    end
    !isempty(resource.meta) && (data["_meta"] = resource.meta)
    return data
end

function resource_template_descriptor(template::MCPServerResourceTemplate)
    data = Dict{String,Any}(
        "name" => template.name,
        "uriTemplate" => template.uri_template === nothing ? template.name : template.uri_template,
    )
    template.title !== nothing && (data["title"] = template.title)
    template.description !== nothing && (data["description"] = template.description)
    template.mime_type !== nothing && (data["mimeType"] = template.mime_type)
    !isempty(template.icons) && (data["icons"] = template.icons)
    if !isempty(template.annotations)
        data["annotations"] = template.annotations
    end
    !isempty(template.meta) && (data["_meta"] = template.meta)
    return data
end

function flatten_legacy_tool_outputs(outputs)
    outputs isa AbstractVector || return Any[]
    content_items = Any[]
    for item in outputs
        if item isa AbstractDict
            content = get(item, "content", nothing)
            content isa AbstractVector && append!(content_items, content)
        end
    end
    return content_items
end

function normalize_tool_result(result)
    result isa AbstractDict || throw(mcp_error(:invalid_response, "Tool handler must return a dictionary"))
    normalized = Dict{String,Any}()
    if haskey(result, "content")
        normalized["content"] = result["content"]
    elseif haskey(result, "outputs")
        normalized["content"] = flatten_legacy_tool_outputs(result["outputs"])
    end
    if haskey(result, "structuredContent")
        normalized["structuredContent"] = result["structuredContent"]
    end
    if !haskey(normalized, "content") && !haskey(normalized, "structuredContent")
        throw(mcp_error(:invalid_response, "Tool handler must provide content or structuredContent"))
    end
    if haskey(result, "isError")
        normalized["isError"] = result["isError"]
    end
    if haskey(result, "annotations")
        annotations = normalize_dict(result["annotations"], "annotations")
        annotations !== nothing && !isempty(annotations) && (normalized["annotations"] = annotations)
    end
    if haskey(result, "_meta")
        meta = normalize_dict(result["_meta"], "_meta")
        meta !== nothing && !isempty(meta) && (normalized["_meta"] = meta)
    end
    if haskey(result, "outputSchema")
        normalized["outputSchema"] = result["outputSchema"]
    end
    if haskey(result, "nextCursor")
        normalized["nextCursor"] = result["nextCursor"]
    end
    return normalized
end

function call_tool(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    haskey(params, "name") || throw(mcp_error(:invalid_params, "Tool call requires a name"))
    name = String(params["name"])
    tool = get(server.tools, name, nothing)
    tool === nothing && throw(mcp_error(:method_not_found, "Tool $(name) is not registered"))
    args = arguments_dict(params)
    result = tool.handler(context, args)
    normalized = normalize_tool_result(result)
    if tool.output_schema !== nothing && !haskey(normalized, "structuredContent")
        annotations = get(normalized, "annotations", Dict{String,Any}())
        schema = tool.output_schema
        if schema isa AbstractDict
            props = get(schema, "properties", nothing)
            if props isa AbstractDict
                structured = Dict{String,Any}()
                for (prop_name, prop_schema) in props
                    prop_value = get(annotations, String(prop_name), nothing)
                    prop_value === nothing && continue
                    structured[String(prop_name)] = prop_value
                end
                !isempty(structured) && (normalized["structuredContent"] = structured)
            end
        end
    end
    return normalized
end

function handle_logging_set_level(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    haskey(params, "level") || throw(mcp_error(:invalid_params, "logging/setLevel requires a level"))
    level = normalize_log_level(params["level"])
    try
        server.logging_handler !== nothing && server.logging_handler(context, level)
    catch err
        @warn "logging handler raised" err
    end
    set_logging_level!(server, level)
    return Dict("level" => server.logging_level)
end

function handle_completion_request(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    server.completion_handler === nothing && throw(mcp_error(:method_not_found, "completion support not configured"))
    result = server.completion_handler(context, params)
    result isa AbstractDict || throw(mcp_error(:invalid_response, "Completion handler must return a dictionary"))
    return result
end

function list_tools(server::MCPServer, params::Dict{String,Any})
    items = [tool_descriptor(tool) for tool in values(server.tools)]
    return paginate_collection(items, params, "tools")
end

function list_prompts(server::MCPServer, params::Dict{String,Any})
    items = [prompt_descriptor(prompt) for prompt in values(server.prompts)]
    return paginate_collection(items, params, "prompts")
end

function get_prompt(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    haskey(params, "name") || throw(mcp_error(:invalid_params, "Prompt retrieval requires a name"))
    name = String(params["name"])
    prompt = get(server.prompts, name, nothing)
    prompt === nothing && throw(mcp_error(:method_not_found, "Prompt $(name) is not registered"))
    args = arguments_dict(params)
    return prompt.handler(context, args)
end

function list_resources(server::MCPServer, params::Dict{String,Any})
    items = [resource_descriptor(resource) for resource in values(server.resources)]
    return paginate_collection(items, params, "resources")
end

function list_resource_templates(server::MCPServer, params::Dict{String,Any})
    items = [resource_template_descriptor(template) for template in values(server.resource_templates)]
    return paginate_collection(items, params, "resourceTemplates")
end

function read_resource(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    haskey(params, "uri") || throw(mcp_error(:invalid_params, "Resource retrieval requires a uri"))
    uri = String(params["uri"])
    resource = get(server.resources, uri, nothing)
    resource === nothing && throw(mcp_error(:method_not_found, "Resource $(uri) is not registered"))
    args = arguments_dict(params)
    return resource.handler(context, args)
end

function subscribe_resource(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    context.session === nothing && throw(mcp_error(:invalid_request, "resources/subscribe requires a session"))
    haskey(params, "uri") || throw(mcp_error(:invalid_params, "Subscription requires a uri"))
    uri = String(params["uri"])
    push!(context.session.subscriptions, uri)
    resources_cap = ensure_capability!(server, "resources")
    if resources_cap isa AbstractDict
        resources_cap["subscribe"] = true
    end
    return Dict{String,Any}()
end

function unsubscribe_resource(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    context.session === nothing && throw(mcp_error(:invalid_request, "resources/unsubscribe requires a session"))
    haskey(params, "uri") || throw(mcp_error(:invalid_params, "Unsubscribe requires a uri"))
    uri = String(params["uri"])
    delete!(context.session.subscriptions, uri)
    return Dict{String,Any}()
end

function notify_resource_updated!(
    server::MCPServer,
    uri::AbstractString;
    session_ids::Union{Nothing,Vector{String}}=nothing,
    annotations=nothing,
    metadata=nothing,
)
    payload = Dict{String,Any}("uri" => String(uri))
    annotation_data = normalize_dict_or_empty(annotations, "annotations")
    if metadata !== nothing
        meta = normalize_dict(metadata, "metadata")
        meta !== nothing && merge!(annotation_data, meta)
    end
    !isempty(annotation_data) && (payload["annotations"] = annotation_data)
    recipients = MCPSession[]
    for session in values(server.sessions)
        session.initialized || continue
        if session_ids !== nothing && !(session.id in session_ids)
            continue
        end
        (String(uri) in session.subscriptions) || continue
        push!(recipients, session)
    end
    isempty(recipients) && return nothing
    broadcast_jsonrpc_notification!(server, JSONRPC_METHOD_NOTIFICATIONS_RESOURCES_UPDATED; params=payload, sessions=recipients)
    return nothing
end

function handle_cancellation_notification(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    server.cancellation_handler === nothing && return nothing
    try
        server.cancellation_handler(context, params)
    catch err
        @warn "Error in cancellation handler" session=context.session === nothing ? "none" : context.session.id err
    end
    return nothing
end

function initialize_response(server::MCPServer, session::MCPSession, params::Dict{String,Any})
    _ = params # currently unused, retained for future extensions
    result = Dict(
        "protocolVersion" => server.config.protocol_version,
        "capabilities" => manifest_capabilities(server),
        "serverInfo" => server.server_info,
    )
    server.config.instructions !== nothing && (result["instructions"] = String(server.config.instructions))
    return result
end

function dispatch_jsonrpc(server::MCPServer, context::MCPRequestContext, params::Dict{String,Any})
    method = context.method
    if method == JSONRPC_METHOD_INITIALIZE
        return initialize_response(server, context.session, params)
    elseif method == JSONRPC_METHOD_PING
        return Dict{String,Any}()
    elseif method == JSONRPC_METHOD_NOTIFICATIONS_INITIALIZED
        context.session === nothing && throw(mcp_error(:invalid_request, "notifications/initialized requires a session"))
        context.session.initialized = true
        return nothing
    elseif method == JSONRPC_METHOD_TOOLS_LIST
        return list_tools(server, params)
    elseif method == JSONRPC_METHOD_TOOLS_CALL
        return call_tool(server, context, params)
    elseif method == JSONRPC_METHOD_PROMPTS_LIST
        return list_prompts(server, params)
    elseif method == JSONRPC_METHOD_PROMPTS_GET
        return get_prompt(server, context, params)
    elseif method == JSONRPC_METHOD_RESOURCES_LIST
        return list_resources(server, params)
    elseif method == JSONRPC_METHOD_RESOURCES_READ
        return read_resource(server, context, params)
    elseif method == JSONRPC_METHOD_RESOURCES_TEMPLATES_LIST
        return list_resource_templates(server, params)
    elseif method == JSONRPC_METHOD_RESOURCES_SUBSCRIBE
        return subscribe_resource(server, context, params)
    elseif method == JSONRPC_METHOD_RESOURCES_UNSUBSCRIBE
        return unsubscribe_resource(server, context, params)
    elseif method == JSONRPC_METHOD_COMPLETION_COMPLETE
        return handle_completion_request(server, context, params)
    elseif method == JSONRPC_METHOD_LOGGING_SET_LEVEL
        return handle_logging_set_level(server, context, params)
    elseif method == JSONRPC_METHOD_NOTIFICATIONS_CANCELLED
        handle_cancellation_notification(server, context, params)
        return nothing
    else
        throw(mcp_error(:method_not_found, "Unsupported MCP method $(method)"))
    end
end

function classify_error(err)
    if err isa MCPError
        if err.code == :method_not_found
            return -32601, err.message
        elseif err.code == :invalid_params
            return -32602, err.message
        elseif err.code == :invalid_request
            return -32600, err.message
        elseif err.code == :invalid_session
            return -32001, err.message
        elseif err.code == :session_required
            return -32002, err.message
        elseif err.code == :not_initialized
            return -32002, err.message
        elseif err.code == :invalid_response
            return -32003, err.message
        else
            return -32000, err.message
        end
    elseif err isa ArgumentError
        return -32602, sprint(showerror, err)
    else
        return -32000, sprint(showerror, err)
    end
end

function handle_jsonrpc_request(server::MCPServer, req::HTTP.Request)
    server.request_hook !== nothing && server.request_hook(req)
    body = read_request_body(req)
    header_error = validate_jsonrpc_headers(server, req)
    header_error !== nothing && return header_error
    payload = try
        JSON.parse(body)
    catch err
        response = jsonrpc_error(server, nothing, nothing, -32700, "Failed to parse JSON-RPC body: $(sprint(showerror, err))")
        return response
    end
    payload isa AbstractDict || return jsonrpc_error(server, nothing, nothing, -32600, "JSON-RPC payload must be an object")
    id = get(payload, "id", nothing)
    if !haskey(payload, "method") && id !== nothing && (haskey(payload, "result") || haskey(payload, "error"))
        session = try
            ensure_session_for_request(server, req, "JSON-RPC response")
        catch err
            if err isa MCPError
                code, message = classify_error(err)
                response = jsonrpc_error(server, nothing, nothing, code, message)
                return response
            else
                rethrow(err)
            end
        end
        try
            ensure_session_initialized!(session, "JSON-RPC response")
        catch err
            if err isa MCPError
                code, message = classify_error(err)
                response = jsonrpc_error(server, session, nothing, code, message)
                return response
            else
                rethrow(err)
            end
        end
        return HTTP.Response(202, response_headers(server; session=session, content_type=nothing))
    end
    method_value = get(payload, "method", nothing)
    method_value isa AbstractString || return jsonrpc_error(server, nothing, id, -32600, "JSON-RPC method must be a string")
    method = String(method_value)
    params = params_dict(get(payload, "params", Dict{String,Any}()))
    timeout_ms = try
        parse_timeout_header(req)
    catch err
        if err isa MCPError
            code, message = classify_error(err)
            response = jsonrpc_error(server, nothing, id, code, message)
            return response
        else
            rethrow(err)
        end
    end
    session = try
        ensure_session_for_request(server, req, method)
    catch err
        if err isa MCPError
            code, message = classify_error(err)
            response = jsonrpc_error(server, nothing, id, code, message)
            return response
        else
            rethrow(err)
        end
    end
    context = MCPRequestContext(server, req, method, id, params, session, timeout_ms)
    try
        if method != JSONRPC_METHOD_INITIALIZE && method != JSONRPC_METHOD_NOTIFICATIONS_INITIALIZED
            ensure_session_initialized!(session, method)
        end
    catch err
        if err isa MCPError
            code, message = classify_error(err)
            response = jsonrpc_error(server, session, id, code, message)
            return response
        else
            rethrow(err)
        end
    end
    if id === nothing
        try
            dispatch_jsonrpc(server, context, params)
        catch err
            @warn "Error handling JSON-RPC notification" method=context.method err
        end
        response = HTTP.Response(202, response_headers(server; session=session, content_type=nothing))
        return response
    end
    try
        result = dispatch_jsonrpc(server, context, params)
        response = jsonrpc_success(server, session, id, result)
        return response
    catch err
        code, message = classify_error(err)
        response = jsonrpc_error(server, session, id, code, message)
        return response
    end
end

function handle_stream_request(server::MCPServer, req::HTTP.Request)
    header_error = validate_stream_headers(server, req)
    header_error !== nothing && return header_error
    session_id = HTTP.header(req, "MCP-Session-Id")
    if session_id === nothing
        response = HTTP.Response(400, response_headers(server), JSON.json(Dict("error" => "Missing MCP-Session-Id header")))
        return response
    end
    session = find_session(server, session_id)
    if session === nothing
        response = HTTP.Response(404, response_headers(server), JSON.json(Dict("error" => "Unknown session")))
            return response
    end
    ensure_session_initialized!(session, "event-stream")
    last_event = HTTP.header(req, "Last-Event-ID")
    last_event !== nothing && prune_session_events!(session, String(last_event))
    events = copy(session.pending_events)
    empty!(session.pending_events)
    if isempty(events)
        heartbeat_id = next_event_id!(session)
        heartbeat_payload = Dict("sessionId" => session.id)
        heartbeat_event = MCPEvent(id=heartbeat_id, event="heartbeat", data=serialize_event_payload(heartbeat_payload))
        events = MCPEvent[heartbeat_event]
    end
    response = HTTP.Response(
        200,
        response_headers(server; session=session, content_type=nothing, extra=HeaderPair["Connection" => "close"]),
    )
    HTTP.sse_stream(response) do stream
        first_event = true
        for event in events
            write(
                stream,
                HTTP.SSEEvent(
                    event.data;
                    event=event.event,
                    id=event.id,
                    retry=first_event ? 15000 : nothing,
                ),
            )
            first_event = false
        end
    end
    return response
end

function handle_session_delete(server::MCPServer, req::HTTP.Request)
    origin_error = validate_origin_header(server, req)
    origin_error !== nothing && return origin_error
    version, version_error = resolve_protocol_version(server, req, "session delete request")
    version_error !== nothing && return version_error
    if version != server.config.protocol_version
        data = Dict(
            "error" => "Unsupported MCP protocol version",
            "expected" => server.config.protocol_version,
            "received" => version,
        )
        return HTTP.Response(400, response_headers(server), JSON.json(data))
    end
    session_id = HTTP.header(req, "MCP-Session-Id")
    if session_id === nothing || isempty(strip(String(session_id)))
        return HTTP.Response(400, response_headers(server), JSON.json(Dict("error" => "Missing MCP-Session-Id header")))
    end
    delete!(server.sessions, String(session_id))
    return HTTP.Response(202, response_headers(server; content_type=nothing))
end

read_request_body(req::HTTP.Request) = begin
    body = req.body
    if body === nothing
        return ""
    elseif body isa Vector{UInt8}
        return String(body)
    elseif body isa AbstractString
        return String(body)
    else
        try
            return String(read(body))
        catch
            return String(body)
        end
    end
end

function build_router(server::MCPServer)
    router = HTTP.Router()
    for path in server.config.manifest_paths
        HTTP.register!(router, "GET", path, req -> manifest_response(server, req))
    end
    HTTP.register!(router, "POST", server.transport_path, req -> handle_jsonrpc_request(server, req))
    HTTP.register!(router, "GET", server.transport_path, req -> handle_stream_request(server, req))
    HTTP.register!(router, "DELETE", server.transport_path, req -> handle_session_delete(server, req))
    return router
end

function handle_verbose_logging(f, verbose)
    function (req::HTTP.Request)
        verbose && @info req
        resp = f(req)
        verbose && @info resp
        return resp
    end
end

function serve_mcp_http(server::MCPServer; host::AbstractString="127.0.0.1", port::Integer=0, verbose::Bool=server.config.verbose)
    router = build_router(server)
    http_server = HTTP.serve!(handle_verbose_logging(router, verbose), host, port)
    sock = Sockets.getsockname(http_server.listener.server)
    actual_port = sock isa Tuple ? sock[end] : sock.port
    actual_host = host
    return MCPHTTPServer(server, router, http_server, actual_host, actual_port)
end

stop_mcp_server(http_server::MCPHTTPServer) = close(http_server.http)

base_url(http_server::MCPHTTPServer) = string("http://", http_server.host, ":", string(http_server.port))
