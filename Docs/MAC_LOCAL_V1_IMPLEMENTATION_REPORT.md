# yusufiwt macOS Local V1 Implementation Report

Date: 2026-07-19  
Host: macOS 26.5.2, Apple Silicon, Europe/Istanbul  
Source baseline: `main` at `3ca9d6f`

## 1. Final status

**CONDITIONAL**

The Mac-only product builds, packages, installs, launches, persists real local
events, returns real local decisions, posts local notifications, survives UI
force-quit, restores after helper restart, and passes the automated release
suite. The gate is not PASS because a new account-backed Codex session was not
started, a real reboot was not performed, and the remaining UI-level
performance/notification-action observations need user-controlled validation.

## 2. Scope

Included in Mac Local V1:

- Universal macOS app, menu bar extra, floating panel, dashboard and settings.
- Same-user helper, XPC and mode-0600 Unix socket.
- SQLite/WAL history, rules, analytics, diagnostics, privacy and retention.
- Codex, Claude and Gemini managed hook preview/install/repair/uninstall tooling.
- Approval, question and plan decision paths with provider-acknowledgment state.
- Local completion, failure, waiting and idle notifications.
- Safe install, upgrade, uninstall and ad-hoc development fallback.

Deferred to V2: relay, accounts, remote access, SSH nodes, APNs, iOS, watchOS,
widgets/live activities, direct LAN, telemetry and Sparkle runtime updates. See
[scope](MAC_LOCAL_V1_SCOPE.md) and [ADR-0022](ADR/0022-mac-local-v1-release-scope.md).

## 3. Baseline findings

The repository already contained strong domain, protocol, SQLite, helper,
socket/XPC, provider adapter, history, rules, privacy and macOS UI foundations.
It was partial because the full Mac target still shared V2 dependencies, there
was no physical Mac Local distribution contract, notification preferences were
not fully persisted/exposed, and provider lifecycle commands were incomplete.
The evidence-first baseline is in [the gap matrix](MAC_LOCAL_V1_GAP_MATRIX.md).

Live testing found and fixed three non-theoretical defects:

1. Different provider project IDs for the same repository violated the unique
   stable-path constraint. Project persistence now chooses a canonical row by
   path, then ID.
2. Replacing an ad-hoc app caused `SMAppService` launch constraints to reject
   the helper. Ad-hoc packages now install a same-user LaunchAgent; Apple
   Development/Developer ID builds retain ServiceManagement registration.
3. `Phase10.xcstrings` compiled as a separate table while call sites used the
   default table. Those strings were merged into `Localizable.xcstrings`.

## 4. Architecture changes

- Added `MacLocalRelease` and `AgentControlMacLocal`; the 14-target build graph
  contains only the app, helper, hook and required local packages.
- Added an explicit `mac-local-v1` manifest and Info.plist scope marker.
- Moved companion authority out of `AgentLocalIPC` into
  `AgentCompanionAuthority`, removing companion reachability from the local graph.
- Added fail-closed Mac Local feature policy and config flags.
- Added helper registration repair that preserves spool data, plus an ad-hoc
  user LaunchAgent installer fallback required by macOS launch constraints.
- Reduced recovery polling from 2 to 10 seconds; registry notifications still
  trigger immediate refresh.

The architectural rationale and downgrade boundaries are recorded in ADR-0022.

## 5. Changed files

Build and release:

- `project.yml`, `Config/MacLocalRelease.xcconfig`,
  `Apps/macOS/Info-MacLocal.plist`, `Makefile`.
- `Scripts/{build,package,install,uninstall,test,verify}_mac_local*.sh`.
- `Tests/Contracts/test_mac_local_v1_contract.sh`.

Runtime and persistence:

- `AgentControlMacApp.swift`, `LaunchAgentManager.swift`, helper main.
- `DatabaseActor+Writes.swift` canonical project upsert.
- `AgentControlStore.swift`, notification policy/coordinator and Phase 10 UI.
- `FakeAgentScenarios.swift` and simulator decision CLI.

Provider and graph separation:

- Root/nested `Package.swift`, `AgentCompanionAuthority` target.
- `AgentControlHookMain.swift` managed lifecycle commands.
- `FeatureFlagPolicy.swift` Mac Local release profile.

Tests and documentation:

- Database, IPC, UI, feature-policy and performance regressions.
- Scope, ADR, install, release process, QA matrix, README/product/changelog.
- UI evidence under `Docs/Evidence/`.

## 6. Build outputs

| Artifact | Exact path | Size | SHA-256 |
|---|---|---:|---|
| App | `~/Projects/yusufiwt/dist/yusufiwt.app` | 31 MB | `9ad9be05a3923b45dcafae3f718f368bbfcc661d1382296f8a1a50d7f5ebcae8` |
| ZIP | `~/Projects/yusufiwt/dist/yusufiwt-macOS-local-v1.zip` | 9.8 MB | `e60303c2ac9f104b121a9ecfd297354246a3c8b93a6e82cc583e1782f619addd` |

The app checksum is a deterministic sorted tree hash, since `.app` is a
directory. `dist/SHA256SUMS.txt` records both values. The executable is universal
`x86_64 arm64`. Signing is hardened-runtime **ad-hoc**, identifier
`com.yusuf.agentcontrol.mac`, no TeamIdentifier because the host has zero valid
code-signing identities. Nested binaries are signed before the app and
`codesign --verify --deep --strict` passes.

Notarization: **NOT APPLICABLE FOR MAC LOCAL V1**. No Developer ID identity was
available and no notarization was attempted or claimed.

The ZIP contains the app, installer, uninstaller, signing metadata and install
guide; extraction preserves and re-verifies the app signature.

## 7. Runtime evidence

- Validated app path: `~/Projects/yusufiwt/dist/yusufiwt.app`.
- App process launched and exposed a real AX dashboard in 1,485 ms.
- Menu/dashboard showed 33+ live fake sessions, inbox state and localized views.
- Control-Option-Space opened the real floating panel; screenshot:
  [floating panel](Evidence/mac-local-v1-floating-panel.png).
- Localized dashboard screenshot:
  [dashboard](Evidence/mac-local-v1-dashboard-localized.png).
- Helper LaunchAgent path:
  `~/Library/LaunchAgents/com.yusuf.agentcontrol.helper.plist`.
- Final helper PID during evidence: `77838`; same-user LaunchAgent state running.
- Socket: `~/Library/Application Support/AgentControl/ipc/helper.sock`, owner
  current user, mode `srw-------`.
- SQLite: `~/Library/Application Support/AgentControl/agent-control.sqlite`, WAL.
- Final doctor: database healthy, socket accepting, spool pending 0, 35 active
  sessions and 51 persisted events.
- `lsof -i` returned no sockets for app or helper; the local runtime made no
  relay/APNs/network connection.

## 8. Fake Agent evidence

The installed helper returned these real socket responses:

| Scenario | Result |
|---|---|
| running | appended |
| progress | recorded without state change |
| approval approve | decision approve round-trip |
| approval deny | decision deny round-trip |
| question choice | stable choice ID round-trip |
| plan approve | decision approve round-trip |
| parent → subagent | both events appended after fixture repair |
| completion | running and completed appended |
| failure | running and failed appended |
| duplicate | duplicate/no reapply |
| out-of-order | stale event did not regress state |
| malformed | safe `helper.request_failed` rejection |

The first live run exposed the canonical-project bug; the repaired run and its
regression test pass.

## 9. Live provider evidence

- Installed Codex: `codex-cli 0.145.0-alpha.18`.
- Managed preview produced scoped lifecycle matrices for Codex, Claude and
  Gemini without modifying user configuration.
- Fixture/adapter tests cover Codex correlation, provider output schemas,
  approval lifecycle and the rule that outbox success is impossible before
  provider acknowledgment.

`BLOCKED_EXTERNAL`: no new account-backed Codex model session was started, and
the existing user Codex configuration was not mutated. Therefore real Codex
session visibility, live approve, live deny, provider ack and completion are not
claimed. This avoided extra account usage as requested by the repository owner.

## 10. Notifications evidence

- System Settings initially showed yusufiwt notifications off. After the
  explicitly requested permission was enabled and the app restarted, the log
  recorded `didGrant: 1 hasError: 0`.
- Completion, failure and waiting-approval fixtures each produced
  `Adding notification request` followed by `Added ... hasError: 0` in the real
  UserNotifications subsystem.
- Five action categories are registered; approval/plan expose approve, deny,
  review and terminal actions. Secret questions never expose an inline answer.
- Settings persist global, decision, completed, failed, idle, sound, focus,
  quiet-hours and privacy policy values. Default notification text is generic
  and does not include prompts.

`MANUAL_REQUIRED`: click a real approval notification's Approve and Deny buttons
while a real provider is waiting; automated policy tests pass, but the final OS
action click was not presented as live-provider evidence.

## 11. Recovery evidence

- `kill -9` of the app left helper running and healthy.
- Helper bootout made a fake event return `spooled`; bootstrap/kickstart imported
  it and returned spool count 0.
- Helper restart restored the persisted snapshot and active-session count.
- Uninstall removed app/helper registration, preserved the SQLite file, and a
  reinstall restored a healthy runtime.
- Installer upgrades through a verified staging path and backs up the prior app
  until replacement succeeds.
- Provider uninstall is restricted to marked AgentControl blocks; fixture tests
  prove unrelated JSON/JSONC/TOML content and external edits are preserved.

`MANUAL_REQUIRED`: perform a real Mac reboot, log in, run doctor, and confirm the
menu item plus restored sessions. LaunchAgent unload/bootstrap is the completed
near-reboot test; reboot itself is not claimed.

## 12. Performance measurements

| Measurement | Result | Evidence quality |
|---|---:|---|
| Event → helper socket p95 | 0.74 ms, n=40 | automated real socket |
| Local decision → adapter p95 | 114.38 ms, n=20 | installed helper + fake adapter |
| First usable AX view | 1,485 ms | cold UI launch |
| App idle CPU | 0.0%, 1.9%, 2.2%; avg 1.37% | three 3-second samples |
| Helper idle CPU | 0.0%, 0.0%, 0.3%; avg 0.10% | three 3-second samples |
| App/helper idle memory | 46 MB / 5.1 MB | `top` physical memory |
| 100 sessions | 100 persisted in fixture | UI scroll remains manual |
| 1,000-event burst | 1,000-event transactional batches | live socket burst remains manual |
| 100k ingestion | 7.666 s | automated |
| 100k analytics query | <0.001 s reported as 0.000 s | automated |
| Leak smoke | helper 0 leaks; app restricted scan 14,288 bytes/284 system-visible allocations | partial |

The prior 2-second polling consumed 3.7–4.7% idle CPU. Registry-driven updates
plus a 10-second recovery fallback reduced the measured average to 1.37%.

`MANUAL_REQUIRED`: collect Instruments signposts for true event→render p95,
100-session scroll hitch, a live 1,000-event socket burst and a full unrestricted
app leak trace. These are not represented by build success.

## 13. Security, privacy, accessibility and localization

- Same-user XPC authorization, expected bundle identifiers and mode-0600 socket.
- Ad-hoc allowance is compile-time restricted to Debug/Mac Local; high/critical
  automation remains fail-closed.
- Sensitive payload encryption/tamper rejection, secret persistence refusal,
  retention/delete and redacted diagnostics tests pass.
- No prompt, code or secret is persisted by default; notifications default to a
  generic privacy level.
- Mac Local artifact scan contains no watch, notification-service, relay or
  Sparkle runtime artifact. The project still declares cached Sparkle for the
  separate full product, but it is absent from the 14-target local graph/bundle.
- Turkish/English catalog is valid and the raw Phase 10 table-key defect is
  fixed. AX inspection showed localized sidebar, session state and panel labels.
- VoiceOver labels, keyboard hotkey and missing-permission fallback have tests.
- Source scan found no ambiguous TODO/FIXME, unimplemented fatal error,
  placeholder success or credential pattern in the local production surface.
- No open Critical/High local security defect was found.

## 14. Commands run

All listed commands exited 0 in their final run unless marked otherwise:

- `git status --short` — 0, initial worktree clean; final expected changes listed.
- `make bootstrap` — 0.
- `make generate` — 0.
- baseline/full `swift test` — 0 outside sandbox; 5 socket tests only failed
  inside sandbox with expected `EPERM` before rerun.
- `make test-mac-local` — 0; **152 tests, 29 suites** plus package contract.
- `make lint` — 0; SwiftFormat 0 files, SwiftLint 0 violations.
- `make persistence-performance` — 0 after canonical project fix.
- `make package-mac-local` — 0; Xcode build succeeded.
- Installer target — `/Applications/yusufiwt.app`.
- `make uninstall-mac-local` — 0; data preserved; reinstall 0.
- `make verify-mac-local-v1` — 0; signature, ZIP, scope and live doctor.
- fake scenario matrix — expected success/rejection results above.
- `codesign --verify --deep --strict` — 0.
- `lipo -archs` — `x86_64 arm64`.
- UserNotifications delivery log — completion/failed/waiting added with no error.
- `leaks` — helper complete/0; app partial due hardened-process restriction.

## 15. Remaining blockers

1. `BLOCKED_EXTERNAL` — real Codex model session, approve, deny, ack and
   completion. Requires account usage and temporary managed-hook installation.
2. `MANUAL_REQUIRED` — real reboot/login persistence check.
3. `MANUAL_REQUIRED` — real notification action click and terminal exact-pane
   navigation using a session with real terminal metadata.
4. `MANUAL_REQUIRED` — Instruments event→render, 100-session UI scroll,
   1,000-event live socket and unrestricted leak measurements.
5. Distribution remains ad-hoc. Developer ID signing/notarization is outside Mac
   Local V1 and requires an external certificate/account.

## 16. How to run now

```sh
cd ~/Projects/yusufiwt
make bootstrap
make test-mac-local
make lint
make package-mac-local
ditto -x -k dist/yusufiwt-macOS-local-v1.zip /private/tmp/yusufiwt-release
/private/tmp/agentcontrol-release/install_mac_local.sh
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook doctor
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook managed-preview codex
make verify-mac-local-v1
```

For the user-controlled live Codex gate:

```sh
mkdir -p /private/tmp/agentcontrol-live-codex
cd /private/tmp/agentcontrol-live-codex && git init
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook managed-install codex
codex -C /private/tmp/agentcontrol-live-codex -a untrusted -s workspace-write
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook managed-uninstall codex
```

In that Codex session, request one harmless write, approve it, then request a
second harmless write and deny it. Confirm dashboard/provider-ack/completion,
then remove the managed hook as shown.
