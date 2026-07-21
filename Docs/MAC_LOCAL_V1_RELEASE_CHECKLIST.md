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

- [x] Launch graph has no automatic main `Window`/`WindowGroup`; menu bar and notch are the primary shell.
- [x] Explicit, focusable Control Center contains Integrations, Automation/Rules, History/Analytics and Privacy/Diagnostics.
- [x] Native Settings is reachable from the menu bar and `Command-,`; language, notification/sound and panel preferences persist.
- [x] Helper, XPC, socket, SQLite and doctor are healthy.
- [x] App force-quit leaves helper alive.
- [x] Fake sessions and parent/subagent are visible in the UI.
- [x] Mac Local menu/notch/decision/notification/Settings/Control Center strings are in the English/Turkish catalog.
- [x] Global keyboard shortcut opens the panel.
- [ ] `MANUAL_REQUIRED`: VoiceOver/Reduce Motion/contrast human pass.
- [ ] `MANUAL_REQUIRED`: real terminal exact-pane result with captured metadata.

## Providers and decisions

- [x] Managed preview/install/backup/repair/uninstall implementation and tests.
- [x] Codex/Claude/Gemini/Cursor capability/version preview is implemented and fixture-tested.
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
- [x] Missing helper spools telemetry; synchronous decisions remain neutral and are never replayed as stale approvals.
- [x] Uninstall preserves data and removes only managed changes.
- [x] Reinstall returns healthy app/helper.
- [x] No app/helper external network socket; relay/APNs not initialized.
- [x] Wrapped shell privilege escalation/recursive deletion, cross-session decision identity and provider-denial outcomes have regressions.
- [ ] `MANUAL_REQUIRED`: reboot, login, doctor, menu item and restored session.

## Quality and performance

- [ ] Final source suite counts and package hashes must be refreshed by the current release run; historical counts are not release evidence.
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

## Current manual QA script

These checks are intentionally unchecked until performed against the newly
packaged app. Record date, build hash, screen/OS version and observed result for
each item.

1. [ ] Clean launch: terminate the app, relaunch it, and verify only menu bar/notch appears; no Control Center opens automatically.
2. [ ] Menu commands: open Settings and Control Center from the status item; verify `Command-,` focuses Settings.
3. [ ] Notification route: start FakeAgent approval, click the notification body, and verify the matching request is selected without sending a decision.
4. [ ] Acknowledgment boundary: approve once, observe “provider response pending,” then inject/receive provider ack and verify final applied state.
5. [ ] Automatic result: replay the auto-approved fixture; verify no actionable notch/OS approval and a provider-automation history entry.
6. [ ] Humanized command: replay the xcodebuild fixture; verify project/scheme/configuration/destination summary and a redacted raw-command disclosure.
7. [ ] Usage: replay 73% quota and 75% context fixtures, switch sessions, then verify an unavailable provider shows `—`, not `0%`.
8. [ ] Provider decisions: complete one Claude question, Gemini approval and Codex approval; confirm each provider receives its documented stdout schema.
9. [ ] Cursor: complete a scoped write/delete/task decision, a shell/MCP approval and a session/compaction event; verify Agent question/plan controls remain explicitly unsupported.
10. [ ] Sound: turn notification sound off, schedule a new decision/completion notification and verify it is silent in foreground and background.
11. [ ] Language: switch System → Türkçe → English, relaunch, and verify persistence without mixed Mac Local UI strings.
12. [ ] Displays/navigation: move the panel between displays, test Escape and Reduce Motion, then return to the captured terminal/IDE session.
13. [ ] Reconnect: restart the helper while a provider hook is retrying, verify one current pending decision after reconnect, and verify no duplicate notification.
