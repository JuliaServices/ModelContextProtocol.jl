# First registered release

The package currently identifies as 1.0.0 and is consumed from immutable Git
revisions. Its initial registered release should be prepared from a reviewed
commit after the package and documentation checks pass.

1. Confirm General registration readiness, including the optional Agentif
   extension's dependency metadata. Agentif's first registration is tracked
   separately from this package.
2. Run `Pkg.test()` and the documentation build as required by `AGENTS.md`.
   The test suite includes the static JuliaC tools subset's trim check on
   supported Julia versions.
3. Register the reviewed 1.0.0 commit, then verify General's install/load
   checks, the release tag, and the GitHub release.
4. Replace downstream Git sources with the registered release and resolve
   their lockfiles.

The full implementation supports stateful MCP 2025-11-25 and stateless MCP
2026-07-28. The static implementation remains a tools-only 2025-11-25 subset.
Publishing a release does not establish live webhook delivery to a client.

This document records pending publication steps; it does not mean that a
registered version or release tag already exists.
