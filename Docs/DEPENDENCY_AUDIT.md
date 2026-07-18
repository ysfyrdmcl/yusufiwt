# Dependency and SBOM audit

The Apple clients use system frameworks, local Swift targets, and Sparkle 2.9.2,
which is exact-version pinned in `project.yml` for direct macOS updates. The relay's
41 resolved Swift packages are pinned by revision in
`Services/AgentControlRelay/Package.resolved`. Direct dependencies are Vapor,
Fluent, PostgreSQL/SQLite drivers, Redis, JWTKit and Swift Crypto; each is used by
the relay boundary described in `SECURITY.md`.

`ruby Scripts/generate_sbom.rb` deterministically emits the checked-in CycloneDX
1.5 inventory at `Config/SBOM/agentcontrol.cdx.json`. Regenerate it after every
dependency resolution and review the diff. RC sign-off must attach a current
OSV/GitHub Advisory scan of that exact SBOM/resolved revision set, including the
Sparkle binary artifact and its release signature. Any Critical
or High result blocks release unless proven unreachable and recorded in a
security ADR; Moderate/Low findings require an owner and due date.

The 2026-07-18 source review found no vendored or unpinned URL dependency,
package plugin, source-package executable build-tool dependency, or
dependency-owned secret. Sparkle is an exact-version-pinned binary target; its
official release artifact is resolved by SwiftPM and recorded in the SBOM.
