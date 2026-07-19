# yusufiwt macOS Local V1 Release Checklist

Final gate: **CONDITIONAL** — 2026-07-19

## Scope and build

- [x] Mac Local scope, ADR and V2 defer decision documented.
- [x] `AgentControlMacLocal` scheme and `MacLocalRelease` config build.
- [x] iOS/watch/relay/APNs/Sparkle runtime absent from local target/bundle.
- [x] Local app/helper works without an account or network connection.
- [x] Universal app, ZIP and SHA-256 outputs exist.
- [x] Deep strict code-sign verification passes.
- [x] Signing mode truthfully recorded as ad-hoc; notarization not claimed.

## Runtime and UX

- [x] App process, menu bar extra, dashboard and floating panel run.
- [x] Helper, XPC, socket, SQLite and doctor are healthy.
- [x] App force-quit leaves helper alive.
- [x] Fake sessions and parent/subagent are visible in the UI.
- [x] Turkish/English Phase 10 localization table defect fixed and AX-checked.
- [x] Global keyboard shortcut opens the panel.
- [ ] `MANUAL_REQUIRED`: VoiceOver/Reduce Motion/contrast human pass.
- [ ] `MANUAL_REQUIRED`: real terminal exact-pane result with captured metadata.

## Providers and decisions

- [x] Managed preview/install/backup/repair/uninstall implementation and tests.
- [x] Codex/Claude/Gemini capability/version preview runs locally.
- [x] Fake approval approve and deny round-trip.
- [x] Fake question stable choice and plan review round-trip.
- [x] Provider-ack lifecycle tests prohibit early success.
- [ ] `BLOCKED_EXTERNAL`: real Codex session appears in yusufiwt.
- [ ] `BLOCKED_EXTERNAL`: real Codex approve succeeds only after provider ack.
- [ ] `BLOCKED_EXTERNAL`: real Codex deny and completion pass.

## Notifications

- [x] macOS authorization granted after explicit System Settings enable.
- [x] Completion, failure and waiting-approval requests added with no OS error.
- [x] Preference persistence, privacy, dedupe and secret-question tests pass.
- [ ] `MANUAL_REQUIRED`: click Approve and Deny from a real provider notification.

## Local P0, recovery and security

- [x] History/rules/analytics/diagnostics run on local data.
- [x] Privacy/redaction/encryption/retention/delete tests pass.
- [x] Duplicate/order/malformed/state-machine tests pass.
- [x] Helper restart restores snapshot.
- [x] Missing helper spools; restart imports and clears spool.
- [x] Uninstall preserves data and removes only managed changes.
- [x] Reinstall returns healthy app/helper.
- [x] No app/helper external network socket; relay/APNs not initialized.
- [x] No open Critical/High local security bug found.
- [ ] `MANUAL_REQUIRED`: reboot, login, doctor, menu item and restored session.

## Quality and performance

- [x] Swift packages: 162 tests / 31 suites pass; relay: 12 tests pass.
- [x] `make lint`: 0 violations.
- [x] Event→helper p95 0.74 ms.
- [x] Decision→adapter p95 114.38 ms.
- [x] First usable AX view 1,485 ms.
- [x] App/helper average idle CPU 1.37% / 0.10%.
- [x] App/helper physical memory 46 MB / 5.1 MB.
- [x] 100k ingestion 7.666 s; analytics query <0.001 s.
- [x] Helper leak smoke: 0 leaks.
- [ ] `MANUAL_REQUIRED`: event→render p95 with Instruments.
- [ ] `MANUAL_REQUIRED`: 100-session scroll hitch and live 1,000-event socket run.
- [ ] `MANUAL_REQUIRED`: unrestricted app leak trace (release process was restricted).

## Artifacts

- [x] `dist/yusufiwt.app` — 31 MB.
- [x] `dist/yusufiwt-macOS-local-v1.zip` — 9.8 MB.
- [x] `dist/SHA256SUMS.txt` current.
- [x] ZIP includes install/uninstall scripts, signing metadata and install guide.
- [x] `make verify-mac-local-v1` passes package and live doctor gates.

Do not mark this checklist PASS until every unchecked `BLOCKED_EXTERNAL` and
`MANUAL_REQUIRED` release item is completed with evidence.
