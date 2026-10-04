using Test, HTTP, JSON, ModelContextProtocol

@testset "HTTP protocol version negotiation" begin
    MCP = ModelContextProtocol

    @testset "Legacy initialization without a version header ($preferred)" for preferred in ("2025-11-25", "2026-07-28")
        server = MCPServer(name="Version negotiation", version="1.0.0", protocol_version=preferred,
            supported_protocol_versions=["2025-11-25", "2026-07-28"])
        calls = Ref(0)
        versions = String[]
        register_tool!(server; name="count", handler=(context, _arguments) -> begin
            calls[] += 1
            push!(versions, context.protocol_version)
            Dict("content" => Any[])
        end)
        capability_calls = Ref(0)
        register_tool!(server; name="capability", required_client_capabilities=Dict("sampling" => Dict()),
            handler=(_context, _arguments) -> begin
                capability_calls[] += 1
                Dict("content" => Any[])
            end)
        register_tool!(server; name="input", handler=(_context, _arguments) -> MCP.MCPInputRequired(request_state="retry"))
        request(method; id="1", params=Dict{String,Any}(), headers=Pair{String,String}[]) = HTTP.Request(
            "POST", "/v1/mcp",
            vcat(["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"], headers),
            JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)),
        )
        initialize_params = Dict(
            "protocolVersion" => "2025-11-25",
            "capabilities" => Dict(),
            "clientInfo" => Dict("name" => "Legacy client", "version" => "1.0.0"),
        )
        initialized = MCP.handle_jsonrpc_request(server, request("initialize"; id=0, params=initialize_params))
        @test initialized.status == 200
        payload = JSON.parse(String(initialized.body))
        @test haskey(payload, "result")
        if haskey(payload, "result")
            @test payload["id"] == 0
            @test payload["result"]["protocolVersion"] == "2025-11-25"
            session_id = MCP.http_header_value(initialized.headers, "MCP-Session-Id")
            @test session_id isa AbstractString
            session_headers = ["MCP-Session-Id" => String(session_id)]
            rejected = MCP.handle_jsonrpc_request(server, request("notifications/initialized"; id=nothing, headers=session_headers))
            @test rejected.status == 400
            @test !server.sessions[session_id].initialized
            push!(session_headers, "MCP-Protocol-Version" => "2025-11-25")
            accepted = MCP.handle_jsonrpc_request(server, request("notifications/initialized"; id=nothing, headers=session_headers))
            @test accepted.status == 202
            @test server.sessions[session_id].initialized
            rejected = MCP.handle_jsonrpc_request(server, request("tools/call";
                params=Dict("name" => "count"), headers=["MCP-Session-Id" => String(session_id)]))
            @test rejected.status == 400
            @test calls[] == 0
            accepted = MCP.handle_jsonrpc_request(server, request("tools/call";
                params=Dict("name" => "count"), headers=session_headers))
            @test accepted.status == 200
            @test calls[] == 1
            @test versions == ["2025-11-25"]
            accepted = MCP.handle_jsonrpc_request(server, request("tools/call";
                params=Dict("name" => "capability"), headers=session_headers))
            @test accepted.status == 200
            @test haskey(JSON.parse(String(accepted.body)), "result")
            @test capability_calls[] == 1
            rejected = MCP.handle_jsonrpc_request(server, request("tools/call";
                params=Dict("name" => "input"), headers=session_headers))
            @test rejected.status == 200
            @test get(get(JSON.parse(String(rejected.body)), "error", Dict()), "code", nothing) == -32003

            for (name, expected_status) in (("count", 200), ("capability", 400), ("input", 200))
                response = MCP.handle_jsonrpc_request(server, request("tools/call"; params=Dict(
                    "name" => name, "_meta" => Dict(MCP.META_PROTOCOL_VERSION => "2026-07-28",
                        MCP.META_CLIENT_CAPABILITIES => Dict(),
                        MCP.META_CLIENT_INFO => Dict("name" => "Modern client", "version" => "1.0.0")),
                ), headers=["MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/call", "Mcp-Name" => name]))
                @test response.status == expected_status
                payload = JSON.parse(String(response.body))
                name == "capability" && @test payload["error"]["code"] == -32021
                name == "input" && @test payload["result"]["resultType"] == "input_required"
            end
            @test versions == ["2025-11-25", "2026-07-28"]
            @test capability_calls[] == 1
            @test server.config.protocol_version == preferred
        end

        sessions_before = length(server.sessions)
        for header in ("", " ", "1900-01-01")
            response = MCP.handle_jsonrpc_request(server, request("initialize";
                params=initialize_params, headers=["MCP-Protocol-Version" => header]))
            @test response.status == 400
            @test length(server.sessions) == sessions_before
        end
        for method in ("initialize", "tools/call")
            response = MCP.handle_jsonrpc_request(server, request(method; params=Dict(
                "name" => "count", "_meta" => Dict(
                    MCP.META_PROTOCOL_VERSION => "2026-07-28",
                    MCP.META_CLIENT_CAPABILITIES => Dict(),
                ),
            )))
            @test response.status == 400
            @test JSON.parse(String(response.body))["error"]["code"] == -32020
            @test length(server.sessions) == sessions_before
        end
        response = MCP.handle_jsonrpc_request(server, request("initialize";
            params=initialize_params, headers=["Origin" => "https://untrusted.example"]))
        @test response.status == 403
        @test length(server.sessions) == sessions_before
        response = MCP.handle_jsonrpc_request(server, request("tools/call"; params=Dict("name" => "count")))
        @test response.status == 400
        @test length(server.sessions) == sessions_before
        modern_only = MCPServer(name="Modern only", version="1.0.0", protocol_version="2026-07-28", supported_protocol_versions=String[])
        @test MCP.handle_jsonrpc_request(modern_only, request("initialize"; params=initialize_params)).status == 400
        @test isempty(modern_only.sessions)
    end

    @testset "Bounded modern version retry" begin
        mode = Ref(:negotiate)
        records = Any[]
        effects = Ref(0)
        stub = HTTP.serve!("127.0.0.1", 0; verbose=false) do req
            body = String(req.body)
            payload = JSON.parse(body)
            headers = Dict(lowercase(String(k)) => String(v) for (k, v) in req.headers)
            push!(records, (; body, payload, headers))
            if length(records) == 1 || mode[] == :always
                data = Dict{String,Any}("supported" => ["2026-07-28"], "requested" => headers["mcp-protocol-version"])
                error = Dict{String,Any}("code" => -32022, "message" => "Unsupported protocol version", "data" => data)
                reply = Dict{String,Any}("jsonrpc" => "2.0", "id" => get(payload, "id", nothing), "error" => error)
                mode[] == :wrong_id && (reply["id"] = "another-request")
                mode[] == :missing_id && delete!(reply, "id")
                mode[] == :wrong_jsonrpc && (reply["jsonrpc"] = "1.0")
                mode[] == :mixed_result && (reply["result"] = Dict())
                mode[] == :wrong_code && (error["code"] = -32020)
                mode[] == :missing_message && delete!(error, "message")
                mode[] == :wrong_requested && (data["requested"] = "another-version")
                mode[] == :legacy_only && (data["supported"] = ["2025-11-25"])
                mode[] == :future_only && (data["supported"] = ["2099-01-01"])
                mode[] == :invalid_supported && (data["supported"] = "2026-07-28")
                status = mode[] == :http200 ? 200 : mode[] == :http403 ? 403 : mode[] == :http401 ? 401 : 400
                body = mode[] == :malformed ? "{" : JSON.json(reply)
                return HTTP.Response(status, ["Content-Type" => "application/json"], body)
            end
            effects[] += 1
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(Dict(
                "jsonrpc" => "2.0", "id" => payload["id"],
                "result" => Dict("content" => [Dict("type" => "text", "text" => "written once")]),
            )))
        end
        try
            port = MCP.bound_http_port(stub)
            transport = MCPTransportDescriptor(kind=:http, url="http://127.0.0.1:$(port)/mcp")
            discovery = MCPDiscovery(manifest=Dict{String,Any}(), transports=[transport], default_transport=transport)
            function new_client(version="2026-07-28")
                client = prepare_manual_client(discovery; config=MCPClientConfig(protocol_version=version),
                    capabilities=Dict("elicitation" => Dict()), client_info=Dict("name" => "Version test", "version" => "1.0.0"))
                client.auth_token = "Bearer version-test"
                client.initialized = true
                client.tool_schemas["write-once"] = Dict("type" => "object", "properties" => Dict(
                    "note" => Dict("type" => "string", "x-mcp-header" => "Note")))
                return client
            end
            attempt(client; kwargs...) = try
                call_tool(client, "write-once"; arguments=Dict("note" => "keep-me"), timeout_ms=5000, kwargs...)
            catch error
                error
            end
            for version in ("2026-07-28", "2099-01-01")
                empty!(records)
                effects[] = 0
                client = new_client(version)
                meta = Dict(MCP.META_PROTOCOL_VERSION => version, "example.test/trace" => "trace-1")
                result = attempt(client; meta, headers=["X-Request-Tag" => "keep-me"])
                @test result isa AbstractDict
                @test length(records) == 2
                @test effects[] == 1
                @test meta[MCP.META_PROTOCOL_VERSION] == version
                @test client.protocol_version == version
                @test client.next_id[] == 1
                if length(records) == 2
                    @test result["content"][1]["text"] == "written once"
                    @test records[1].payload["id"] == records[2].payload["id"]
                    expected = deepcopy(records[1].payload)
                    expected["params"]["_meta"][MCP.META_PROTOCOL_VERSION] = "2026-07-28"
                    @test records[2].payload == expected
                    expected_headers = copy(records[1].headers)
                    expected_headers["mcp-protocol-version"] = "2026-07-28"
                    @test records[2].headers == expected_headers
                    @test records[2].headers["mcp-method"] == "tools/call"
                    @test records[2].headers["mcp-name"] == "write-once"
                    @test records[2].headers["mcp-param-note"] == "keep-me"
                    @test records[2].headers["authorization"] == "Bearer version-test"
                    @test records[2].headers["mcp-timeout-ms"] == "5000"
                end
            end
            empty!(records)
            effects[] = 0
            client = new_client("2099-01-01")
            raw_arguments = """{"note":"keep-me","precise":1.23456789012345678901234567890123456789,"large":12345678901234567890123456789012345678901234567890,"nested":{"_meta":{"$(MCP.META_PROTOCOL_VERSION)":"2099-01-01"},"escaped":"\\u2603"}}"""
            raw_metadata = """{"precise":9.87654321098765432109876543210987654321,"large":98765432109876543210987654321098765432109876543210}"""
            result = call_tool(client, "write-once"; arguments=Dict("note" => "keep-me", "raw" => JSON.JSONText(raw_arguments)),
                meta=Dict("example.test/raw" => JSON.JSONText(raw_metadata)),
                headers=["X-Request-Tag" => "keep-me"], timeout_ms=5000)
            @test result["content"][1]["text"] == "written once"
            @test length(records) == 2
            @test effects[] == 1
            @test client.protocol_version == "2099-01-01"
            @test client.next_id[] == 1
            if length(records) == 2
                for record in records
                    request = JSON.parse(record.body, Dict{String,JSON.JSONText})
                    params = JSON.parse(request["params"].value, Dict{String,JSON.JSONText})
                    arguments = JSON.parse(params["arguments"].value, Dict{String,JSON.JSONText})
                    meta = JSON.parse(params["_meta"].value, Dict{String,JSON.JSONText})
                    @test arguments["raw"].value == raw_arguments
                    @test meta["example.test/raw"].value == raw_metadata
                end
                @test records[1].payload["id"] == records[2].payload["id"]
                expected_headers = copy(records[1].headers)
                expected_headers["mcp-protocol-version"] = "2026-07-28"
                @test records[2].headers == expected_headers
            end
            for reject in (:wrong_id, :missing_id, :wrong_jsonrpc, :mixed_result, :wrong_code, :missing_message,
                           :wrong_requested, :legacy_only, :future_only, :invalid_supported, :malformed, :http200, :http403, :http401, :always)
                mode[] = reject
                empty!(records)
                effects[] = 0
                result = attempt(new_client())
                @test result isa Exception
                @test length(records) == (reject == :always ? 2 : 1)
                @test effects[] == 0
                reject == :http401 && @test result isa MCP.MCPAuthenticationRequired
            end
            mode[] = :negotiate
            empty!(records)
            @test attempt(new_client("2025-11-25")) isa MCPError
            @test length(records) == 1
            for kwargs in ((; meta=Dict(MCP.META_PROTOCOL_VERSION => "2099-01-01")),
                           (; headers=["MCP-Protocol-Version" => "2099-01-01"]))
                empty!(records)
                @test attempt(new_client(); kwargs...) isa MCPError
                @test length(records) == 1
            end
            empty!(records)
            @test_throws MCPError MCP.jsonrpc_notification(new_client(), "notifications/custom")
            @test length(records) == 1
        finally
            close(stub)
        end
    end
end
