# Phase 0 Test Plan

Phase 0 establishes repository contracts only. Product and provider behavior is
outside this phase.

## Contract checks

- Required repository, configuration, documentation, and localization files exist.
- XcodeGen declares macOS, iOS, watchOS, extension, and helper shell targets.
- Debug, Staging, and Release use separate build configurations.
- Bundle identifiers and app-group identifiers follow the approved namespace.
- Release and Staging cannot enable debug-only feature overrides.
- The Swift package dependency graph is acyclic and `AgentDomain` has no platform dependency.
- ADR 0001 through 0008 exist and are accepted.
- Tracked files contain no private keys, credentials, or known secret placeholders.
- Managed configuration policy forbids whole-file replacement.

## Build checks

- `swift test` builds the root package with Swift 6 complete concurrency checking.
- XcodeGen emits `AgentControl.xcodeproj` without manual edits.
- Every generated shell target builds for an available generic destination with code signing disabled.

## Commands

The acceptance command is:

```sh
make bootstrap && make generate && make test
```

