# ModelContextProtocol.jl

[![CI](https://github.com/JuliaServices/ModelContextProtocol.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaServices/ModelContextProtocol.jl/actions/workflows/ci.yml)
[![Docs stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaServices.github.io/ModelContextProtocol.jl/stable)
[![Docs dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaServices.github.io/ModelContextProtocol.jl/dev)

Julia server and client utilities for the Model Context Protocol (MCP).

The package targets MCP protocol version `2025-11-25` and currently focuses on
Streamable HTTP, discovery manifests, OAuth-protected resources, tools, prompts,
resources, completions, logging notifications, and client smoke tests.

## Installation

This JuliaServices package is currently unregistered. The General registry has
a separate package with the same name, so `Pkg.add("ModelContextProtocol")`
does not install this checkout.

Use a URL or local development checkout instead:

```julia
using Pkg
Pkg.develop(url="https://github.com/JuliaServices/ModelContextProtocol.jl")
```

## Minimal Server

```julia
using ModelContextProtocol

server = MCPServer(MCPServerConfig(name="Calculator", version="0.1.0"))

register_tool!(
    server;
    name="add",
    description="Add numbers.",
    input_schema=Dict(
        "type" => "object",
        "properties" => Dict(
            "numbers" => Dict("type" => "array", "items" => Dict("type" => "number")),
        ),
        "required" => ["numbers"],
    ),
    handler=function (_context, args)
        total = sum(Float64.(args["numbers"]))
        return Dict(
            "content" => [Dict("type" => "text", "text" => string(total))],
            "structuredContent" => Dict("sum" => total),
        )
    end,
)

http_server = serve_mcp_http(server; host="127.0.0.1", port=3010)
wait(http_server.http)
```

## Minimal Client

```julia
using ModelContextProtocol

discovery = discover_server("http://127.0.0.1:3010")
client = prepare_manual_client(discovery)
initialize_client!(client)

result = call_tool(client, "add"; arguments=Dict("numbers" => [1, 3, 4]))
terminate_session!(client)
```

## Agentif Tools

When `Agentif.jl` is loaded, this package can register Agentif tools directly:

```julia
using Agentif
using ModelContextProtocol

tool = @tool "Echo text." echo(text::String) = text

server = MCPServer(MCPServerConfig(name="Agentif MCP", version="0.1.0"))
register_tool!(server, tool)
```

See `examples/` for calculator servers with and without OAuth. The docs include
a deeper walkthrough of the Auth0-federated calculator example.
