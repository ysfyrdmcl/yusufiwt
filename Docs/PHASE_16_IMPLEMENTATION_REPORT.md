# Phase 16 implementation report

- Date: 2026-07-18
- Status: Implemented, pending protected-environment verification
- Commit: Uncommitted working tree

## Implemented

- Developer ID Release archive/export, Hardened Runtime, dSYM, ZIP/DMG,
  notarization, stapling, Gatekeeper, checksum, and CycloneDX SBOM pipeline.
- Sparkle 2.9.2 exact pin, SwiftUI updater entry point, HTTPS stable/beta feeds,
  Ed25519 public/private key boundary, signed appcast generation, and retained
  update artifacts.
- Build-generated app/helper compatibility manifest binding version/build,
  local protocol, helper SHA-256, and hook SHA-256.
- iOS/watchOS archive plus App Store Connect export/TestFlight upload pipeline,
  production entitlement/archive verification, symbols, SBOM, and checksums.
- Protected GitHub release workflow, fail-closed artifact verifier, ADR, runbook,
  and Phase 16 contract/test plan.

## Local evidence

- Phase 16 contract and structural verifier: pass (16 verifier assertions).
- Sparkle 2.9.2 resolution and macOS Debug build: pass.
- arm64 optimized macOS Release build: pass; app dSYM UUID matches the binary.
- Full contract suite: pass.
- Root Swift suite: 143 tests pass; AgentDomain coverage 92.12%,
  RiskClassifier coverage 100%.
- Relay suite: 9 tests pass.
- macOS app/helper/hook/simulator/inspector targets: pass.
- Notification Service, Live Activity, and Widgets simulator targets: pass.
- SwiftFormat/SwiftLint: pass, zero violations.
- SBOM regeneration is byte-for-byte deterministic and contains Sparkle 2.9.2.

## Open release evidence

The local machine does not have the watchOS 26.5 platform installed, so the
combined iOS/watchOS simulator scheme cannot run here. Developer ID, Apple
notarization, App Store Connect, APNs, and Sparkle private signing credentials
were intentionally unavailable. Consequently these exact-build gates remain:

- signed archive/export, accepted notarization, staple, and clean-Mac Gatekeeper;
- previous-stable-to-current Sparkle update, migration, and helper restart;
- TestFlight upload/processing and physical iPhone/Watch pairing/push decisions;
- release commit SHA and external submission/build identifiers.

No publishable artifact is produced until the protected workflow satisfies all
of these gates.
