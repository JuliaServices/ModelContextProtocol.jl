# Trim-safe Static Server

The static server is a specialized alternative to `MCPServer`. It keeps the
request graph concrete for JuliaC `--trim=safe` compilation. It supports the
MCP `2025-11-25` initialization, session, ping, tool-list, tool-call,
resource-list, resource-read, and session-delete flows. It can also serve MCP
Apps widgets and run without sessions.

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

## MCP Apps widgets

An MCP App is an HTML widget that hosts such as Claude and ChatGPT render
inline when a linked tool runs. The [MCP App playbook](https://github.com/JuliaServices/ModelContextProtocol.jl/blob/main/MCP-App-playbook.md)
explains each piece. With the static server:

1. Serve the widget HTML as a `StaticMCPResource` with a `ui://` uri and
   `mime_type=MCP_APP_HTML_MIME_TYPE`. `mcp_app_html` builds a widget document
   with the host handshake included.
2. Link the tool to the widget with `meta=static_ui_tool_meta(uri)`.
3. Advertise MCP Apps with `extensions=static_ui_extensions()`.
4. Return the widget's data as `structured_content`.

```@example static-server
widget_uri = "ui://echo/card"
widget = ModelContextProtocol.StaticMCPResource(
    uri=widget_uri,
    name="echo-card",
    mime_type=ModelContextProtocol.MCP_APP_HTML_MIME_TYPE,
    text=ModelContextProtocol.mcp_app_html(
        app_name="echo-card",
        body="<main id=\"app\">Loading</main>",
        script="mcpApp.onRender(function (data) { document.getElementById('app').textContent = data.echoed; });",
    ),
    meta=MCPJSON.JSONText("{\"ui\":{\"prefersBorder\":true}}"),
)

card_echo = ModelContextProtocol.StaticMCPTool(
    name="echo",
    description="Return the supplied message in a card.",
    input_schema=echo.input_schema,
    meta=ModelContextProtocol.static_ui_tool_meta(widget_uri),
    handler=EchoHandler(),
)

app_server = ModelContextProtocol.StaticMCPServer(
    [card_echo];
    name="Static Echo",
    version="1.0.0",
    resources=[widget],
    extensions=ModelContextProtocol.static_ui_extensions(),
    stateless=true,
)

request = ModelContextProtocol.HTTP.Request(
    "POST",
    "/v1/mcp",
    ["Content-Type" => "application/json", "MCP-Protocol-Version" => "2025-11-25"],
    Vector{UInt8}("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"),
)
String(ModelContextProtocol.handle_static_jsonrpc_request(app_server, request).body)
```

The static server returns the text block and `structuredContent` for each
tool call. It does not embed the widget HTML in the tool result, so hosts that
render only an embedded copy show the text instead.

## Protocol versions and sessions

`initialize` answers with the client's requested `protocolVersion` when it is
the server's `protocol_version` or in `supported_protocol_versions`, and with
`protocol_version` otherwise. Requests whose `MCP-Protocol-Version` header
names any other version get HTTP 400. Some clients omit that header after
`initialize`; `missing_protocol_header` chooses what happens then:

- `:ignore` (the default) serves the request.
- `:warn` logs a warning and serves the request.
- `:error` answers HTTP 400.

By default the server issues an `MCP-Session-Id` at `initialize` and keeps the
session in memory. A client must send that id, and the
`notifications/initialized` notification, before other requests. After a
restart, or on another machine, the session is unknown and the client gets
HTTP 404 and must initialize again.

Set `stateless=true` to avoid that. `initialize` then issues no session id,
requests need no session, and the server stores nothing per client, so any
process running the same server answers any client. `DELETE` returns HTTP 405
because there is no session to end. This is still the `2025-11-25` protocol,
not the `2026-07-28` protocol.

## Support limits

The static server does not provide prompts, resource templates, resource
subscriptions, completion, OAuth discovery, or unsolicited server events.
`resources/templates/list` returns an empty list. Its `GET` handler returns
HTTP 405 because it does not open an event stream. Use `MCPServer` when the
application needs these features.

JuliaC verification covers in-memory HTTP requests and the complete static
server lifecycle in both session modes. It does not cover live socket or TLS
setup in HTTP.jl.
