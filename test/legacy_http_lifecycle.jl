using Test, HTTP, JSON, ModelContextProtocol

@testset "Legacy HTTP session lifecycle" begin
    MCP = ModelContextProtocol
    @testset "Server preference $preferred" for preferred in ("2025-11-25", "2026-07-28")
        server = MCPServer(name="Legacy lifecycle", version="1.0.0", protocol_version=preferred,
            supported_protocol_versions=["2025-11-25", "2026-07-28"])
        http = serve_mcp_http(server; host="127.0.0.1", port=0)
        try
            transport = MCPTransportDescriptor(kind=:http, url=base_url(http) * "/v1/mcp")
            discovery = MCPDiscovery(manifest=Dict{String,Any}(), transports=[transport], default_transport=transport)
            new_client() = prepare_manual_client(discovery; config=MCPClientConfig(protocol_version="2025-11-25"))
            client = new_client()
            initialized = initialize_client!(client)
            @test initialized["protocolVersion"] == "2025-11-25"
            @test client.initialized
            session_id = client.session_id
            MCP.enqueue_server_event!(server, session_id, "message", Dict("text" => "legacy event"))
            streamed = try open_event_stream(client) catch error; error end
            @test streamed isa HTTP.Response
            if streamed isa HTTP.Response
                @test streamed.status == 200
                @test occursin("legacy event", String(streamed.body))
            end
            deleted = try terminate_session!(client) catch error; error end
            @test deleted isa HTTP.Response
            if deleted isa HTTP.Response
                @test deleted.status == 202
            end
            @test client.session_id === nothing
            @test !client.initialized
            @test !haskey(server.sessions, session_id)
            @test server.config.protocol_version == preferred

            client = new_client()
            initialize_client!(client)
            session_id = client.session_id
            MCP.enqueue_server_event!(server, session_id, "message", Dict("text" => "preserved event"))
            for method in ("GET", "DELETE"), (version, origin, status) in (
                ("1900-01-01", nothing, 400), ("2099-01-01", nothing, 400),
                (nothing, nothing, 400), ("", nothing, 400),
                ("2025-11-25", "https://untrusted.example", 403),
                ("2026-07-28", "https://untrusted.example", 403), ("2026-07-28", nothing, 405),
            )
                headers = ["Accept" => "text/event-stream", "MCP-Session-Id" => session_id]
                version === nothing || push!(headers, "MCP-Protocol-Version" => version)
                origin === nothing || push!(headers, "Origin" => origin)
                events_before = length(server.sessions[session_id].pending_events)
                response = HTTP.request(method, transport.url; headers, status_exception=false)
                @test response.status == status
                status == 405 && @test MCP.http_header_value(response.headers, "Allow") == "POST"
                @test haskey(server.sessions, session_id)
                if haskey(server.sessions, session_id)
                    @test length(server.sessions[session_id].pending_events) == events_before
                end
            end
        finally
            HTTP.forceclose(http.http)
        end
    end

    @testset "Unsupported legacy version and missing-header policy" begin
        modern_only = MCPServer(name="Modern only", version="1.0.0", protocol_version="2026-07-28",
            supported_protocol_versions=String[])
        for (method, handler) in (("GET", MCP.handle_stream_request), ("DELETE", MCP.handle_session_delete))
            response = handler(modern_only, HTTP.Request(method, "/v1/mcp",
                ["Accept" => "text/event-stream", "MCP-Protocol-Version" => "2025-11-25"]))
            @test response.status == 400
            @test isempty(modern_only.sessions)
        end
        for behavior in (:ignore, :warn)
            server = MCPServer(name="Legacy fallback", version="1.0.0", missing_protocol_header=behavior)
            request = HTTP.Request("GET", "/v1/mcp", ["Accept" => "text/event-stream"])
            if behavior == :warn
                @test_logs (:warn, r"missing MCP-Protocol-Version header") @test MCP.validate_stream_headers(server, request) === nothing
            else
                @test MCP.validate_stream_headers(server, request) === nothing
            end
        end
    end
end
