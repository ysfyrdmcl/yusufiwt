# ADR 0021 — Beta, launch and operations boundary

- Status: Accepted
- Date: 2026-07-18

## Context

The 1.0 release needs a controlled alpha profile, compatibility evidence,
privacy-safe support artifacts, operational signals, incident controls, account
deletion, and a release gate that cannot be satisfied by documentation alone.

## Decision

- Shipping features use typed `ReleaseFeatureConfiguration`; emergency disables
  always override rollout enables. Debug overrides remain unavailable in staging
  and production.
- The relay has independently scoped, default-off kill switches for pairing,
  envelope submission, APNs hints, and Live Activities. Recovery paths remain
  available.
- Relay/APNs metrics use bounded labels. `/internal/metrics` exists only when a
  bearer token is configured and never emits user, device, project, token,
  envelope, or payload values.
- Crash health comes from Apple aggregate crash metrics. AgentControl does not
  add content-bearing telemetry solely for a dashboard.
- Diagnostic feedback is an explicit-consent, user-reviewed file export; it
  performs no network request and excludes sensitive/secret attachments.
- iOS account deletion calls an authenticated relay cascade, closes active
  sockets, invalidates credentials, then removes local secure/app-group state.
- `verify_phase17.rb --release-evidence` requires evidence for every 1.0 gate;
  structural readiness cannot approve a release.

## Consequences

Operators must protect the metrics token and collect Apple/physical-device
evidence for the exact release commit. During APNs incidents pending fetch stays
authoritative. A remote client-configuration service is not added for 1.0;
server authority paths are disabled at deployment level.
