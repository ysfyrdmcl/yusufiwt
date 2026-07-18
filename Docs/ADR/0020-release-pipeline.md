# ADR 0020: Reproducible Apple release pipeline

- Status: Accepted
- Date: 2026-07-18

## Context

AgentControl ships a directly distributed macOS app with an embedded user-level
helper and hook, plus an iOS app containing watchOS and notification/widget
extensions. Release artifacts must be traceable to one version/build and must not
depend on private credentials stored in the repository.

## Decision

- `Release` archives are produced only by the checked-in release scripts and use
  Hardened Runtime, Developer ID/App Store signing, and dSYM generation.
- macOS releases contain a generated compatibility manifest binding the app
  version/build, local protocol version, helper, and hook SHA-256 digests.
- The macOS ZIP and DMG contain the same stapled app. Notarization is mandatory
  unless a developer explicitly selects the non-publishable local dry-run mode.
- Sparkle 2 uses an HTTPS appcast, an Ed25519 public key embedded at build time,
  and a private key supplied only by Keychain or the CI secret store. Stable and
  beta feeds are separate staged channels.
- iOS/watchOS are archived together and uploaded with the App Store Connect
  export path. Production push, app-group, keychain, Sign in with Apple, widget,
  Live Activity, and watch embedding are checked before upload.
- Every published artifact is accompanied by retained archives/dSYMs, CycloneDX
  SBOM, SHA-256 checksums, and release-verifier output.

## Consequences

Signing certificates, notarization credentials, App Store Connect keys, and the
Sparkle private key remain outside source control. A source checkout can verify
the pipeline structure and create unsigned dry-run archives, but only a protected
release environment can produce publishable artifacts or satisfy the external
Gatekeeper, Sparkle-upgrade, and TestFlight gates.

