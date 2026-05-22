# ModelContextProtocol.jl

`ModelContextProtocol.jl` provides Julia server and client utilities for the
Model Context Protocol (MCP). It focuses on Streamable HTTP servers, discovery
manifests, OAuth-protected resources, JSON-RPC request handling, tools, prompts,
resources, completions, logging notifications, and lightweight client smoke
tests.

The package currently targets MCP protocol version `2025-11-25`.

## Installation

This JuliaServices package is currently unregistered. The General registry has
a separate package with the same name, so `Pkg.add("ModelContextProtocol")`
does not install this checkout.

Use a URL or local development checkout instead:

```julia
using Pkg
Pkg.develop(url="https://github.com/JuliaServices/ModelContextProtocol.jl")
```

## Server

```julia
using ModelContextProtocol

server = MCPServer(MCPServerConfig(
    name="Calculator",
    version="0.1.0",
    transport_path="/v1/mcp",
))

register_tool!(
    server;
    name="add",
    description="Add numbers.",
    input_schema=Dict(
        "type" => "object",
        "properties" => Dict(
            "numbers" => Dict(
                "type" => "array",
                "items" => Dict("type" => "number"),
                "minItems" => 2,
            ),
        ),
        "required" => ["numbers"],
    ),
    handler=function (_context, args)
        numbers = Float64.(args["numbers"])
        result = sum(numbers)
        return Dict(
            "content" => [Dict("type" => "text", "text" => string(result))],
            "structuredContent" => Dict("sum" => result),
        )
    end,
)

http_server = serve_mcp_http(server; host="127.0.0.1", port=3010)
wait(http_server.http)
```

## Agentif Tools

If `Agentif.jl` is loaded, `ModelContextProtocol.jl` can register Agentif tools
directly through its package extension:

```julia
using Agentif
using ModelContextProtocol

tool = @tool "Echo text." echo(text::String) = text

server = MCPServer(MCPServerConfig(name="Agentif MCP", version="0.1.0"))
register_tool!(server, tool)
```

The extension derives the MCP `inputSchema` from `Agentif.parameters(tool)` and
wraps the Agentif function in a standard MCP tool handler.

## Client

```julia
using ModelContextProtocol

discovery = discover_server("http://127.0.0.1:3010")
client = prepare_manual_client(discovery)
initialize_client!(client)

result = call_tool(client, "add"; arguments=Dict("numbers" => [1, 3, 4]))
terminate_session!(client)
```

## OAuth

For OAuth-protected MCP servers, use `OAuth.jl` to acquire a token and attach it
before initialization:

```julia
using ModelContextProtocol

discovery = discover_server("https://example.com")
client = prepare_manual_client(discovery)

# token is an OAuth.TokenResponse from OAuth.jl.
attach_token!(client, token)
initialize_client!(client)
```

See the `examples/` directory for runnable calculator servers and clients.
