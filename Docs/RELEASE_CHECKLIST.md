# yusufiwt 1.0 release checklist

Copy `Config/Operations/release-evidence.example.json` outside the source tree,
fill it with durable exact-build evidence, then run `make test`,
`make release-verify`, and
`ruby Scripts/verify_phase17.rb --release-evidence <record.json>` on the exact
release commit. Stable promotion requires evidence for every item.

## Product and compatibility

- P0/P1 has no incomplete or synthetic-success behavior.
- Published Codex/Claude/Gemini matrix matches shipped policy and fallback.
- Fresh macOS local-only setup/decision works without an account.
- English/Turkish, VoiceOver, keyboard, privacy, retention, diagnostics,
  recovery, and account deletion smoke tests pass.

## Security and operations

- Physical companion pairing, replay/tamper, risk policy, provider ack, key
  rotation/revoke, partition/APNs outage, and account deletion pass.
- No Critical/High issue; threat/privacy/dependency/SBOM reviews match commit.
- Dashboard/alerts are live; each emergency flag and rollback was staged.
- A real support export was scanned for secret/content fixtures before sharing.

## Distribution and promotion

- macOS is signed, notarized/stapled, clean-Mac accepted, and updates from the
  prior stable with helper/migration/decision round trip.
- dSYMs, SBOM, checksums, appcast, notes, and issues are verified.
- iOS/watchOS is TestFlight processed; physical pairing, APNs, notification,
  Live Activity, widgets, and Watch handoff pass.
- App Store privacy/support/deletion metadata and review notes are ready.
- Record commit, builds, Apple IDs, artifacts, devices/OS, evidence, reviewers.
  Promote with two-person approval and observe dashboard thresholds for 2 hours.
