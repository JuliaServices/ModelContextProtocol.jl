using Logging

const JSONRPC_METHOD_INITIALIZE = "initialize"
const JSONRPC_METHOD_NOTIFICATIONS_INITIALIZED = "notifications/initialized"
const JSONRPC_METHOD_NOTIFICATIONS_CANCELLED = "notifications/cancelled"
const JSONRPC_METHOD_TOOLS_LIST = "tools/list"
const JSONRPC_METHOD_TOOLS_CALL = "tools/call"
const JSONRPC_METHOD_PROMPTS_LIST = "prompts/list"
const JSONRPC_METHOD_PROMPTS_GET = "prompts/get"
const JSONRPC_METHOD_RESOURCES_LIST = "resources/list"
const JSONRPC_METHOD_RESOURCES_READ = "resources/read"
const JSONRPC_METHOD_RESOURCES_TEMPLATES_LIST = "resources/templates/list"
const JSONRPC_METHOD_RESOURCES_SUBSCRIBE = "resources/subscribe"
const JSONRPC_METHOD_COMPLETION_COMPLETE = "completion/complete"
const JSONRPC_METHOD_LOGGING_SET_LEVEL = "logging/setLevel"
const JSONRPC_METHOD_NOTIFICATIONS_MESSAGE = "notifications/message"
const JSONRPC_METHOD_NOTIFICATIONS_TOOLS_LIST_CHANGED = "notifications/tools/list_changed"
const JSONRPC_METHOD_NOTIFICATIONS_PROMPTS_LIST_CHANGED = "notifications/prompts/list_changed"
const JSONRPC_METHOD_NOTIFICATIONS_RESOURCES_LIST_CHANGED = "notifications/resources/list_changed"
const JSONRPC_METHOD_NOTIFICATIONS_RESOURCE_TEMPLATES_LIST_CHANGED = "notifications/resources/templates/list_changed"
const JSONRPC_METHOD_NOTIFICATIONS_RESOURCES_UPDATED = "notifications/resources/updated"

const JSONRPC_VERSION = "2.0"
const JSONRPC_TIMEOUT = (connecttimeout=10, readtimeout=120)

function client_request_body_text(body)
    body === nothing && return ""
    return body isa AbstractString ? String(body) : String(body)
end

function client_response_body_text(response::HTTP.Response; streaming::Bool)
    if streaming
        return "(streaming body not logged)"
    end
    try
        return String(response.body)
    catch err
        return string("(unavailable: ", sprint(showerror, err), ")")
    end
end

function log_client_http_request(client::MCPClient, method::AbstractString, url::AbstractString, headers::HTTP.Headers, body)
    client.verbose || return
    header_pairs = headers_to_pairs(headers)
    request_body = client_request_body_text(body)
    request = HTTP.Request(String(method), String(url), header_pairs, request_body)
    println("MCP client HTTP request:")
    println(request)
end

function log_client_http_response(client::MCPClient, method::AbstractString, url::AbstractString, response::HTTP.Response; streaming::Bool=false)
    client.verbose || return
    header_pairs = headers_to_pairs(response.headers)
    body_text = client_response_body_text(response; streaming=streaming)
    printable_response = HTTP.Response(response.status, header_pairs, body_text)
    println("MCP client HTTP response:")
    println(printable_response)
end

function jsonrpc_call(
    client::MCPClient,
    method::AbstractString;
    params=nothing,
    notification::Bool=false,
    headers=nothing,
    timeout=nothing,
    timeout_ms=nothing,
)
    ensure_http_transport(client.transport)
    ensure_client_readiness(client, String(method), notification)
    payload = Dict{String,Any}(
        "jsonrpc" => JSONRPC_VERSION,
        "method" => String(method),
    )
    normalized_params = normalize_params(params)
    normalized_params === nothing || (payload["params"] = normalized_params)
    if !notification
        client.next_id[] += 1
        payload["id"] = string(client.next_id[])
    end
    body = JSON.json(payload)
    header_pairs = normalize_headers(headers)
    if timeout_ms !== nothing
        timeout_value = normalize_timeout_ms(timeout_ms)
        push!(header_pairs, normalize_pair("Mcp-Timeout-Ms", string(timeout_value)))
    end
    response = submit_jsonrpc_request(client, body; headers=header_pairs, timeout=timeout)
    notification && return nothing
    isempty(response.body) && throw(mcp_error(:jsonrpc_error, "JSON-RPC response from $(client.transport.url) was empty"))
    data = parse_jsonrpc_response(response.body)
    return get(data, "result", nothing)
end

jsonrpc_notification(client::MCPClient, method::AbstractString; params=nothing, headers=nothing) =
    jsonrpc_call(client, method; params=params, notification=true, headers=headers)

function submit_jsonrpc_request(client::MCPClient, body; headers, timeout)
    header_pairs = normalize_headers(headers)
    request_headers = build_request_headers(client, header_pairs)
    timeout_settings = normalize_timeout(client, timeout)
    log_client_http_request(client, "POST", client.transport.url, request_headers, body)
    response = client.http.request(
        "POST",
        client.transport.url;
        headers=request_headers,
        body=body,
        status_exception=false,
        timeout_settings...,
    )
    log_client_http_response(client, "POST", client.transport.url, response)
    status = response.status
    if status in 200:299 || status == 204
        return response
    elseif status == 401
        challenges = extract_auth_challenges(response.headers)
        body_str = String(response.body)
        throw(MCPAuthenticationRequired(status, challenges, isempty(body_str) ? nothing : body_str))
    else
        msg = try
            String(response.body)
        catch
            ""
        end
        throw(mcp_error(:http_error, "JSON-RPC request failed with status $(status): $(msg)"))
    end
end

function parse_jsonrpc_response(body)
    data = JSON.parse(String(body))
    data isa AbstractDict || throw(mcp_error(:jsonrpc_error, "JSON-RPC response must be a JSON object"))
    version = get(data, "jsonrpc", nothing)
    version == JSONRPC_VERSION || throw(mcp_error(:jsonrpc_error, "Unsupported JSON-RPC version $(version)"))
    if haskey(data, "error") && data["error"] !== nothing
        err = data["error"]
        if err isa AbstractDict
            code = get(err, "code", "unknown")
            message = get(err, "message", "JSON-RPC error")
            details = haskey(err, "data") ? string("; data=", JSON.json(err["data"])) : ""
            throw(mcp_error(:jsonrpc_error, "JSON-RPC error (code=$(code)): $(message)$(details)"))
        else
            throw(mcp_error(:jsonrpc_error, "JSON-RPC error: $(err)"))
        end
    end
    haskey(data, "result") || throw(mcp_error(:jsonrpc_error, "JSON-RPC response missing result field"))
    return data
end

function build_request_headers(client::MCPClient, extra::Vector{HeaderPair})
    headers = HTTP.Headers(client.headers)
    HTTP.setheader(headers, "Content-Type" => "application/json")
    HTTP.setheader(headers, "Accept" => "application/json, text/event-stream")
    HTTP.setheader(headers, "MCP-Protocol-Version" => client.protocol_version)
    if client.auth_token !== nothing
        HTTP.setheader(headers, "Authorization" => authorization_value(client.auth_token))
    end
    if client.session_id !== nothing
        HTTP.setheader(headers, "Mcp-Session-Id" => String(client.session_id))
    end
    for (name, value) in extra
        HTTP.setheader(headers, name => value)
    end
    return headers
end

authorization_value(token::TokenResponse) = string(token.token_type, " ", token.access_token)

function normalize_params(params)
    params === nothing && return nothing
    if params isa NamedTuple
        return Dict{String,Any}(String(k) => v for (k, v) in pairs(params))
    elseif params isa AbstractDict
        dict = Dict{String,Any}()
        for (k, v) in params
            dict[String(k)] = v
        end
        return dict
    else
        return params
    end
end

function ensure_http_transport(transport::MCPTransportDescriptor)
    transport.kind == :http || throw(mcp_error(:transport_unsupported, "Only HTTP transports are supported (got $(transport.kind))"))
end

function ensure_client_readiness(client::MCPClient, method::AbstractString, notification::Bool)
    if method == JSONRPC_METHOD_INITIALIZE
        return
    elseif method == JSONRPC_METHOD_NOTIFICATIONS_INITIALIZED
        client.session_id === nothing && throw(mcp_error(:session_required, "Cannot send notifications/initialized before establishing a session"))
        return
    end
    client.initialized || throw(mcp_error(:not_initialized, "Client must complete initialization before calling $(method)"))
    return
end

function normalize_timeout(client::MCPClient, timeout_override)
    if timeout_override === nothing
        return client.timeout
    elseif timeout_override isa NamedTuple
        return (; client.timeout..., timeout_override...)
    else
        throw(ArgumentError("timeout must be provided as a NamedTuple, got $(typeof(timeout_override))"))
    end
end

function normalize_timeout_ms(timeout_ms)
    timeout_ms isa Integer || throw(ArgumentError("timeout_ms must be provided as an integer number of milliseconds"))
    timeout_ms > 0 || throw(ArgumentError("timeout_ms must be positive"))
    return Int(timeout_ms)
end
