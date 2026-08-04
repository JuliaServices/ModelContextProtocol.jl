using JSON
using ModelContextProtocol

url = only(ARGS)
descriptor = MCPTransportDescriptor(kind=:http, url=url)
discovery = MCPDiscovery(
    manifest=Dict{String,Any}(),
    transports=[descriptor],
    default_transport=descriptor,
)
client = prepare_manual_client(
    discovery;
    config=MCPClientConfig(
        protocol_version=get(
            ENV,
            "MCP_CONFORMANCE_PROTOCOL_VERSION",
            ModelContextProtocol.PROTOCOL_VERSION_2026_07_28,
        ),
    ),
)

tools = list_tools(client)
scenario = get(ENV, "MCP_CONFORMANCE_SCENARIO", "")
if scenario == "http-custom-headers"
    context = JSON.parse(get(ENV, "MCP_CONFORMANCE_CONTEXT", "{}"))
    for request in get(context, "toolCalls", Any[])
        call_tool(client, request["name"]; arguments=get(request, "arguments", Dict{String,Any}()))
    end
elseif scenario == "http-invalid-tool-headers"
    for tool in get(tools, "tools", Any[])
        call_tool(client, tool["name"]; arguments=Dict("region" => "us-west1"))
    end
end
