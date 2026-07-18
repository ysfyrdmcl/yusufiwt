# Incident runbook

## Severity

- **SEV-1:** suspected exposure, unauthorized decisions, widespread outage, or
  release-integrity failure. Freeze promotion and engage security immediately.
- **SEV-2:** relay 5xx above 5%, APNs failures above 10%, crash-free sessions
  below 99.5%, pairing failure, or broken stable update.
- **SEV-3:** localized degradation with a working fallback.

Record time, build/channel, symptoms, dashboard links, operator, and changes.
Never paste tokens, bodies, prompts, commands, paths, ciphertext, or user IDs.

## First 15 minutes

1. Declare severity and freeze release/config changes.
2. Verify `/v1/health`, `/v1/ready`, authenticated `/internal/metrics`, and
   Apple crash metrics.
3. Correlate deploy/build time with relay/APNs/crash changes.
4. Select the narrowest flag in `Config/Operations/emergency-disable.json` and
   obtain a second review for SEV-1/2.
5. Confirm local-only, pending fetch, deletion, and recovery fallbacks.

## Scenarios

For relay/database faults, rollback/scale the immutable deployment and follow
`Docs/RECOVERY_RUNBOOK.md`; disable envelope submission if writes may be unsafe.
For APNs faults, disable APNs while keeping encrypted submission/pending fetch;
disable Live Activities alone when possible. For pairing abuse, disable pairing
while existing rotated/revocable credentials continue. For client crashes,
pause Sparkle/App Store promotion and follow `Docs/ROLLBACK_RUNBOOK.md`.

For suspected security/privacy exposure, disable the affected write path,
rotate relay/APNs/release credentials, preserve access/deploy audit records, and
follow `SECURITY.md`. Request only redacted diagnostics.

Remove flags one at a time with a canary. Require 30 green minutes and a real
device decision round trip. Publish a summary and add regression coverage.
