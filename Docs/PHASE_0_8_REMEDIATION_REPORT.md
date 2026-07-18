# Phase 0–8 Remediation Report

**Date:** 18 July 2026  
**Working-tree base:** `52eae6d`  
**Scope:** Phase 0–8 only; no Phase 9 production implementation was added.

The remediation changes are currently uncommitted. Therefore the project plan
does not mark a remediated phase `Verified` with a new commit SHA.

## Acceptance result

**Phase 9 readiness: NOT READY**

Automated regression, contracts, lint, unsigned target builds, persistence
crash recovery, and an installed-Codex handshake pass. The remaining blockers
require a signed development app, OS notification interaction, release-hardware
UI measurement, or an authenticated live agent task that can consume account
usage.

| Phase | Result | Evidence / blocker |
|---|---|---|
| 0 | Blocked | Bootstrap/generate/contracts/build pass; clean-clone CI and remediation commit SHA are not available in this working tree |
| 1 | Verified | Domain/state/risk tests pass; AgentDomain coverage 96.96%, RiskClassifier 100% |
| 2 | Verified | Atomic/duplicate/migration/corrupt recovery tests pass; separate SQLite process crash smoke passes; production helper uses detached database open |
| 3 | Blocked | App now registers `SMAppService`; unregister cleanup tests pass, but the produced acceptance build is unsigned/ad-hoc and no signed force-quit E2E was run |
| 4 | Verified | Contract and real Unix-socket event round-trip test pass under the 500 ms p95 assertion |
| 5 | Blocked | Installed Codex schema and real initialize handshake pass; no authenticated managed turn with command + file approval was started |
| 6 | Blocked | Codex is installed; Claude and Gemini are Not applicable on this Mac. Live config install/repair/uninstall was not run against the user's real config |
| 7 | Blocked | Default/custom hotkey and virtualized list tests pass; release UI first-render and scroll-hitch measurement is missing |
| 8 | Blocked | All question/plan payload and notification callback tests pass; real UserNotifications action → helper → provider acknowledgment E2E is missing |

## Remediation details

### 1. Managed Codex acceptance

Previous state: only recorded controller/fixture coverage existed.

Changes and evidence:

- Replaced sensitive-looking fixture command/path values with redacted values.
- Generated the installed Codex JSON schema and found command approval, file
  approval, and `serverRequest/resolved` protocol surfaces.
- Ran a real, non-model `initialize` handshake against Codex
  `0.145.0-alpha.18`; the server returned its user agent, Codex home, and macOS
  platform result.
- Existing tests prove command/file correlation, deny/approve, no `applied`
  before provider resolution, final acknowledgment states, cancel/crash, and
  bounded reconnect behavior.

Blocker: a real managed turn would call a model and use account quota. It was
not started without the explicit live opt-in described in the remediation test
plan.

### 2. Global hotkey

Previous state: hard-coded Command-Shift-A.

Changes and evidence:

- Default is now Control-Option-Space (`keyCode 49`).
- A versioned UserDefaults value preserves an explicit user selection.
- macOS Settings offers Control-Option-Space and Command-Shift-A; changes update
  the running event monitors.
- Unit and Phase 7 contract tests verify the default and persistence.

### 3. 100-session performance

Previous state: the test only counted 100 session objects.

Changes and evidence:

- The active list uses SwiftUI `List`; panel/history surfaces use lazy stacks.
- The test plan now defines release thresholds: first-render p95 <= 100 ms,
  scroll hitch p95 <= 16.7 ms, and no hitch > 50 ms.
- The read-model 100-session fixture completed in approximately 1 ms in the
  debug test run.

Blocker: this is not a release render/scroll measurement. Instruments/UI
measurement on the designated release Mac remains required.

### 4. Question and plan contracts

Previous state: labels were decision payloads and multi-choice, confirmation,
and Request Changes had no distinct wire decisions.

Changes and evidence:

- Added structured `QuestionChoice { id, label }`; new encoders emit stable IDs
  and legacy label arrays decode at the compatibility boundary.
- Added single choice, multi choice, free text, confirmation, and secret domain,
  IPC, provider-mapping, broker-validation, and UI behavior.
- Free text enforces the provider schema `maxLength` capability.
- Secret answers are rejected by the broker and notification path and retain
  terminal-only fallback.
- Plan decisions now have distinct Approve, Request Changes (bounded text), and
  Deny payloads.

Tests cover valid/invalid stable IDs, duplicate multi-selection IDs, length
bounds, secret rejection, and plan-change separation.

### 5. Notification action round-trip

Previous state: categories existed, but callbacks did not report or test stale,
expired, secret, or duplicate outcomes and permission failure was ignored.

Changes and evidence:

- Authorization now records authorized/denied degraded state.
- Callback handling validates request ID, current revision, expiry, decision
  kind, and secret restrictions.
- Duplicate/not-found, expired, superseded, and invalid actions return explicit
  dispositions and acknowledgment UI states.
- UI still transitions through `sending` and `sentToProvider`; it never invents
  `applied` before provider acknowledgment.
- Public UserNotifications categories/interruption levels are used. macOS owns
  Focus enforcement; local quiet hours remain fake-clock testable.

Blocker: real notification delivery/action and provider acknowledgment require
launching the signed app and interacting with OS notification permission/UI.

### 6. Persistence

Previous state: transaction behavior was in-process and the production helper
could synchronously construct the database from an inherited executor.

Changes and evidence:

- Added a separate-process WAL crash smoke: the process is killed after event +
  snapshot inserts but before commit; reopen observes `0:0`. The committed path
  observes `1:1`, duplicate/migration inserts are no-ops, and integrity is `ok`.
- Added `DatabaseActor.open`, which performs open/migration in a detached utility
  task; `HelperHost` uses it. A MainActor caller test passes.
- Existing tests cover event/snapshot rollback, committed WAL reopen, migration
  checksum/no-op, encryption, read-only recovery/export, and corrupt diagnosis.
- The opt-in 100,000-event fixture passed in 10.012 seconds test time (20.23
  seconds wall time including build/startup).

### 7. Helper lifecycle

Previous state: production app did not initiate registration; unregister only
removed socket/handoff artifacts.

Changes and evidence:

- The macOS app now initializes `LaunchAgentManager` and registers the bundled
  `SMAppService`, while retaining offline retry behavior if approval is pending.
- Unregister removes only the owned socket, handoff, and private spool after
  UID/type/permission validation; the event database is preserved.
- Registration, idempotent unregister, cleanup, XPC secure coding, signature
  policy, reconnect, socket persistence, and restore tests pass.

Blocker: the test build used `CODE_SIGNING_ALLOWED=NO`; signed registration,
force-quit persistence, unauthorized live client, and uninstall residue checks
must be run with a development identity.

### 8. Provider smoke

Previous state: provider integrations were fixture-only.

Evidence on this Mac:

- Codex: installed, version and schema detected, real app-server initialize
  handshake passed.
- Claude Code: Not applicable (binary not installed).
- Gemini CLI: Not applicable (binary not installed).
- Fixture tests still prove diff preview, backup, stale-preview rejection,
  managed merge/repair, uninstall scoping, native fallback, event mapping, and
  unknown-version monitor-only behavior.

Blocker: modifying the user's real provider config and starting an authenticated
task were deliberately not performed without the live opt-in.

## Commands and results

| Command | Result |
|---|---|
| `make bootstrap && make generate` | Pass |
| `make test` | Pass: contracts, Swift tests, all macOS/iOS/watchOS targets |
| `make lint` | Pass: SwiftFormat clean; SwiftLint 0 violations |
| all `Tests/Contracts/test_phase*_contract.sh` | Phase 0–8 pass |
| `Scripts/test_persistence_process_crash.sh` | Pass |
| `make persistence-performance` | Pass: 100,000 events; 10.012 s test / 20.23 s wall |
| installed Codex schema generation | Pass |
| installed Codex `initialize` handshake | Pass; no model call |
| production secret/TODO/fatalError/bypass scan | No fatalError/TODO/secret literal; expected policy keywords only |

## Remaining gate

Do not begin Phase 9. Run the live Codex managed turn, signed helper lifecycle,
real notification action/provider acknowledgment, live Codex hook lifecycle,
release UI performance measurement, clean-clone CI, and then commit the
remediation so verified plan rows can reference an actual SHA.
