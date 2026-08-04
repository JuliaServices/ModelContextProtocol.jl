# MCP 2026-07-28

`ModelContextProtocol.jl` supports both the stateful MCP `2025-11-25`
protocol and the stateless MCP `2026-07-28` protocol over Streamable HTTP.
The client defaults to `2025-11-25` for compatibility. The server accepts both
versions with its default configuration.

## Select the stateless client

Set the version when you prepare the client. `initialize_client!` then calls
`server/discover`. It does not send the removed `initialize` method.

```julia
using ModelContextProtocol

discovery = discover_server("https://mcp.example.com")
client = prepare_manual_client(
    discovery;
    config=MCPClientConfig(
        protocol_version=ModelContextProtocol.PROTOCOL_VERSION_2026_07_28,
    ),
    capabilities=Dict("elicitation" => Dict()),
)

server_info = initialize_client!(client)
```

Each request includes the required protocol version, client capabilities, and
client identity in `params._meta`. Streamable HTTP requests also include the
required `Mcp-Method` and `Mcp-Name` headers. The package rejects a response or
request that violates the matching rules.

The modern protocol does not use sessions, `notifications/initialized`,
`notifications/cancelled` over HTTP, `ping`, `logging/setLevel`, or the old
resource subscription methods. The client reports an error if an application
tries to use one of these legacy calls in modern mode. `terminate_session!`
only clears local client state in modern mode.

## Require a client capability

A tool can state the client capability that it needs. The server checks the
capability before it invokes the handler.

```@example modern
using ModelContextProtocol

server = MCPServer(name="Approval server", version="0.1.0")

register_tool!(
    server;
    name="approve",
    required_client_capabilities=Dict("elicitation" => Dict()),
    handler=(_context, _arguments) -> Dict(
        "content" => [Dict("type" => "text", "text" => "approved")],
    ),
)

server.tools["approve"].required_client_capabilities
```

If the request omits a required capability, the server returns
`MissingRequiredClientCapability` (`-32021`) with HTTP status `400`. Nested
capability requirements are checked recursively.

For `MCPInputRequired`, the package removes input requests for capabilities
that the client did not declare. It returns `MissingRequiredClientCapability`
only when no requested interaction is supported.

## Multi-round-trip requests

A handler returns `MCPInputRequired` when it needs sampling, roots,
elicitation, or another client operation before it can finish.

```julia
register_tool!(
    server;
    name="confirm-delete",
    handler=function (context, _arguments)
        responses = ModelContextProtocol.input_responses(context)
        if responses === nothing
            return MCPInputRequired(
                input_requests=Dict(
                    "approval" => Dict(
                        "method" => "elicitation/create",
                        "params" => Dict(
                            "message" => "Delete the record?",
                            "requestedSchema" => Dict(
                                "type" => "object",
                                "properties" => Dict(
                                    "confirmed" => Dict("type" => "boolean"),
                                ),
                                "required" => ["confirmed"],
                            ),
                        ),
                    ),
                ),
                request_state="delete-record-42",
            )
        end
        return Dict(
            "content" => [Dict("type" => "text", "text" => "deleted")],
        )
    end,
)
```

The client receives a result with `resultType == "input_required"`. It sends
the next attempt with `input_responses` and the returned `request_state`:

```julia
retry = call_tool(
    client,
    "confirm-delete";
    input_responses=Dict("approval" => Dict("action" => "accept")),
    request_state="delete-record-42",
)
```

The application owns the approval or sampling interaction. The package does
not perform it automatically.

## Custom tool headers

Use `x-mcp-header` on a tool input property when an HTTP intermediary must see
that value without parsing JSON.

```@example modern
header_schema = Dict(
    "type" => "object",
    "properties" => Dict(
        "region" => Dict(
            "type" => "string",
            "x-mcp-header" => "Region",
        ),
    ),
)

register_tool!(
    server;
    name="route-query",
    input_schema=header_schema,
    handler=(_context, _arguments) -> Dict(
        "content" => [Dict("type" => "text", "text" => "ok")],
    ),
)

server.tools["route-query"].input_schema["properties"]["region"]["x-mcp-header"]
```

The modern client reads the schema from `tools/list`. It sends a matching
`Mcp-Param-Region` header on `tools/call`. It encodes unsafe text as UTF-8
Base64. It excludes malformed tool definitions from `tools/list`. The server
validates recognized custom headers before it invokes the tool.

Only `string`, `integer`, and `boolean` properties can use this annotation.
Integers must be in the JavaScript safe-integer range. Header names must be
unique HTTP field-name tokens. Do not expose passwords, tokens, or personal
data in these headers.

## Subscriptions and request events

Use the namespaced subscription API for modern list-change and resource
notifications:

```julia
listen = ModelContextProtocol.listen_subscriptions!(
    client;
    tools_list_changed=true,
    resource_uris=["memory://report"],
)
```

Register handlers with `register_notification_handler!` before you start the
listener. A server can end all active streams with
`ModelContextProtocol.close_subscription_listeners!` during shutdown.

Tool handlers can call `ModelContextProtocol.send_progress!` and
`ModelContextProtocol.send_log!`. The current server preserves event order but
buffers request-scoped events until the handler returns. Use
`subscriptions/listen` when an event must arrive independently of one request.

## Cache metadata

Modern discovery and list results include `ttlMs` and `cacheScope`. Configure
them with `cache_ttl_ms` and `cache_scope` in `MCPServerConfig`. The time must
not be negative. The scope must be `"private"` or `"public"`.

## Conformance adapter

The repository includes `test/conformance_client.jl`. It lets the official MCP
conformance runner exercise this package as a client. The normal Julia test
suite contains permanent regression checks for the same wire contracts.
