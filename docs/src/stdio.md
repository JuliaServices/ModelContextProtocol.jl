# Local stdio client

Use `ModelContextProtocol.prepare_stdio_client(command)` to launch a local MCP
server and own its stdin/stdout connection. The child must exchange one UTF-8
JSON-RPC object per line. Diagnostic output belongs on stderr. The constructor
accepts a Julia `Cmd`; it does not run a shell or interpret a command string.

This example uses the repository's deterministic echo peer. Replace `command`
with your server's command in an application. The do-block closes the child
when the body returns or throws.

```@example stdio
using ModelContextProtocol

peer = joinpath(pkgdir(ModelContextProtocol), "test", "stdio_peer.jl")
project = dirname(Base.active_project())
command = `$(Base.julia_cmd()) --startup-file=no --project=$project $peer`

ModelContextProtocol.prepare_stdio_client(command; stderr=devnull) do client
    initialize_client!(client)
    @assert list_tools(client)["tools"][1]["name"] == "echo"
    result = call_tool(client, "echo"; arguments=Dict("message" => "Hello, λ"))
    println(result["structuredContent"]["message"])
end
```

Without a do-block, use `try`/`finally` and call `close(client)` or
`terminate_session!(client)`. The client owns the direct child and its protocol
pipes. It does not manage a process tree created by that child. Pass the server
executable directly when possible.

## Protocol versions

The default is MCP `2025-11-25`. Select `2026-07-28` explicitly with
`MCPClientConfig(protocol_version=ModelContextProtocol.PROTOCOL_VERSION_2026_07_28)`.

| Behavior | 2025-11-25 | 2026-07-28 |
|:--|:--|:--|
| `initialize_client!` | Initialize, then initialized notification | `server/discover` |
| Request identity/capabilities | Initialization parameters | Per-request `_meta` |
| Lists, calls, and notifications | Supported | Supported |
| Server requests | Existing registered request handlers | Rejected by the protocol |
| Multi-round-trip input | Application-managed | Existing `input_required` helpers |
| Request timeout | Cancellation notification | Cancellation notification |
| Subscriptions | Existing legacy resource calls | Not implemented |

The implementation follows the dated
[2025-11-25 transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
and [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
rules, and the
[2026-07-28 stdio transport](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
rules for the operations above. It does not probe versions, fall back to another
protocol, restart a child, or replay requests automatically. HTTP headers,
OAuth bearer tokens, HTTP event streams, and modern `subscriptions/listen` are
rejected, as are custom HTTP adapters and verbose HTTP logging. Stdio has no
HTTP header transport; `x-mcp-header` tool arguments are
sent as ordinary arguments. Importing a server's catalog into Agentif is a
separate application concern.

## Concurrent calls and handlers

Register notification/request handlers and complete initialization before
starting concurrent calls. Calls receive unique string IDs; out-of-order
responses are matched by the exact ID. A late response to an expired call is
discarded. EOF, invalid JSON/UTF-8, mismatched IDs, and oversized frames fail
pending calls and start process cleanup.

Notifications and legacy server requests use the existing handler registration
APIs. One callback task preserves arrival order, independently of response
reading. A handler can make a nested client call. A slow handler delays other
callbacks but does not stop response routing. Closing discards queued callbacks
that have not started.

## Bounds and shutdown

`config.timeout.readtimeout` defaults to 120 seconds. Each call can override it
with a positive integer `timeout_ms`. This deadline covers queued writes and
response waits. It does not preempt application JSON serialization or OS process
creation. A response timeout sends cancellation, except for legacy initialize;
a write timeout closes the connection because a partial frame cannot be safely
replayed. `connecttimeout` has no effect for a local process; other timeout
settings are rejected.

`max_message_bytes` defaults to 16 MiB per incoming/outgoing message.
`max_pending_messages` defaults to 128 and separately limits pending calls,
queued writes, and queued callbacks. A full call/write queue reports
`MCPError(:transport_busy)`. Callback overflow fails the connection with
`MCPError(:callback_overflow)`. These are queue/frame limits, not a total memory
quota for parsed JSON or user code.

Stderr can go directly to a filename, open file, terminal, pipe, or `devnull`.
Caller-provided destinations remain caller-owned. In-memory/custom IO sinks
are rejected because their implicit copy tasks cannot be bounded by the client.
If a pipe destination blocks, requests still have deadlines and closing can
terminate the child.

`close(client; timeout=5.0)` stops new calls, fails pending calls, closes stdin,
and escalates to process termination and kill if necessary. It waits for owned
IO and callback tasks within the supplied deadline. Cleanup state remains
available if close times out, so a later `close` can finish waiting.

Julia cannot safely interrupt arbitrary callback code. A blocked user callback
can produce `MCPError(:callback_timeout)` after process/IO cleanup. Release that
callback and close again. A callback may call `close` itself; close skips waiting
for that callback, which finishes when its handler returns. This transport does
not provide forced task cancellation.

The dynamic subprocess client is not a JuliaC `--trim=safe` API. The package's
[static tools server](static-server.md) remains its supported native subset.
