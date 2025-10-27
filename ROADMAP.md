# MCP 2025-06-18 Compliance Roadmap

This document captures the work needed to bring `ModelContextProtocol.jl` into
alignment with the Model Context Protocol revision published on
2025‑06‑18. References to the upstream specification use the markdown files in
`docs/specification/2025-06-18/…` from the
`modelcontextprotocol/modelcontextprotocol` repository.

## Current Coverage Snapshot
- Discovery and manual client creation over plain HTTP are implemented
  (see `src/discovery.jl`, `src/client.jl`).
- Server primitives exist for basic tool, prompt, and resource registration
  with JSON-RPC handling (`src/server.jl`).
- OAuth helper wrappers exist for attaching tokens (`src/auth.jl`).
- Test suite exercises a happy-path HTTP server/client interaction.

The implemented surface matches the 2024-era MCP draft and omits large
portions of the 2025-06-18 revision.

## Compliance Gaps and Required Enhancements

### Lifecycle, Transport, and Session Management
- **`initialize` / `initialized` handshake** (`basic/lifecycle.mdx`): client
  must send `notifications/initialized` after a successful response, and server
  should avoid initiating requests before it is received. Neither side enforces
  this today.
- **Protocol headers and session IDs** (`basic/transports.mdx` §Streamable HTTP):
  client requests must send `Accept: application/json, text/event-stream`,
  `MCP-Protocol-Version`, and (when provided) `Mcp-Session-Id`. Server responses
  should set these headers and support resumable SSE streams. Current client and
  server only support stateless POSTs with JSON responses.
- **Server-to-client notifications & requests**: HTTP transport lacks SSE support,
  so logging messages, list change notifications, progress updates, and server
  initiated requests cannot flow.
- **Timeouts and cancellation** (`basic/lifecycle.mdx`, `basic/utilities/cancellation.mdx`):
  no helpers exist for sending or handling cancellation or progress
  notifications.

### Discovery & Manifest
- **Manifest schema drift** (`basic/transports.mdx`, `schema.mdx`):
  generated manifest lacks fields introduced in 2025-06-18 (e.g. `description_for_model`,
  richer transport descriptors, `instructions`). Need to audit against the
  latest schema and expose configuration knobs in `MCPServerConfig`.
- **Capability exposure**: manifest should accurately reflect negotiated
  capabilities (including `logging`, `completions`, resource sub-capabilities).

### Server Capabilities
- **Tools** (`server/tools.mdx`):
  - `call_tool` handlers should return `content`, `structuredContent`,
    `isError`, and optional `outputSchema`. Current handlers expect an
    `outputs` array.
  - `MCPServerTool` lacks fields for `outputSchema` and `annotations`.
  - Pagination cursors (`nextCursor`) are unsupported.
  - `notifications/tools/list_changed` and capability flag plumbing are absent.
  - Error handling must distinguish protocol errors vs execution errors per spec.
- **Prompts** (`server/prompts.mdx`):
  - Response format should allow single content objects and annotations.
  - Pagination and `nextCursor` not supported.
  - No `notifications/prompts/list_changed`.
- **Resources** (`server/resources.mdx`):
  - Method name mismatch (`resources/get` vs `resources/read`).
  - No support for resource templates, subscriptions, or list change notifications.
  - `MCPServerResource` should expose spec-compliant fields (`title`, `annotations`,
    `size`) and handler helpers should produce `text`/`blob` payloads.
- **Logging** (`server/utilities/logging.mdx`):
  - Missing `logging` capability, `logging/setLevel`, and `notifications/message`.
- **Completions** (`server/utilities/completion.mdx`):
  - No plumbing for `completion/complete`, capability declaration, or helper APIs.
- **Utilities (ping/progress/cancellation)** (`basic/utilities/*.mdx`):
  - No helpers for sending `ping`, `progress` or handling cancellation.

### Client Responsibilities
- **Request sequencing** (`basic/lifecycle.mdx`): send `notifications/initialized`
  and guard against issuing feature calls before initialization completes.
- **Extended operations**:
  - Add wrappers for `resources/read`, `resources/templates/list`,
    `resources/subscribe`, `completion/complete`, `logging/setLevel`, `ping`,
    `cancelled`, and `sampling`/`elicitation` request handlers (see
    `client/sampling.mdx`, `client/elicitation.mdx`, `client/roots.mdx`).
  - Handle pagination cursors returned from list operations.
  - Support structured tool responses (`structuredContent`, `isError`).
- **Streaming / notifications**: implement SSE listener so clients can consume
  server notifications (`notifications/message`, `notifications/resources/updated`,
  list change events, etc.) and respond to server-initiated requests.
- **Capability negotiation helpers**: expose ergonomic APIs for setting client
  capabilities (roots, sampling, elicitation) and for registering handlers the
  server can invoke.

### Authorization & Security
- **OAuth metadata** (`basic/authorization.mdx`): extend discovery helpers to
  surface `WWW-Authenticate` parameters like `resource`, `scope`, and issuer
  selection. Ensure HTTP client attaches `Authorization` and `DPoP` headers per
  spec.
- **Origin validation** (`basic/transports.mdx` security warning): HTTP server
  should enforce origin checks and allow binding to loopback-only by default.
- **Annotations**: ensure resource/prompt/tool annotations map cleanly to spec
  keys to avoid leaking unintended metadata.

### Typing & Schema Alignment
- Audit type aliases (`src/types.jl`) against `schema.mdx`:
  - Introduce types for shared content payloads (text/image/audio/resource).
  - Support `_meta` blocks where permitted.
  - Validate enums (log levels, stop reasons, etc.).
- Provide serialization helpers to guarantee responses conform to schema (e.g.
  ensure timestamps are ISO-8601).

## Recommended Implementation Phases

### Phase 1 – Core Protocol Compliance
1. Retrofit HTTP client/server pipeline to include protocol headers and add
   preliminary SSE support (even if notifications are buffered).
2. Update lifecycle: send `notifications/initialized`, add timeout/cancellation
   hooks.
3. Align server methods with spec naming and payloads (`resources/read`,
   structured tool results, annotations).
4. Extend manifest generation/configuration to cover new schema fields.
5. Expand test suite to cover updated request/response shapes.

### Phase 2 – Notifications and Advanced Capabilities
1. Implement logging, completion, and pagination helpers.
2. Add resource templates, subscriptions, and list change notifications.
3. Support prompt/tool/resource `listChanged` flows end-to-end (server + client).
4. Introduce SSE event loop in client to receive notifications and server requests.
5. Provide first-class APIs for registering completion/logging handlers.

### Phase 3 – Client Feature Surface
1. Add sampling and elicitation handler plumbing so client applications can fulfill
   server requests (`client/sampling.mdx`, `client/elicitation.mdx`).
2. Implement roots capability negotiation with list change notifications.
3. Harden authorization flows (refresh token management, DPoP when required).
4. Document migration guide from pre-2025 APIs to new payloads.

## Testing and Validation Strategy
- Unit tests for each JSON-RPC method covering success, error, pagination, and
  annotation handling.
- Integration tests exercising Streamable HTTP with SSE (can use loopback server).
- Contract tests against the official schema (JSON Schema validation of responses).
- Authorization tests using stub issuer/resource metadata (extend existing auth stubs).
- Regression tests for manifest generation and discovery parsing.
- Load/latency checks for SSE reconnection and notification bursts.

## Open Questions & Follow-Ups
- Decide whether to continue supporting legacy `resources/get` / `outputs`
  structures behind a compatibility flag.
- Determine minimum acceptable subset of SSE features (full resumability vs simple
  single-stream) for initial release.
- Evaluate need for a higher-level state machine to coordinate simultaneous
  server→client requests once sampling/elicitation are added.
