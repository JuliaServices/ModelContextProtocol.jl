using Test
using HTTP
using JSON
using OAuth
using Sockets
using ModelContextProtocol

mutable struct StubState
    headers::Vector{Dict{String,String}}
    cancellations::Vector{Dict{String,Any}}
    timeouts::Vector{Union{Nothing,Int}}
    log_levels::Vector{String}
    completion_requests::Vector{Dict{String,Any}}
end

StubState() = StubState(Dict{String,String}[], Dict{String,Any}[], Union{Nothing,Int}[], String[], Dict{String,Any}[])

function record_headers!(state::StubState, req::HTTP.Request)
    header_map = Dict{String,String}()
    for (name, value) in req.headers
        header_map[String(name)] = String(value)
    end
    push!(state.headers, header_map)
end

function start_mcp_test_server()
    config = MCPServerConfig(
        name="Stub MCP Server",
        version="0.1.0",
        description="Test server",
    )
    server = MCPServer(config)
    state = StubState()
    set_request_hook!(server) do req
        record_headers!(state, req)
    end
    echo_handler = function (context::MCPRequestContext, args::Dict{String,Any})
        push!(state.timeouts, context.timeout_ms)
        message = get(args, "message", "")
        return Dict(
            "content" => [Dict("type" => "text", "text" => String(message))],
            "structuredContent" => Dict(),
            "annotations" => Dict("echoed" => true),
        )
    end
    register_tool!(
        server;
        name="echo",
        handler=echo_handler,
        title="Echo",
        description="Echo back input text",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict("message" => Dict("type" => "string")),
            "required" => ["message"],
        ),
        output_schema=Dict("type" => "object"),
        annotations=Dict("category" => "utility"),
    )
    prompt_handler = function (_::MCPRequestContext, args::Dict{String,Any})
        topic = get(args, "topic", "friend")
        return Dict("messages" => [
            Dict(
                "role" => "assistant",
                "content" => [Dict("type" => "text", "text" => "Hello $(topic)!")],
            ),
        ])
    end
    register_prompt!(
        server;
        name="hello_prompt",
        description="Greet the user",
        handler=prompt_handler,
    )
    resource_handler = function (_::MCPRequestContext, ::Dict{String,Any})
        return Dict("contents" => [
            Dict("type" => "text", "text" => "Hello from stub resource"),
        ])
    end
    register_resource!(
        server;
        uri="memory://welcome",
        title="Welcome Message",
        description="Static greeting",
        annotations=Dict("kind" => "greeting"),
        size=32,
        handler=resource_handler,
    )
    register_resource_template!(
        server;
        name="memory_template",
        description="Create memory resources",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict("name" => Dict("type" => "string")),
        ),
        handler=(::MCPRequestContext, args::Dict{String,Any}) -> Dict("uri" => string("memory://", get(args, "name", "template"))),
    )
    set_cancellation_handler!(server) do context, params
        session_id = context.session === nothing ? nothing : context.session.id
        push!(state.cancellations, Dict("sessionId" => session_id, "params" => params))
    end
    set_logging_handler!(server) do _context, level
        push!(state.log_levels, level)
    end
    set_completion_handler!(server) do _context, params
        push!(state.completion_requests, ModelContextProtocol.to_json_dict(params))
        prompt = get(params, "prompt", "")
        return Dict(
            "choices" => [
                Dict(
                    "id" => "choice-1",
                    "content" => [Dict("type" => "text", "text" => string("Echo:", " ", prompt))],
                ),
            ],
        )
    end
    http_server = serve_mcp_http(server; host="127.0.0.1", port=0, verbose=false)
    return state, http_server
end

stop_mcp_test_server(http_server::MCPHTTPServer) = stop_mcp_server(http_server)

function stub_protected_resource(base::String)
    return JSON.json(Dict(
        "resource" => string(base, "/resource"),
        "authorization_servers" => [string(base, "/issuer")],
        "scopes_supported" => ["openid", "profile"],
    ))
end

function start_auth_stub_server()
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/.well-known/auth-required.json", req -> begin
        host = HTTP.header(req, "Host")
        base = string("http://", host)
        header = "Bearer resource_metadata=\"$(base)/.well-known/protected-resource\" scope=\"openid profile\""
        HTTP.Response(401, ["WWW-Authenticate" => header], "")
    end)
    HTTP.register!(router, "GET", "/.well-known/protected-resource", req -> begin
        host = HTTP.header(req, "Host")
        base = string("http://", host)
        HTTP.Response(200, ["Content-Type" => "application/json"], stub_protected_resource(base))
    end)
    server = HTTP.serve!(router, "127.0.0.1", 0; verbose=false)
    port = ModelContextProtocol.bound_http_port(server)
    base = "http://127.0.0.1:$(port)"
    return server, base
end

stop_auth_stub_server(server) = close(server)

@testset "MCP client over HTTP" begin
    state, http_server = start_mcp_test_server()
    base = base_url(http_server)
    try
        discovery = discover_server(base)
        @test discovery.default_transport !== nothing
        client = prepare_manual_client(discovery; headers=["X-Test" => "alpha"])
        manifest_entry = discovery.manifest["model_context_protocols"][1]
        @test manifest_entry["capabilities"]["tools"] isa AbstractDict

        init = initialize_client!(client; capabilities=Dict("tools" => Dict("listChanged" => true)))
        @test get(init, "serverInfo", Dict())["name"] == "Stub MCP Server"
        @test haskey(get(init, "capabilities", Dict()), "tools")
        @test !haskey(init, "sessionId")
        @test client.session_id !== nothing
        @test client.initialized
        @test isempty(ping(client))

        log_events = Dict{String,Any}[]
        resource_events = Dict{String,Any}[]
        tool_list_changes = String[]
        client_requests = String[]

        register_notification_handler!(client, "notifications/message", (__, _, params) -> begin
            payload = params isa AbstractDict ? ModelContextProtocol.to_json_dict(params) : Dict{String,Any}("value" => params)
            push!(log_events, payload)
            nothing
        end)
        register_notification_handler!(client, "notifications/resources/updated", (__, _, params) -> begin
            payload = params isa AbstractDict ? ModelContextProtocol.to_json_dict(params) : Dict{String,Any}("value" => params)
            push!(resource_events, payload)
            nothing
        end)
        register_notification_handler!(client, "notifications/tools/list_changed", (__, _, __) -> begin
            push!(tool_list_changes, "tools")
            nothing
        end)
        register_request_handler!(client, "sampling/createMessage", (__, method, params, id) -> begin
            @test method == "sampling/createMessage"
            @test id == "server-request-1"
            @test haskey(params, "messages")
            push!(client_requests, String(id))
            Dict(
                "role" => "assistant",
                "content" => [Dict("type" => "text", "text" => "sampled")],
                "model" => "stub-model",
            )
        end)

        tools = list_tools(client; timeout_ms=5000)
        @test length(get(tools, "tools", [])) == 1
        tool_info = tools["tools"][1]
        @test tool_info["annotations"]["category"] == "utility"
        @test tool_info["outputSchema"]["type"] == "object"
        @test any(h -> get(h, "Mcp-Timeout-Ms", "") == "5000", state.headers)

        echo = call_tool(client, "echo"; arguments=Dict("message" => "hello world"), timeout_ms=2500)
        content = echo["content"][1]["text"]
        @test content == "hello world"
        @test echo["annotations"]["echoed"]
        @test state.timeouts[end] == 2500

        prompts = list_prompts(client)
        @test prompts["prompts"][1]["name"] == "hello_prompt"

        prompt = get_prompt(client, "hello_prompt"; arguments=Dict("topic" => "Julia"))
        @test occursin("Julia", prompt["messages"][1]["content"][1]["text"])

        resources = list_resources(client)
        @test resources["resources"][1]["uri"] == "memory://welcome"
        @test resources["resources"][1]["title"] == "Welcome Message"
        @test resources["resources"][1]["annotations"]["kind"] == "greeting"
        @test resources["resources"][1]["size"] == 32

        resource = read_resource(client, "memory://welcome")
        @test resource["contents"][1]["text"] == "Hello from stub resource"

        @test any(h -> get(h, "X-Test", "") == "alpha", state.headers)
        @test any(h -> any(lowercase(k) == "mcp-protocol-version" && v == ModelContextProtocol.DEFAULT_PROTOCOL_VERSION for (k, v) in h), state.headers)
        @test any(h -> any(lowercase(k) == "mcp-session-id" && !isempty(v) for (k, v) in h), state.headers)
        @test any(h -> any(lowercase(k) == "accept" && occursin("text/event-stream", lowercase(v)) for (k, v) in h), state.headers)

        enqueue_server_event!(http_server.server, client.session_id, "message", Dict("text" => "queued"))
        stream_resp = open_event_stream(client)
        stream_headers = Dict{String,String}(lowercase(String(k)) => String(v) for (k, v) in stream_resp.headers)
        @test stream_resp.status == 200
        @test stream_headers["content-type"] == "text/event-stream"
        @test stream_headers["mcp-session-id"] == client.session_id
        body_str = String(stream_resp.body)
        @test occursin("retry: 15000", body_str)
        @test occursin("event: message", body_str)
        @test occursin("data: {\"text\":\"queued\"}", body_str)

        stream_resp2 = open_event_stream(client)
        body_str2 = String(stream_resp2.body)
        @test occursin("event: heartbeat", body_str2)

        listener = start_event_listener!(client; poll_interval=0.1)
        try
            log_message!(http_server.server; message="test-event", level="warning", session_id=client.session_id)
            sleep(0.2)
            @test any(evt -> get(evt, "level", "") == "warning" && get(evt, "data", "") == "test-event", log_events)

            result_level = set_log_level!(client, "debug")
            @test result_level["level"] == "debug"
            @test !isempty(state.log_levels)
            @test state.log_levels[end] == "debug"

            register_tool!(
                http_server.server;
                name="reverse",
                description="Reverse input text",
                handler=(::MCPRequestContext, args::Dict{String,Any}) -> Dict(
                    "content" => [Dict("type" => "text", "text" => reverse(String(get(args, "message", ""))))],
                ),
            )
            sleep(0.2)
            @test !isempty(tool_list_changes)

            paged = list_tools(client; limit=1)
            @test length(get(paged, "tools", [])) == 1
            @test haskey(paged, "nextCursor")
            next_cursor = paged["nextCursor"]
            paged2 = list_tools(client; cursor=next_cursor)
            @test length(get(paged2, "tools", [])) >= 1

            templates = list_resource_templates(client)
            @test !isempty(get(templates, "resourceTemplates", []))
            @test templates["resourceTemplates"][1]["name"] == "memory_template"

            sub = subscribe_resource(client, "memory://welcome")
            @test isempty(sub)
            unsub = unsubscribe_resource(client, "memory://welcome")
            @test isempty(unsub)
            subscribe_resource(client, "memory://welcome")
            notify_resource_updated!(http_server.server, "memory://welcome"; annotations=Dict("kind" => "greeting"))
            sleep(0.2)
            @test any(evt -> evt["uri"] == "memory://welcome", resource_events)

            enqueue_server_event!(
                http_server.server,
                client.session_id,
                "jsonrpc",
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => "server-request-1",
                    "method" => "sampling/createMessage",
                    "params" => Dict("messages" => Any[]),
                ),
            )
            request_stream = open_event_stream(client)
            for event in ModelContextProtocol.parse_sse_events(String(request_stream.body))
                ModelContextProtocol.handle_sse_event!(client, event)
            end
            @test client_requests == ["server-request-1"]

            completion = completion_complete(client; prompt="hello")
            @test completion["choices"][1]["content"][1]["text"] == "Echo: hello"
            @test !isempty(state.completion_requests)
            @test state.completion_requests[end]["prompt"] == "hello"
        finally
            stop_event_listener!(client)
        end

        cancel_request(client, "req-1"; reason="no-op")
        @test !isempty(state.cancellations)
        cancel_entry = state.cancellations[end]
        @test cancel_entry["sessionId"] == client.session_id
        @test cancel_entry["params"]["requestId"] == "req-1"

        token_data = JSON.Object(Dict{String,Any}("access_token" => "stubtoken", "token_type" => "Bearer"))
        token = OAuth.TokenResponse(token_data)
        attach_token!(client, token)
        list_tools(client)
        @test any(h -> get(h, "Authorization", "") == "Bearer stubtoken", state.headers)
        response = terminate_session!(client)
        @test response.status in (200, 202, 204, 405)
        @test client.session_id === nothing
    finally
        stop_mcp_test_server(http_server)
    end
end

@testset "HTTP transport edge cases" begin
    @test ModelContextProtocol.normalize_host_for_origin("[::1]:4321") == "[::1]"
    @test ModelContextProtocol.is_loopback_host("[::1]:4321")

    _state, http_server = start_mcp_test_server()
    base = base_url(http_server)
    try
        discovery = discover_server(base)
        client = prepare_manual_client(discovery)
        ModelContextProtocol.jsonrpc_call(
            client,
            "initialize";
            params=Dict(
                "protocolVersion" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict("name" => "edge-test", "version" => "0.1.0"),
            ),
        )
        @test client.session_id !== nothing

        body = JSON.json(Dict("jsonrpc" => "2.0", "id" => "edge-1", "method" => "ping"))
        response = HTTP.request(
            "POST",
            client.transport.url;
            headers=[
                "Content-Type" => "application/json",
                "Accept" => "application/json, text/event-stream",
                "MCP-Protocol-Version" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "MCP-Session-Id" => client.session_id,
            ],
            body=body,
            status_exception=false,
        )
        @test response.status == 200
        payload = JSON.parse(String(response.body))
        @test payload["error"]["code"] == -32002
        @test occursin("not initialized", payload["error"]["message"])
    finally
        stop_mcp_test_server(http_server)
    end
end

@testset "Discovery auth challenges" begin
    server, base = start_auth_stub_server()
    try
        err = try
            discover_server(base; path="/.well-known/auth-required.json")
            nothing
        catch e
            e
        end
        @test err isa MCPAuthenticationRequired
        challenge = err.challenges[1]
        @test challenge.resource_metadata == string(base, "/.well-known/protected-resource")
        @test "openid" in challenge.scopes
    finally
        stop_auth_stub_server(server)
    end
end
