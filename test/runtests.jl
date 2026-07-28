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
        return MCPToolResult(
            content=[MCPTextContent(text=String(message))],
            structured_content=(;),
            annotations=Dict("echoed" => true),
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

function jsonrpc_http_request(method::String; id="1", params=Dict{String,Any}(), session_id=nothing)
    headers = [
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
        "MCP-Protocol-Version" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
    ]
    session_id !== nothing && push!(headers, "MCP-Session-Id" => session_id)
    body = Dict{String,Any}("jsonrpc" => "2.0", "method" => method)
    id !== nothing && (body["id"] = id)
    isempty(params) || (body["params"] = params)
    return HTTP.Request("POST", "/v1/mcp", headers, codeunits(JSON.json(body)))
end

Base.@kwdef struct StaticEchoArgs
    message::String=""
end

struct StaticEchoHandler end

function (::StaticEchoHandler)(
    ::ModelContextProtocol.StaticMCPRequestContext,
    arguments::JSON.JSONText,
)
    parsed = JSON.parse(arguments.value, StaticEchoArgs)
    return ModelContextProtocol.StaticMCPToolResult(
        text=parsed.message,
        structured_content=JSON.JSONText(JSON.json((; echoed=parsed.message))),
    )
end

function static_test_server()
    tool = ModelContextProtocol.StaticMCPTool(
        name="echo",
        title="Echo",
        description="Return the supplied message.",
        input_schema=JSON.JSONText(
            "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
        ),
        annotations=JSON.JSONText("{\"readOnlyHint\":true}"),
        handler=StaticEchoHandler(),
    )
    return ModelContextProtocol.StaticMCPServer(
        [tool];
        name="Static Test",
        version="0.1.0",
        description="Static MCP test server.",
        instructions="Use the echo tool.",
    )
end

@testset "Static tools server" begin
    server = static_test_server()
    initialize = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request(
            "initialize";
            id=1,
            params=Dict(
                "protocolVersion" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict("name" => "static-test", "version" => "0.1.0"),
            ),
        ),
    )
    @test initialize.status == 200
    session_id = HTTP.header(initialize, "MCP-Session-Id")
    @test !isempty(session_id)
    initialize_payload = JSON.parse(String(initialize.body))
    @test initialize_payload["id"] == 1
    @test initialize_payload["result"]["serverInfo"]["name"] == "Static Test"
    @test initialize_payload["result"]["capabilities"]["tools"]["listChanged"] == false

    before_initialized = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request("tools/list"; session_id),
    )
    @test before_initialized.status == 400

    initialized = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request("notifications/initialized"; id=nothing, session_id),
    )
    @test initialized.status == 202

    listed = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request("tools/list"; session_id),
    )
    @test listed.status == 200
    listed_payload = JSON.parse(String(listed.body))
    @test only(listed_payload["result"]["tools"])["name"] == "echo"
    @test only(listed_payload["result"]["tools"])["inputSchema"]["required"] == ["message"]

    called = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request(
            "tools/call";
            session_id,
            params=Dict("name" => "echo", "arguments" => Dict("message" => "hello\n\"world\"")),
        ),
    )
    @test called.status == 200
    called_payload = JSON.parse(String(called.body))
    @test called_payload["result"]["structuredContent"] == Dict("echoed" => "hello\n\"world\"")
    @test called_payload["result"]["content"][1]["text"] == "hello\n\"world\""

    unknown = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        jsonrpc_http_request(
            "tools/call";
            session_id,
            params=Dict("name" => "missing", "arguments" => Dict{String,Any}()),
        ),
    )
    @test JSON.parse(String(unknown.body))["error"]["code"] == -32602

    stream = ModelContextProtocol.handle_static_stream_request(
        server,
        HTTP.Request("GET", "/v1/mcp"),
    )
    @test stream.status == 405

    deleted = ModelContextProtocol.handle_static_session_delete(
        server,
        HTTP.Request("DELETE", "/v1/mcp", ["MCP-Session-Id" => session_id]),
    )
    @test deleted.status == 204
end

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

@testset "Session stores" begin
    shared_store = InMemorySessionStore()
    config = MCPServerConfig(name="Shared Store Server", version="0.1.0", session_store=shared_store)
    server_a = MCPServer(config)
    server_b = MCPServer(config)

    init_response = ModelContextProtocol.handle_jsonrpc_request(
        server_a,
        jsonrpc_http_request(
            "initialize";
            id="init",
            params=Dict(
                "protocolVersion" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "capabilities" => Dict{String,Any}(),
                "clientInfo" => Dict("name" => "store-test", "version" => "0.1.0"),
            ),
        ),
    )
    session_id = HTTP.header(init_response, "MCP-Session-Id")
    @test init_response.status == 200
    @test !isempty(session_id)
    @test length(ModelContextProtocol.list_sessions(shared_store)) == 1

    initialized_response = ModelContextProtocol.handle_jsonrpc_request(
        server_b,
        jsonrpc_http_request("notifications/initialized"; id=nothing, session_id),
    )
    @test initialized_response.status == 202
    session = ModelContextProtocol.find_session(shared_store, session_id)
    @test session !== nothing
    @test session.initialized

    ping_response = ModelContextProtocol.handle_jsonrpc_request(
        server_a,
        jsonrpc_http_request("ping"; id="ping", session_id),
    )
    @test ping_response.status == 200
    ping_payload = JSON.parse(String(ping_response.body))
    @test ping_payload["result"] == Dict{String,Any}()

    event_id = ModelContextProtocol.enqueue_server_event!(server_b, session_id, "message", Dict("text" => "shared"))
    @test event_id == "1"
    stream_response = ModelContextProtocol.handle_stream_request(
        server_a,
        HTTP.Request(
            "GET",
            "/v1/mcp",
            [
                "Accept" => "text/event-stream",
                "MCP-Protocol-Version" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "MCP-Session-Id" => session_id,
            ],
            UInt8[],
        ),
    )
    @test stream_response.status == 200
    streamed_session = ModelContextProtocol.find_session(shared_store, session_id)
    @test streamed_session !== nothing
    @test isempty(streamed_session.pending_events)
    @test streamed_session.event_sequence == 1

    delete_response = ModelContextProtocol.handle_session_delete(
        server_b,
        HTTP.Request(
            "DELETE",
            "/v1/mcp",
            [
                "MCP-Protocol-Version" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                "MCP-Session-Id" => session_id,
            ],
            UInt8[],
        ),
    )
    @test delete_response.status == 202
    @test ModelContextProtocol.find_session(shared_store, session_id) === nothing
end

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
            @test timedwait(
                () -> any(
                    evt -> get(evt, "level", "") == "warning" && get(evt, "data", "") == "test-event",
                    log_events,
                ),
                5.0;
                pollint=0.05,
            ) == :ok

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
            @test timedwait(() -> !isempty(tool_list_changes), 5.0; pollint=0.05) == :ok

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
            @test timedwait(
                () -> any(evt -> evt["uri"] == "memory://welcome", resource_events),
                5.0;
                pollint=0.05,
            ) == :ok

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

        attach_token!(client, "Bearer rawtoken")
        list_tools(client)
        @test any(h -> get(h, "Authorization", "") == "Bearer rawtoken", state.headers)
        @test Base.get_extension(ModelContextProtocol, :ModelContextProtocolOAuthExt) !== nothing
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

@testset "MCP Apps" begin
    @testset "capability helpers" begin
        caps = ui_extension_capability()
        @test caps["extensions"][MCP_APPS_EXTENSION_ID]["mimeTypes"] == [MCP_APP_HTML_MIME_TYPE]
        merged = add_ui_extension_capability!(Dict{String,Any}("logging" => Dict{String,Any}()))
        @test haskey(merged, "logging")
        @test merged["extensions"][MCP_APPS_EXTENSION_ID]["mimeTypes"] == [MCP_APP_HTML_MIME_TYPE]
        existing = Dict{String,Any}("extensions" => Dict{String,Any}("acme/other" => Dict{String,Any}()))
        add_ui_extension_capability!(existing)
        @test haskey(existing["extensions"], "acme/other")
        @test haskey(existing["extensions"], MCP_APPS_EXTENSION_ID)
    end

    @testset "tool and resource meta" begin
        meta = ui_tool_meta("ui://acme/card")
        @test meta["ui"]["resourceUri"] == "ui://acme/card"
        @test meta["ui/resourceUri"] == "ui://acme/card"
        @test meta["ui"]["visibility"] == ["model", "app"]
        app_only = ui_tool_meta("ui://acme/card"; visibility=["app"])
        @test app_only["ui"]["visibility"] == ["app"]
        no_uri = ui_tool_meta()
        @test !haskey(no_uri, "ui/resourceUri")
        rmeta = ui_resource_meta()
        @test rmeta["ui"]["prefersBorder"] === true
        @test rmeta["ui"]["displayMode"] == "inline"
    end

    @testset "protocol version negotiation" begin
        server = MCPServer(name="apps", version="1.0.0", supported_protocol_versions=["2025-06-18"])
        session = ModelContextProtocol.MCPSession(id="s")
        respond(version) = ModelContextProtocol.initialize_response(server, session, Dict{String,Any}("protocolVersion" => version))["protocolVersion"]
        @test respond("2025-06-18") == "2025-06-18"
        @test respond(ModelContextProtocol.DEFAULT_PROTOCOL_VERSION) == ModelContextProtocol.DEFAULT_PROTOCOL_VERSION
        @test respond("1999-01-01") == ModelContextProtocol.DEFAULT_PROTOCOL_VERSION
        no_params = ModelContextProtocol.initialize_response(server, session, Dict{String,Any}())
        @test no_params["protocolVersion"] == ModelContextProtocol.DEFAULT_PROTOCOL_VERSION
    end

    @testset "mcp_app_html shell" begin
        html = mcp_app_html(
            app_name="acme-card",
            app_version="2.0.0",
            body="<main id=\"app\"></main>",
            css=".card{padding:16px}",
            script="mcpApp.onRender(function(data){document.getElementById('app').textContent=String(data);});",
        )
        for needle in (
            "<!doctype html>",
            "\"name\":\"acme-card\"",
            "\"version\":\"2.0.0\"",
            "\"protocolVersion\":\"$(MCP_APPS_UI_PROTOCOL_VERSION)\"",
            "ui/initialize",
            "appInfo",
            "appCapabilities",
            "ui/notifications/initialized",
            "ui/notifications/tool-result",
            "ui/notifications/size-changed",
            "ev.source !== window.parent",
            "tools/call",
            ".card{padding:16px}",
            "<main id=\"app\"></main>",
        )
            @test occursin(needle, html)
        end
        with_head = mcp_app_html(
            app_name="acme-card",
            body="<main></main>",
            head="<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">",
            css="@import url('https://fonts.googleapis.com/css2?family=Inter');",
        )
        @test occursin("<meta name=\"color-scheme\" content=\"light dark\">", with_head)
        @test occursin("<link rel=\"preconnect\"", with_head)
        # @import stays first in the stylesheet so it remains valid CSS
        @test occursin("<style>\n@import", with_head)
        @test_throws ArgumentError mcp_app_html(app_name="x", body="", script="var a=\"</script>\";")
        @test_throws ArgumentError mcp_app_html(app_name="x", body="", css="/*</style>*/")
        @test_throws ArgumentError mcp_app_html(app_name="x", body="<script>var a=1;</script>")
    end

    @testset "widget-backed server end to end" begin
        server = MCPServer(
            name="Apps Stub Server",
            version="0.1.0",
            capabilities=ui_extension_capability(),
            supported_protocol_versions=["2025-06-18"],
            missing_protocol_header=:ignore,
        )
        card = register_ui_resource!(
            server;
            uri="ui://apps-stub/card",
            html=mcp_app_html(app_name="apps-stub-card", body="<main id=\"app\"></main>"),
            name="apps-stub-card",
            title="Apps Stub Card",
            description="Test widget",
        )
        @test card isa MCPUIResource
        @test_throws ArgumentError register_ui_resource!(server; uri="https://not-ui", html="x")
        register_tool!(
            server;
            name="card-data",
            description="Returns data rendered by the card widget.",
            input_schema=Dict{String,Any}("type" => "object"),
            meta=ui_tool_meta(card),
            handler=(context, args) -> MCPToolResult(
                content=ui_tool_content("Card summary", card),
                structured_content=Dict{String,Any}("greeting" => "hi"),
            ),
        )
        http_server = serve_mcp_http(server; host="127.0.0.1", port=0)
        base = base_url(http_server)
        try
            discovery = discover_server(base)
            client = prepare_manual_client(discovery)
            init = initialize_client!(client; protocol_version="2025-06-18")
            @test init["protocolVersion"] == "2025-06-18"
            @test init["capabilities"]["extensions"][MCP_APPS_EXTENSION_ID]["mimeTypes"] == [MCP_APP_HTML_MIME_TYPE]

            tools = list_tools(client)
            tool = only(filter(t -> t["name"] == "card-data", tools["tools"]))
            @test tool["_meta"]["ui"]["resourceUri"] == "ui://apps-stub/card"
            @test tool["_meta"]["ui/resourceUri"] == "ui://apps-stub/card"

            resources = list_resources(client)
            resource = only(filter(r -> r["uri"] == "ui://apps-stub/card", resources["resources"]))
            @test resource["mimeType"] == MCP_APP_HTML_MIME_TYPE
            @test resource["_meta"]["ui"]["displayMode"] == "inline"

            contents = read_resource(client, "ui://apps-stub/card")
            entry = only(contents["contents"])
            @test entry["uri"] == "ui://apps-stub/card"
            @test entry["mimeType"] == MCP_APP_HTML_MIME_TYPE
            @test occursin("ui/initialize", entry["text"])

            result = call_tool(client, "card-data"; arguments=Dict{String,Any}())
            @test result["structuredContent"]["greeting"] == "hi"
            @test result["content"][1]["type"] == "text"
            embedded = result["content"][2]
            @test embedded["type"] == "resource"
            @test embedded["resource"]["uri"] == "ui://apps-stub/card"
            @test embedded["resource"]["mimeType"] == MCP_APP_HTML_MIME_TYPE
            @test embedded["resource"]["text"] == card.html
        finally
            stop_mcp_server(http_server)
        end
    end
end

@testset "Spec compliance fixes" begin
    @testset "deterministic list ordering and error codes" begin
        server = MCPServer(name="Order Server", version="0.1.0")
        for name in ("zeta", "alpha", "mid")
            register_tool!(
                server;
                name=name,
                handler=(::MCPRequestContext, ::Dict{String,Any}) -> Dict("content" => [Dict("type" => "text", "text" => name)]),
            )
        end
        for name in ("z_prompt", "a_prompt")
            register_prompt!(
                server;
                name=name,
                handler=(::MCPRequestContext, ::Dict{String,Any}) -> Dict("messages" => Any[]),
            )
        end
        for uri in ("memory://z", "memory://a")
            register_resource!(
                server;
                uri=uri,
                handler=(::MCPRequestContext, ::Dict{String,Any}) -> Dict("contents" => Any[]),
            )
        end

        init = ModelContextProtocol.handle_jsonrpc_request(
            server,
            jsonrpc_http_request(
                "initialize";
                id="init",
                params=Dict(
                    "protocolVersion" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                    "capabilities" => Dict{String,Any}(),
                ),
            ),
        )
        session_id = HTTP.header(init, "MCP-Session-Id")
        ModelContextProtocol.handle_jsonrpc_request(
            server,
            jsonrpc_http_request("notifications/initialized"; id=nothing, session_id),
        )
        respond(method; params=Dict{String,Any}()) = JSON.parse(String(ModelContextProtocol.handle_jsonrpc_request(
            server,
            jsonrpc_http_request(method; params, session_id),
        ).body))

        listed = respond("tools/list")
        @test [t["name"] for t in listed["result"]["tools"]] == ["alpha", "mid", "zeta"]
        prompts = respond("prompts/list")
        @test [p["name"] for p in prompts["result"]["prompts"]] == ["a_prompt", "z_prompt"]
        resources = respond("resources/list")
        @test [r["uri"] for r in resources["result"]["resources"]] == ["memory://a", "memory://z"]

        unknown_tool = respond("tools/call"; params=Dict{String,Any}("name" => "missing"))
        @test unknown_tool["error"]["code"] == -32602
        unknown_prompt = respond("prompts/get"; params=Dict{String,Any}("name" => "missing"))
        @test unknown_prompt["error"]["code"] == -32602
        unknown_resource = respond("resources/read"; params=Dict{String,Any}("uri" => "memory://missing"))
        @test unknown_resource["error"]["code"] == -32002
    end

    @testset "streamed POST responses" begin
        router = HTTP.Router()
        HTTP.register!(router, "POST", "/mcp", req -> begin
            payload = JSON.parse(String(req.body))
            method = get(payload, "method", "")
            id = get(payload, "id", nothing)
            if method == "initialize"
                body = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => id,
                    "result" => Dict(
                        "protocolVersion" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
                        "capabilities" => Dict{String,Any}(),
                        "serverInfo" => Dict("name" => "Streamed Stub", "version" => "0.1.0"),
                    ),
                ))
                return HTTP.Response(200, ["Content-Type" => "application/json", "MCP-Session-Id" => "streamed-session"], body)
            elseif id === nothing
                return HTTP.Response(202)
            else
                notification = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "method" => "notifications/message",
                    "params" => Dict("level" => "info", "data" => "stream-note"),
                ))
                response = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => id,
                    "result" => Dict("tools" => [Dict("name" => "streamed")]),
                ))
                body = string(
                    "event: message\ndata: ", notification, "\n\n",
                    "data: ", response, "\n\n",
                )
                return HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
            end
        end)
        stub = HTTP.serve!(router, "127.0.0.1", 0; verbose=false)
        try
            port = ModelContextProtocol.bound_http_port(stub)
            transport = ModelContextProtocol.MCPTransportDescriptor(kind=:http, url="http://127.0.0.1:$(port)/mcp")
            discovery = ModelContextProtocol.MCPDiscovery(manifest=Dict{String,Any}(), transports=[transport], default_transport=transport)
            client = prepare_manual_client(discovery)
            initialize_client!(client)
            streamed_notes = String[]
            register_notification_handler!(client, "notifications/message", (__, _, params) -> begin
                push!(streamed_notes, String(get(params, "data", "")))
                nothing
            end)
            tools = list_tools(client)
            @test [t["name"] for t in tools["tools"]] == ["streamed"]
            @test streamed_notes == ["stream-note"]
        finally
            close(stub)
        end
    end
end

function modern_http_request(method::String; id="1", params=Dict{String,Any}(), version=ModelContextProtocol.PROTOCOL_VERSION_2026_07_28, mcp_method=method, mcp_name=nothing, header_version=version, include_meta=true)
    body_params = Dict{String,Any}(params)
    if include_meta
        meta = get(body_params, "_meta", Dict{String,Any}())
        meta = Dict{String,Any}(meta)
        get!(meta, ModelContextProtocol.META_PROTOCOL_VERSION, version)
        get!(meta, ModelContextProtocol.META_CLIENT_CAPABILITIES, Dict{String,Any}())
        body_params["_meta"] = meta
    end
    headers = [
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
    ]
    header_version !== nothing && push!(headers, "MCP-Protocol-Version" => header_version)
    mcp_method !== nothing && push!(headers, "Mcp-Method" => mcp_method)
    mcp_name !== nothing && push!(headers, "Mcp-Name" => mcp_name)
    body = Dict{String,Any}("jsonrpc" => "2.0", "method" => method, "params" => body_params)
    id !== nothing && (body["id"] = id)
    return HTTP.Request("POST", "/v1/mcp", headers, codeunits(JSON.json(body)))
end

@testset "MCP 2026-07-28" begin
    @testset "stateless server requests" begin
        server = MCPServer(name="Modern Server", version="1.2.3", instructions="Use the echo tool.")
        register_tool!(
            server;
            name="echo",
            handler=(::MCPRequestContext, args::Dict{String,Any}) -> Dict(
                "content" => [Dict("type" => "text", "text" => String(get(args, "message", "")))],
            ),
        )
        register_resource!(
            server;
            uri="memory://doc",
            handler=(::MCPRequestContext, ::Dict{String,Any}) -> Dict("contents" => Any[]),
        )
        respond(req) = ModelContextProtocol.handle_jsonrpc_request(server, req)

        discover = respond(modern_http_request("server/discover"))
        @test discover.status == 200
        discover_payload = JSON.parse(String(discover.body))["result"]
        @test discover_payload["resultType"] == "complete"
        @test ModelContextProtocol.PROTOCOL_VERSION_2026_07_28 in discover_payload["supportedVersions"]
        @test ModelContextProtocol.DEFAULT_PROTOCOL_VERSION in discover_payload["supportedVersions"]
        @test discover_payload["_meta"][ModelContextProtocol.META_SERVER_INFO]["name"] == "Modern Server"
        @test discover_payload["instructions"] == "Use the echo tool."
        @test discover_payload["ttlMs"] == 60_000

        listed = respond(modern_http_request("tools/list"))
        @test listed.status == 200
        listed_payload = JSON.parse(String(listed.body))["result"]
        @test listed_payload["resultType"] == "complete"
        @test listed_payload["ttlMs"] == 60_000
        @test listed_payload["cacheScope"] == "private"
        @test listed_payload["_meta"][ModelContextProtocol.META_SERVER_INFO]["version"] == "1.2.3"
        @test only(listed_payload["tools"])["name"] == "echo"

        called = respond(modern_http_request(
            "tools/call";
            params=Dict{String,Any}("name" => "echo", "arguments" => Dict("message" => "hi")),
            mcp_name="echo",
        ))
        @test called.status == 200
        called_payload = JSON.parse(String(called.body))["result"]
        @test called_payload["resultType"] == "complete"
        @test called_payload["content"][1]["text"] == "hi"

        missing_method_header = respond(modern_http_request("tools/list"; mcp_method=nothing))
        @test missing_method_header.status == 400
        @test JSON.parse(String(missing_method_header.body))["error"]["code"] == -32020

        name_mismatch = respond(modern_http_request(
            "tools/call";
            params=Dict{String,Any}("name" => "echo"),
            mcp_name="other",
        ))
        @test name_mismatch.status == 400
        @test JSON.parse(String(name_mismatch.body))["error"]["code"] == -32020

        version_mismatch = respond(modern_http_request("tools/list"; header_version="2025-11-25"))
        @test version_mismatch.status == 400
        @test JSON.parse(String(version_mismatch.body))["error"]["code"] == -32020

        unsupported = respond(modern_http_request("tools/list"; version="1900-01-01"))
        @test unsupported.status == 400
        unsupported_error = JSON.parse(String(unsupported.body))["error"]
        @test unsupported_error["code"] == -32022
        @test ModelContextProtocol.PROTOCOL_VERSION_2026_07_28 in unsupported_error["data"]["supported"]
        @test unsupported_error["data"]["requested"] == "1900-01-01"

        removed = respond(modern_http_request("ping"))
        @test removed.status == 404
        @test JSON.parse(String(removed.body))["error"]["code"] == -32601

        not_found = respond(modern_http_request(
            "resources/read";
            params=Dict{String,Any}("uri" => "memory://missing"),
            mcp_name="memory://missing",
        ))
        @test JSON.parse(String(not_found.body))["error"]["code"] == -32602

        encoded_name = string("=?base64?", ModelContextProtocol.base64encode("echo"), "?=")
        encoded = respond(modern_http_request(
            "tools/call";
            params=Dict{String,Any}("name" => "echo", "arguments" => Dict("message" => "enc")),
            mcp_name=encoded_name,
        ))
        @test encoded.status == 200
    end

    @testset "MRTR input_required round trip" begin
        server = MCPServer(name="MRTR Server", version="0.1.0")
        register_tool!(
            server;
            name="confirm-op",
            handler=(context::MCPRequestContext, args::Dict{String,Any}) -> begin
                responses = ModelContextProtocol.input_responses(context)
                if responses === nothing
                    return MCPInputRequired(
                        input_requests=Dict{String,Any}(
                            "approval" => Dict{String,Any}(
                                "method" => "elicitation/create",
                                "params" => Dict{String,Any}("mode" => "form", "message" => "Confirm?"),
                            ),
                        ),
                        request_state="state-token",
                    )
                end
                state = ModelContextProtocol.request_state(context)
                return Dict(
                    "content" => [Dict("type" => "text", "text" => "approved:$(state)")],
                )
            end,
        )
        respond(req) = JSON.parse(String(ModelContextProtocol.handle_jsonrpc_request(server, req).body))

        first_attempt = respond(modern_http_request(
            "tools/call";
            params=Dict{String,Any}("name" => "confirm-op"),
            mcp_name="confirm-op",
        ))["result"]
        @test first_attempt["resultType"] == "input_required"
        @test haskey(first_attempt["inputRequests"], "approval")
        @test first_attempt["requestState"] == "state-token"

        retry = respond(modern_http_request(
            "tools/call";
            id="2",
            params=Dict{String,Any}(
                "name" => "confirm-op",
                "inputResponses" => Dict{String,Any}("approval" => Dict{String,Any}("action" => "accept")),
                "requestState" => "state-token",
            ),
            mcp_name="confirm-op",
        ))["result"]
        @test retry["resultType"] == "complete"
        @test retry["content"][1]["text"] == "approved:state-token"
    end

    @testset "modern client end to end" begin
        state, http_server = start_mcp_test_server()
        base = base_url(http_server)
        register_tool!(
            http_server.server;
            name="noisy",
            handler=(context::MCPRequestContext, ::Dict{String,Any}) -> begin
                send_progress!(context; progress=1, total=2, message="halfway")
                send_log!(context, "info", "working")
                Dict("content" => [Dict("type" => "text", "text" => "done")])
            end,
        )
        try
            discovery = discover_server(base)
            client = prepare_manual_client(
                discovery;
                config=MCPClientConfig(protocol_version=ModelContextProtocol.PROTOCOL_VERSION_2026_07_28),
            )
            info = initialize_client!(client)
            @test ModelContextProtocol.PROTOCOL_VERSION_2026_07_28 in info["supportedVersions"]
            @test info["_meta"][ModelContextProtocol.META_SERVER_INFO]["name"] == "Stub MCP Server"

            tools = list_tools(client)
            @test tools["resultType"] == "complete"
            @test tools["ttlMs"] == 60_000
            @test "echo" in [t["name"] for t in tools["tools"]]

            echo = call_tool(client, "echo"; arguments=Dict("message" => "modern hello"))
            @test !is_input_required(echo)
            @test echo["content"][1]["text"] == "modern hello"
            @test any(h -> get(h, "Mcp-Method", "") == "tools/call", state.headers)
            @test any(h -> get(h, "Mcp-Name", "") == "echo", state.headers)

            progress_events = Dict{String,Any}[]
            log_events = Dict{String,Any}[]
            register_notification_handler!(client, "notifications/progress", (__, _, params) -> begin
                push!(progress_events, ModelContextProtocol.to_json_dict(params))
                nothing
            end)
            register_notification_handler!(client, "notifications/message", (__, _, params) -> begin
                push!(log_events, ModelContextProtocol.to_json_dict(params))
                nothing
            end)
            noisy = call_tool(
                client,
                "noisy";
                meta=Dict(
                    "progressToken" => "tok-1",
                    ModelContextProtocol.META_LOG_LEVEL => "info",
                ),
            )
            @test noisy["content"][1]["text"] == "done"
            @test length(progress_events) == 1
            @test progress_events[1]["progressToken"] == "tok-1"
            @test progress_events[1]["message"] == "halfway"
            @test length(log_events) == 1
            @test log_events[1]["data"] == "working"

            # without opt-in _meta, notifications are suppressed and the response is plain JSON
            quiet = call_tool(client, "noisy")
            @test quiet["content"][1]["text"] == "done"
            @test length(progress_events) == 1
            @test length(log_events) == 1

            acks = Dict{String,Any}[]
            list_changes = String[]
            register_notification_handler!(client, "notifications/subscriptions/acknowledged", (__, _, params) -> begin
                push!(acks, ModelContextProtocol.to_json_dict(params))
                nothing
            end)
            register_notification_handler!(client, "notifications/tools/list_changed", (__, _, __) -> begin
                push!(list_changes, "tools")
                nothing
            end)
            listen = listen_subscriptions!(client; tools_list_changed=true)
            @test timedwait(() -> !isempty(acks), 5.0; pollint=0.05) == :ok
            @test acks[1]["notifications"]["toolsListChanged"] == true
            @test acks[1]["_meta"][ModelContextProtocol.META_SUBSCRIPTION_ID] == listen.id

            register_tool!(
                http_server.server;
                name="late-arrival",
                handler=(::MCPRequestContext, ::Dict{String,Any}) -> Dict("content" => Any[]),
            )
            @test timedwait(() -> !isempty(list_changes), 5.0; pollint=0.05) == :ok

            close_subscription_listeners!(http_server.server)
            @test timedwait(() -> istaskdone(listen.task), 5.0; pollint=0.05) == :ok
        finally
            stop_mcp_test_server(http_server)
        end
    end
end

include("trim_compile_tests.jl")
