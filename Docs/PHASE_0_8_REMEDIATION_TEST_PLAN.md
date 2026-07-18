# Phase 0–8 Remediation Test Plan

This plan closes the acceptance gaps identified before Phase 9. Phase 9
production work must not begin until the readiness report is `READY`.

## Automated gates

- Run `make bootstrap`, `make generate`, `make test`, and `make lint`.
- Run every `Tests/Contracts/test_phase*_contract.sh` script.
- Phase 2: prove process-crash rollback, committed event/snapshot durability,
  duplicate no-op, migration checksum/no-op, corrupt read-only export, and that
  database disk work is isolated from `MainActor`.
- Phase 3: retain deterministic XPC/signing tests and provide an opt-in signed
  `SMAppService` lifecycle smoke covering force-quit persistence, restore,
  unauthorized clients, and owned-artifact cleanup.
- Phase 5: retain a redacted live-session fixture in normal CI and provide an
  opt-in installed-Codex managed-session smoke covering command/file approval,
  deny, provider acknowledgment ordering, cancellation, and crash/reconnect.
- Phase 6: provide an opt-in live smoke for each installed provider. Missing
  providers are reported as `SKIP`, never `PASS`.
- Phase 7: assert the default hotkey is Control-Option-Space, custom settings
  round-trip, and the active-session list uses lazy/virtualized rows.
- Phase 8: cover stable-ID single choice, stable-ID multi choice, capability-
  bounded free text, confirmation, local-only secret input, and plan Approve /
  Request Changes / Deny without reusing command approval payloads.
- Notifications: validate request ID, revision, expiry, and current membership;
  reject duplicate, expired, and superseded callbacks; show `sending` before
  provider acknowledgment and never infer `applied` locally.
- Scan production sources for secrets, ambiguous TODOs, `fatalError`, and
  approval bypasses.

## Performance budgets

Measure a release build on the designated release Mac, with five warm-up runs
and twenty recorded runs:

| Scenario | Acceptance threshold |
|---|---:|
| 100 active sessions, first rendered list update | p95 <= 100 ms |
| 100 active sessions, programmatic full-list scroll | p95 frame hitch <= 16.7 ms and no hitch > 50 ms |
| Event received to UI read-model update | p95 <= 100 ms |
| Local decision to provider send | p95 <= 100 ms, excluding provider ack |

The unit suite may verify data shape and lazy containers, but it may not claim
the release-hardware performance gate passed. Measurements and hardware details
belong in `Docs/PHASE_0_8_REMEDIATION_REPORT.md`.

## Opt-in environment gates

- `AGENTCONTROL_RUN_LIVE_CODEX=1`: installed and authenticated Codex smoke.
- `AGENTCONTROL_RUN_SIGNED_HELPER=1`: signed development app/helper lifecycle.
- `AGENTCONTROL_RUN_LIVE_PROVIDERS=1`: installed provider hook smoke matrix.
- `AGENTCONTROL_RUN_UI_PERFORMANCE=1`: release-build 100-session Instruments/UI
  performance run.

An unavailable binary, signing identity, permission, or sandbox capability is a
documented `Blocked` or `Not applicable` result. It must not be converted into a
successful fixture result.

## Public notification and Focus boundary

AgentControl registers public UserNotifications categories and interruption
levels. macOS applies the user's Focus settings; AgentControl does not inspect,
simulate, or bypass system Focus. AgentControl quiet hours are a separate local
policy tested with an injected clock.

