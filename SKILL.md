---
name: model-context-protocol-jl
description: Maintain ModelContextProtocol.jl protocol, transport, conformance, documentation, and JuliaC static-server behavior.
---

# ModelContextProtocol.jl Maintenance

Use this skill for changes in this repository.

1. Read `AGENTS.md`, `ROADMAP.md`, and the guide for the affected protocol
   era.
2. Identify whether the change affects the stateful server, the stateless
   server, the client, the static JuliaC server, or more than one surface.
3. Reproduce the wire behavior before editing. Record the JSON-RPC code, HTTP
   status, metadata, and headers.
4. Implement the smallest change that preserves the other protocol era.
5. Add a focused regression test. Use the official MCP conformance runner when
   it has a matching scenario.
6. Run the package suite, JuliaC trim check, Documenter build, and doctests.
7. Keep new low-level APIs namespaced unless they are a primary user entry
   point.

For MCP `2026-07-28`, start with `docs/src/protocol-2026.md`. For the static
server, start with `docs/src/static-server.md`. Do not infer support beyond the
limits stated in those files.
