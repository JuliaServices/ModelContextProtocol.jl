module ToolArgumentTests

using Test, HTTP, JSON, ModelContextProtocol
const MCP = ModelContextProtocol

mutable struct ChangingRegion
    calls::Int
end
JSON.StructUtils.lower(value::ChangingRegion) =
    (value.calls += 1; value.calls == 1 ? "west" : "east")

struct LoweredArguments{T} <: AbstractDict{String,Any}
    value::T
end
Base.length(::LoweredArguments) = 0
Base.iterate(::LoweredArguments) = nothing
JSON.StructUtils.lower(arguments::LoweredArguments) = arguments.value

@testset "Tool argument serialization" begin
    requests = Any[]
    received = Any[]
    server = MCP.MCPServer(name="Argument snapshots", version="1.0.0")
    schema = Dict("type" => "object", "properties" => Dict(
        "region" => Dict("type" => "string", "x-mcp-header" => "Region"),
        "priority" => Dict("type" => "integer", "x-mcp-header" => "Priority"),
        "nested" => Dict("type" => "object", "properties" => Dict(
            "enabled" => Dict("type" => "boolean", "x-mcp-header" => "Enabled"))),
    ))
    for (name, input_schema) in (("routed", schema), ("ordinary", Dict("type" => "object")))
        MCP.register_tool!(server; name, input_schema, handler=(context, arguments) -> begin
            push!(received, arguments)
            Dict("content" => [Dict("type" => "text", "text" => "ok")])
        end)
    end
    MCP.set_request_hook!(server) do req
        push!(requests, (
            headers=Dict(String(k) => String(v) for (k, v) in req.headers),
            payload=JSON.parse(String(copy(req.body))),
        ))
    end
    http_server = MCP.serve_mcp_http(server; host="127.0.0.1", port=0)
    try
        transport = MCP.MCPTransportDescriptor(kind=:http, url=MCP.base_url(http_server) * server.transport_path)
        discovery = MCP.MCPDiscovery(manifest=Dict{String,Any}(), transports=[transport], default_transport=transport)
        client = MCP.prepare_manual_client(discovery; config=MCP.MCPClientConfig(protocol_version=MCP.PROTOCOL_VERSION_2026_07_28))

        # The first call discovers the schema; later calls use it without caching arguments.
        region = ChangingRegion(0)
        for expected in ("west", "east")
            result = MCP.call_tool(client, "routed"; arguments=(; region))
            @test result["content"][1]["text"] == "ok"
            @test requests[end].headers["Mcp-Param-Region"] == expected
            @test requests[end].payload["params"]["arguments"]["region"] == expected
            @test received[end]["region"] == expected
        end
        @test region.calls == 2
        @test count(req -> req.payload["method"] == "tools/list", requests) == 1
        ordinary_region = ChangingRegion(0)
        MCP.call_tool(client, "ordinary"; arguments=Dict("region" => ordinary_region))
        @test ordinary_region.calls == 1
        @test received[end]["region"] == "west"
        @test !haskey(requests[end].headers, "Mcp-Param-Region")

        @testset "Encoded object semantics" begin
            for arguments in (
                Dict{String,Any}(), (;),
                (; region="north\n雪", priority=42, nested=(; enabled=false)),
                Dict(:region => "west", :priority => 3),
                Dict{Any,Any}(:region => "first", "region" => "last", 7 => "numeric key"),
                (; region=nothing, priority=missing, nested=(; enabled=nothing)),
                LoweredArguments((; region="lowered")),
                LoweredArguments(JSON.JSONText("{\"region\":\"first\",\"region\":\"last\"}")),
                LoweredArguments(JSON.JSONText("{\"region\":\"first\",\"region\":null}")),
                LoweredArguments(JSON.JSONText("{\"region\":null,\"region\":\"last\"}")),
                LoweredArguments(JSON.JSONText("{\"nested\":{\"enabled\":true,\"enabled\":null}}")),
                LoweredArguments(JSON.JSONText("{\"nested\":{\"enabled\":null,\"enabled\":false}}")),
            )
                expected = JSON.parse(JSON.json(arguments))
                MCP.call_tool(client, "routed"; arguments)
                @test isequal(received[end], expected)
                @test isequal(requests[end].payload["params"]["arguments"], expected)
                for (path, header) in ((["region"], "Region"), (["priority"], "Priority"), (["nested", "enabled"], "Enabled"))
                    value = expected
                    for key in path
                        value = value isa AbstractDict ? get(value, key, nothing) : nothing
                    end
                    raw = get(requests[end].headers, "Mcp-Param-$header", nothing)
                    if value === nothing
                        @test raw === nothing
                    else
                        @test MCP.decode_mcp_name(raw) == string(value)
                    end
                end
            end
        end

        MCP.call_tool(client, "routed")
        @test !haskey(requests[end].payload["params"], "arguments")
        @test isempty(received[end])
        MCP.call_tool(client, "routed"; arguments=Dict())
        @test haskey(requests[end].payload["params"], "arguments")

        @testset "Invalid arguments stop before HTTP or handler effects" begin
            request_count, call_count = length(requests), length(received)
            for arguments in ([1, 2], "text", 1, JSON.JSONText("{}"),
                LoweredArguments([1, 2]), LoweredArguments(nothing), LoweredArguments("text"),
                (; region=7), (; priority=1.5), (; priority=big(9_007_199_254_740_992)))
                @test_throws ArgumentError MCP.call_tool(client, "routed"; arguments)
                @test length(requests) == request_count
                @test length(received) == call_count
            end
            @test_throws ArgumentError MCP.call_tool(client, "routed";
                arguments=LoweredArguments(JSON.JSONText("{\"nested\":[}")))
            @test length(requests) == request_count
            @test length(received) == call_count
        end

        arguments = Dict("region" => "west")
        MCP.call_tool(client, "routed"; arguments, headers=["X-Custom" => "kept"],
            meta=Dict("example.test/marker" => 1), input_responses=Dict("approval" => "yes"),
            request_state="state", timeout_ms=1000)
        @test arguments == Dict("region" => "west")
        @test requests[end].headers["X-Custom"] == "kept"
        @test requests[end].headers["Mcp-Timeout-Ms"] == "1000"
        @test requests[end].payload["params"]["_meta"]["example.test/marker"] == 1
        @test requests[end].payload["params"]["inputResponses"] == Dict("approval" => "yes")
        @test requests[end].payload["params"]["requestState"] == "state"

        unknown_region = ChangingRegion(0)
        @test_throws MCP.MCPError MCP.call_tool(client, "unknown"; arguments=(; region=unknown_region))
        @test unknown_region.calls == 1
        @test !haskey(requests[end].headers, "Mcp-Param-Region")

        legacy = MCP.prepare_manual_client(discovery)
        MCP.initialize_client!(legacy)
        legacy_region = ChangingRegion(0)
        result = MCP.call_tool(legacy, "routed"; arguments=(; region=legacy_region))
        @test result["content"][1]["text"] == "ok"
        @test legacy_region.calls == 1
        @test received[end]["region"] == "west"
        @test !haskey(requests[end].headers, "Mcp-Param-Region")
        @test isempty(legacy.tool_schemas)

        direct_region = ChangingRegion(0)
        MCP.jsonrpc_call(client, "tools/call"; params=Dict("name" => "ordinary", "arguments" => (; region=direct_region)))
        @test direct_region.calls == 1
        @test received[end]["region"] == "west"
    finally
        MCP.stop_mcp_server(http_server)
    end
end

end
