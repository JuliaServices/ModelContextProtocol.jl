# Repository Guidance

## Scope

`ModelContextProtocol.jl` provides Julia client and server support for MCP over
Streamable HTTP.

- The general implementation supports stateful MCP `2025-11-25` and stateless
  MCP `2026-07-28`.
- The static JuliaC implementation is a separate, tools-only `2025-11-25`
  subset. Do not add dynamic dispatch or unsupported features to it.
- Keep the export surface small. Put specialized and low-level helpers under
  the `ModelContextProtocol` namespace.

## Required checks

Run these checks before you open or merge a pull request:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
julia --startup-file=no --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --startup-file=no --project=docs docs/make.jl
```

`Pkg.test()` includes the JuliaC `--trim=safe` compile check. Test on Julia
1.10 when code uses a Julia API that can differ across supported releases.

## Protocol changes

- Verify wire behavior against the matching dated MCP specification.
- Preserve both protocol eras unless the change explicitly removes support.
- Add a regression test for headers, metadata, JSON-RPC error codes, HTTP
  status codes, and side-effect rules.
- Use the official MCP conformance runner for a changed `2026-07-28` contract
  when a relevant scenario exists. `test/conformance_client.jl` is the client
  adapter.
- Treat authentication, cancellation, and request metadata as security
  boundaries. Do not weaken validation to make one fixture pass.

## Documentation

Update the support matrix in `ROADMAP.md` and the relevant Documenter guide
when behavior or a support limit changes. Examples in `@example` blocks
must build and pass as doctests.
