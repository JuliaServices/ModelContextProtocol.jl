using Logging

MCPClientConfig(; transport=nothing, protocol_version=DEFAULT_PROTOCOL_VERSION, headers=nothing, http=HTTP, timeout=JSONRPC_TIMEOUT, verbose::Bool=false) =
    MCPClientConfig(transport, String(protocol_version), normalize_headers(headers), http, timeout, verbose)

function prepare_manual_client(
    discovery::MCPDiscovery;
    config::MCPClientConfig=MCPClientConfig(),
    transport=nothing,
    headers=nothing,
)
    descriptor = select_transport(discovery, transport === nothing ? config.transport : transport)
    descriptor === nothing && throw(mcp_error(:transport_missing, "No transport available in discovery document"))
    header_pairs = copy(config.headers)
    if headers !== nothing
        append!(header_pairs, normalize_headers(headers))
    end
    return MCPClient(
        discovery.manifest,
        descriptor,
        config.protocol_version,
        config.http,
        build_headers(header_pairs),
        config.timeout,
        config.verbose,
        nothing,
        nothing,
        nothing,
        false,
        Base.Ref(0),
        Dict{String,Vector{Function}}(),
        nothing,
        nothing,
    )
end

function select_transport(discovery::MCPDiscovery, choice)
    choice === nothing && return discovery.default_transport
    if choice isa MCPTransportDescriptor
        return choice
    elseif choice isa Symbol
        for descriptor in discovery.transports
            descriptor.kind == choice && return descriptor
        end
        throw(mcp_error(:transport_missing, "Discovery manifest does not expose a $(choice) transport"))
    else
        throw(ArgumentError("Unsupported transport selector $(choice)"))
    end
end

default_client_info() = Dict(
    "name" => "ModelContextProtocol.jl",
    "version" => string(Base.VERSION),
)

list_tools(client::MCPClient; cursor=nothing, limit=nothing, headers=nothing, timeout_ms=nothing) =
    list_entities(client, JSONRPC_METHOD_TOOLS_LIST; cursor=cursor, limit=limit, headers=headers, timeout_ms=timeout_ms)

list_prompts(client::MCPClient; cursor=nothing, limit=nothing, headers=nothing, timeout_ms=nothing) =
    list_entities(client, JSONRPC_METHOD_PROMPTS_LIST; cursor=cursor, limit=limit, headers=headers, timeout_ms=timeout_ms)

list_resources(client::MCPClient; cursor=nothing, limit=nothing, headers=nothing, timeout_ms=nothing) =
    list_entities(client, JSONRPC_METHOD_RESOURCES_LIST; cursor=cursor, limit=limit, headers=headers, timeout_ms=timeout_ms)

list_resource_templates(client::MCPClient; cursor=nothing, limit=nothing, headers=nothing, timeout_ms=nothing) =
    list_entities(client, JSONRPC_METHOD_RESOURCES_TEMPLATES_LIST; cursor=cursor, limit=limit, headers=headers, timeout_ms=timeout_ms)

function list_entities(client::MCPClient, method::AbstractString; cursor, limit, headers, timeout_ms)
    params = Dict{String,Any}()
    cursor !== nothing && (params["cursor"] = String(cursor))
    if limit !== nothing
        limit isa Integer || throw(ArgumentError("limit must be an integer"))
        params["limit"] = Int(limit)
    end
    payload = isempty(params) ? nothing : params
    return jsonrpc_call(client, method; params=payload, headers=headers, timeout_ms=timeout_ms)
end

function call_tool(client::MCPClient, name::AbstractString; arguments=nothing, headers=nothing, timeout_ms=nothing)
    params = Dict{String,Any}("name" => String(name))
    arguments !== nothing && (params["arguments"] = arguments)
    return jsonrpc_call(client, JSONRPC_METHOD_TOOLS_CALL; params=params, headers=headers, timeout_ms=timeout_ms)
end

function get_prompt(client::MCPClient, name::AbstractString; arguments=nothing, headers=nothing, timeout_ms=nothing)
    params = Dict{String,Any}("name" => String(name))
    arguments !== nothing && (params["arguments"] = arguments)
    return jsonrpc_call(client, JSONRPC_METHOD_PROMPTS_GET; params=params, headers=headers, timeout_ms=timeout_ms)
end

function read_resource(client::MCPClient, uri::AbstractString; headers=nothing, timeout_ms=nothing)
    params = Dict("uri" => String(uri))
    return jsonrpc_call(client, JSONRPC_METHOD_RESOURCES_READ; params=params, headers=headers, timeout_ms=timeout_ms)
end

get_resource(client::MCPClient, uri::AbstractString; headers=nothing, timeout_ms=nothing) =
    read_resource(client, uri; headers=headers, timeout_ms=timeout_ms)

function subscribe_resource(client::MCPClient, uri::AbstractString; mode::AbstractString="updates", headers=nothing, timeout_ms=nothing)
    params = Dict("uri" => String(uri), "mode" => String(mode))
    return jsonrpc_call(client, JSONRPC_METHOD_RESOURCES_SUBSCRIBE; params=params, headers=headers, timeout_ms=timeout_ms)
end

function set_log_level!(client::MCPClient, level::AbstractString; headers=nothing, timeout_ms=nothing)
    params = Dict("level" => String(level))
    return jsonrpc_call(client, JSONRPC_METHOD_LOGGING_SET_LEVEL; params=params, headers=headers, timeout_ms=timeout_ms)
end

function completion_complete(client::MCPClient, request::AbstractDict; headers=nothing, timeout_ms=nothing)
    params = Dict{String,Any}()
    for (k, v) in request
        params[String(k)] = v
    end
    return jsonrpc_call(client, JSONRPC_METHOD_COMPLETION_COMPLETE; params=params, headers=headers, timeout_ms=timeout_ms)
end

completion_complete(client::MCPClient, request::NamedTuple; headers=nothing, timeout_ms=nothing) =
    completion_complete(client, Dict{String,Any}(String(k) => v for (k, v) in pairs(request)); headers=headers, timeout_ms=timeout_ms)

function completion_complete(client::MCPClient; headers=nothing, timeout_ms=nothing, kwargs...)
    params = Dict{String,Any}(String(k) => v for (k, v) in kwargs)
    return completion_complete(client, params; headers=headers, timeout_ms=timeout_ms)
end

function merge_extra_params!(dest::Dict{String,Any}, extra)
    extra === nothing && return dest
    extra isa AbstractDict || throw(ArgumentError("extra_params must be a dictionary, got $(typeof(extra))"))
    for (k, v) in extra
        dest[String(k)] = v
    end
    return dest
end

function send_initialized_notification!(client::MCPClient; headers=nothing)
    jsonrpc_notification(client, JSONRPC_METHOD_NOTIFICATIONS_INITIALIZED; headers=headers)
    client.initialized = true
    return client
end

function initialize_client!(
    client::MCPClient;
    protocol_version::AbstractString=client.protocol_version,
    capabilities=nothing,
    client_info=default_client_info(),
    extra_params=nothing,
    headers=nothing,
    timeout_ms=nothing,
)
    params = Dict{String,Any}(
        "protocolVersion" => String(protocol_version),
    )
    capabilities_dict = capabilities === nothing ? Dict{String,Any}() : to_string_dict(capabilities)
    params["capabilities"] = capabilities_dict
    if client_info !== nothing
        info = to_string_dict(client_info)
        !isempty(info) && (params["clientInfo"] = info)
    end
    merge_extra_params!(params, extra_params)
    result = jsonrpc_call(client, JSONRPC_METHOD_INITIALIZE; params=params, headers=headers, timeout_ms=timeout_ms)
    session_data = result isa AbstractDict ? to_json_dict(result) : Dict{String,Any}()
    client.session = session_data
    session_id = get(session_data, "sessionId", nothing)
    client.session_id = session_id === nothing ? nothing : String(session_id)
    client.last_event_id = nothing
    send_initialized_notification!(client; headers=headers)
    return result
end

function cancel_request(client::MCPClient, request_id; reason=nothing, headers=nothing)
    params = Dict{String,Any}("requestId" => request_id)
    reason !== nothing && (params["reason"] = String(reason))
    jsonrpc_notification(client, JSONRPC_METHOD_NOTIFICATIONS_CANCELLED; params=params, headers=headers)
    return nothing
end

function open_event_stream(client::MCPClient; headers=nothing, timeout=nothing)
    client.initialized || throw(mcp_error(:not_initialized, "Client must be initialized before opening an event stream"))
    header_pairs = normalize_headers(headers)
    request_headers = build_request_headers(client, header_pairs)
    HTTP.setheader(request_headers, "Accept" => "text/event-stream")
    if client.last_event_id !== nothing
        HTTP.setheader(request_headers, "Last-Event-ID" => String(client.last_event_id))
    end
    timeout_settings = normalize_timeout(client, timeout)
    log_client_http_request(client, "GET", client.transport.url, request_headers, nothing)
    response = client.http.request(
        "GET",
        client.transport.url;
        headers=request_headers,
        status_exception=false,
        timeout_settings...,
    )
    log_client_http_response(client, "GET", client.transport.url, response; streaming=true)
    status = response.status
    status in 200:299 || throw(mcp_error(:http_error, "Event stream request failed with status $(status)"))
    return response
end

function register_notification_handler!(client::MCPClient, method::AbstractString, handler::Function)
    bucket = get!(client.notification_handlers, String(method)) do
        Function[]
    end
    push!(bucket, handler)
    return client
end

function clear_notification_handlers!(client::MCPClient; method=nothing)
    if method === nothing
        empty!(client.notification_handlers)
    else
        delete!(client.notification_handlers, String(method))
    end
    return client
end

function to_notification_payload(params)
    params === nothing && return Dict{String,Any}()
    if params isa AbstractDict
        return to_json_dict(params)
    else
        return params
    end
end

function notify_handlers!(client::MCPClient, method::String, params)
    handlers = get(client.notification_handlers, method, nothing)
    handlers === nothing && return
    for handler in handlers
        try
            handler(client, method, params)
        catch err
            @warn "Notification handler error" method err
        end
    end
    return nothing
end

function parse_sse_events(body::AbstractString)
    events = NamedTuple{(:event, :id, :data),Tuple{Union{Nothing,String},Union{Nothing,String},String}}[]
    event_name = nothing
    event_id = nothing
    data_lines = String[]
    function emit_event!()
        if isempty(data_lines) && (event_name === nothing || isempty(event_name))
            event_name = nothing
            event_id = nothing
            empty!(data_lines)
            return
        end
        data = join(data_lines, "\n")
        push!(events, (event=event_name, id=event_id, data=data))
        event_name = nothing
        event_id = nothing
        empty!(data_lines)
    end
    for raw_line in split(body, '\n')
        line = String(raw_line)
        if isempty(line)
            emit_event!()
            continue
        elseif startswith(line, ":")
            continue
        elseif startswith(line, "event:")
            event_name = strip(line[7:end])
        elseif startswith(line, "id:")
            event_id = strip(line[4:end])
        elseif startswith(line, "data:")
            push!(data_lines, strip(line[6:end]))
        elseif startswith(line, "retry:")
            continue
        else
            push!(data_lines, strip(line))
        end
    end
    !isempty(data_lines) && emit_event!()
    return events
end

function handle_jsonrpc_event!(client::MCPClient, payload)
    payload isa AbstractDict || return
    method_value = get(payload, "method", nothing)
    method_value === nothing && return
    if haskey(payload, "id") && payload["id"] !== nothing
        @warn "Server initiated requests are not yet supported" method=method_value
        return
    end
    params = get(payload, "params", Dict{String,Any}())
    notify_handlers!(client, String(method_value), to_notification_payload(params))
end

function handle_sse_event!(client::MCPClient, event)
    if event.id !== nothing && !isempty(String(event.id))
        client.last_event_id = String(event.id)
    end
    if event.event === nothing || event.event == "" || event.event == "jsonrpc"
        data_str = event.data
        isempty(data_str) && return
        payload = try
            JSON.parse(String(data_str))
        catch err
            @warn "Failed to parse JSON from event" err
            return
        end
        handle_jsonrpc_event!(client, payload)
    elseif event.event == "heartbeat"
        return
    else
        notify_handlers!(client, string("sse:", event.event), event.data)
    end
end

function event_listener_loop(client::MCPClient, poll_interval::Real, headers)
    while true
        try
            response = open_event_stream(client; headers=headers)
            body = String(response.body)
            for event in parse_sse_events(body)
                handle_sse_event!(client, event)
            end
        catch err
            if err isa InterruptException
                break
            elseif err isa MCPError
                @warn "Event listener encountered MCP error" err
                sleep(poll_interval)
                continue
            else
                @warn "Event listener error" err
            end
        end
        poll_interval > 0 && sleep(poll_interval)
    end
end

function start_event_listener!(client::MCPClient; poll_interval::Real=1.0, headers=nothing)
    client.initialized || throw(mcp_error(:not_initialized, "Client must be initialized before starting event listener"))
    stop_event_listener!(client)
    task = @async begin
        try
            event_listener_loop(client, poll_interval, headers)
        catch err
            if !(err isa InterruptException)
                @warn "Event listener task error" err
            end
        finally
            current = current_task()
            client.event_task === current && (client.event_task = nothing)
        end
    end
    client.event_task = task
    return task
end

function stop_event_listener!(client::MCPClient)
    task = client.event_task
    task === nothing && return nothing
    if !istaskdone(task)
        try
            Base.throwto(task, InterruptException())
        catch
        end
        try
            wait(task)
        catch err
            err isa InterruptException || @warn "Event listener stop error" err
        end
    end
    client.event_task = nothing
    return nothing
end
