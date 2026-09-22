using Test, HTTP, JSON, ModelContextProtocol

@testset "Client response IDs" begin
    response_id = Ref{Any}(:matching)
    response_error = Ref(false)
    notifications = Ref(0)
    stub = HTTP.serve!("127.0.0.1", 0; verbose=false) do req
        payload = JSON.parse(String(req.body))
        if !haskey(payload, "id")
            notifications[] += 1
            return HTTP.Response(202)
        end
        body = Dict{String,Any}("jsonrpc" => "2.0")
        if response_id[] !== :missing
            body["id"] = response_id[] === :matching ? payload["id"] :
                response_id[] === :numeric ? parse(Int, payload["id"]) : response_id[]
        end
        if response_error[]
            body["error"] = Dict("code" => -32600, "message" => "Invalid Request", "data" => "detail")
        else
            body["result"] = Dict("tools" => Any[])
        end
        HTTP.Response(200, ["Content-Type" => "application/json", "MCP-Session-Id" => "test-session"], JSON.json(body))
    end
    try
        port = ModelContextProtocol.bound_http_port(stub)
        transport = ModelContextProtocol.MCPTransportDescriptor(kind=:http, url="http://127.0.0.1:$(port)/mcp")
        discovery = ModelContextProtocol.MCPDiscovery(manifest=Dict{String,Any}(), transports=[transport], default_transport=transport)
        for version in (ModelContextProtocol.DEFAULT_PROTOCOL_VERSION, ModelContextProtocol.PROTOCOL_VERSION_2026_07_28)
            @testset "$version" begin
                client = prepare_manual_client(discovery; config=MCPClientConfig(protocol_version=version))
                client.initialized = true
                @test list_tools(client)["tools"] == Any[]
                for id in ("another-request", :missing, nothing, :numeric, true)
                    response_id[] = id
                    @test_throws ModelContextProtocol.MCPError list_tools(client)
                end
                response_id[] = :matching
                @test list_tools(client)["tools"] == Any[]
                response_error[] = true
                for id in (:matching, :missing, nothing)
                    response_id[] = id
                    err = try
                        list_tools(client)
                    catch err
                        err
                    end
                    @test err isa ModelContextProtocol.MCPError
                    @test occursin("code=-32600", sprint(showerror, err))
                    @test occursin("detail", sprint(showerror, err))
                end
                response_error[] = false
                response_id[] = :matching
            end
        end
        client = prepare_manual_client(discovery)
        response_error[] = true
        for id in (:matching, :missing, nothing)
            response_id[] = id
            @test_throws ModelContextProtocol.MCPError initialize_client!(client)
            @test client.session_id === nothing
            @test client.session === nothing
            @test !client.initialized
            @test notifications[] == 0
        end
        response_error[] = false
        response_id[] = "another-request"
        @test_throws ModelContextProtocol.MCPError initialize_client!(client)
        @test client.session_id === nothing
        @test client.session === nothing
        @test !client.initialized
        @test notifications[] == 0
        response_id[] = :matching
        @test initialize_client!(client)["tools"] == Any[]
        @test client.session_id == "test-session"
        @test client.initialized
        @test notifications[] == 1
    finally
        close(stub)
    end
end
