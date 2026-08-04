# Trim-safe Static Tools Server

The static server is a specialized alternative to `MCPServer`. It keeps the
tool dispatch graph concrete for JuliaC `--trim=safe` compilation. It supports
the MCP `2025-11-25` initialization, session, ping, tool-list, tool-call, and
session-delete flows.

The API is not exported. Use each name through the `ModelContextProtocol`
namespace.

## Create a server

Each tool handler must have the same concrete Julia type. One handler type can
dispatch by tool name when a server has more than one tool. Tool arguments,
schemas, annotations, and structured results use raw `JSON.JSONText` values.
The handler must validate its arguments before it performs work.

```@example static-server
using ModelContextProtocol

const MCPJSON = ModelContextProtocol.JSON

Base.@kwdef struct EchoArguments
    message::String = ""
end

struct EchoHandler end

function (::EchoHandler)(
    ::ModelContextProtocol.StaticMCPRequestContext,
    arguments::MCPJSON.JSONText,
)
    parsed = MCPJSON.parse(arguments.value, EchoArguments)
    return ModelContextProtocol.StaticMCPToolResult(
        text=parsed.message,
        structured_content=MCPJSON.JSONText(MCPJSON.json((; echoed=parsed.message))),
    )
end

echo = ModelContextProtocol.StaticMCPTool(
    name="echo",
    description="Return the supplied message.",
    input_schema=MCPJSON.JSONText(
        "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
    ),
    annotations=MCPJSON.JSONText("{\"readOnlyHint\":true}"),
    handler=EchoHandler(),
)

server = ModelContextProtocol.StaticMCPServer(
    [echo];
    name="Static Echo",
    version="1.0.0",
)

only(server.tools).name
```

Register these handlers on one HTTP route:

```julia
HTTP = ModelContextProtocol.HTTP
router = HTTP.Router()
HTTP.register!(router, "POST", "/v1/mcp") do request
    ModelContextProtocol.handle_static_jsonrpc_request(server, request)
end
HTTP.register!(router, "GET", "/v1/mcp") do request
    ModelContextProtocol.handle_static_stream_request(server, request)
end
HTTP.register!(router, "DELETE", "/v1/mcp") do request
    ModelContextProtocol.handle_static_session_delete(server, request)
end
```

## Support limits

The static server provides tools only. It does not provide prompts, resources,
completion, OAuth discovery, or unsolicited server events. Its `GET` handler
returns HTTP 405 because it does not open an event stream. Use `MCPServer` when
the application needs these features.

JuliaC verification covers in-memory HTTP requests and the complete static
server lifecycle. It does not cover live socket or TLS setup in HTTP.jl.
