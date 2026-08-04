# Protocol Status and Roadmap

This file records the current support boundary for `ModelContextProtocol.jl`.
The dated protocol guides in the published MCP specification are the source of
truth for wire behavior.

## Current support

The package supports Streamable HTTP for two protocol eras:

- MCP `2025-11-25`: stateful initialization, sessions, resumable server event
  streams, cancellation, ping, logging level changes, resource subscriptions,
  tools, prompts, resources, completions, and MCP Apps.
- MCP `2026-07-28`: stateless request metadata, `server/discover`, standard and
  custom request headers, cache metadata, client capability checks,
  multi-round-trip `input_required` results, request-scoped progress and log
  events, and `subscriptions/listen`.

The general server accepts both versions by default. The client defaults to
`2025-11-25`. Applications opt in to `2026-07-28` with `MCPClientConfig`.

The package also includes a separate tools-only server for JuliaC
`--trim=safe` builds. That server intentionally supports only the documented
`2025-11-25` subset.

## Validation baseline

The repository tests these areas:

- Julia 1.10, current stable Julia, and Julia nightly on Linux, macOS, and
  Windows.
- OAuth 2 and OAuth 3 compatibility.
- Stateful and stateless HTTP client/server integration.
- Strict JSON-RPC parsing and notification side-effect rules.
- MCP Apps resource and tool metadata.
- Official MCP conformance scenarios for stateless metadata, capability
  checks, standard request headers, and `x-mcp-header` behavior.
- JuliaC trim compilation for the static server.
- Documenter build and doctests.

## Intentional limits

- The transport is HTTP only. The package does not provide a stdio transport.
- Tool input and output schemas are advertised but are not a complete runtime
  JSON Schema validation engine. A handler must still validate domain rules.
- Modern request-scoped progress and log events keep their correct order, but
  the server buffers them until the handler returns.
- Modern sampling, roots, and elicitation are exposed as multi-round-trip input
  requests. The application performs the external interaction and retries the
  original MCP request.
- OAuth helpers do not implement every optional proof-of-possession mechanism.
- The static JuliaC server does not support prompts, resources, OAuth, MCP Apps,
  arbitrary middleware, or the `2026-07-28` stateless protocol.

## Next work

1. Add the official MCP conformance runner to CI when its `2026-07-28` package
   release is stable.
2. Stream modern request-scoped events while a handler is still running.
3. Add a standard client API that closes one `subscriptions/listen` stream
   without ending the server.
4. Evaluate a lightweight JSON Schema validator for tool arguments and
   structured results.
5. Add a stdio transport only if a concrete Julia deployment needs it.

Do not add a feature only to increase surface coverage. Preserve the small
export surface. Keep specialized helpers under the `ModelContextProtocol`
namespace.
