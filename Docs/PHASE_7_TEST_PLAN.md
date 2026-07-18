# Phase 7 Test Plan

## Automated acceptance coverage

`AgentMacUITests` verifies:

- placement on the display containing the cursor;
- clamping to visible fullscreen bounds;
- loading 100 active sessions without truncation;
- retaining the last snapshot on disconnect and refreshing after reconnect;
- resolving an approval through the keyboard action path.
- defaulting to Control-Option-Space and round-tripping a versioned custom
  shortcut setting.
- using SwiftUI `List`/lazy containers so 100 rows are virtualized.

The 100-session unit fixture is not the release performance acceptance. The
release gate and p95 thresholds are defined in
`PHASE_0_8_REMEDIATION_TEST_PLAN.md` and require the opt-in UI performance run.

The Phase 7 contract verifies the menu bar, floating panel, global hotkey,
XPC notification stream, core dashboard sections, accessibility hooks,
Reduce Motion handling, and complete English/Turkish catalog entries.

## Manual smoke test

1. Launch the helper and macOS app; confirm the menu bar status is visible.
2. Press Control-Option-Space on each display and beside a fullscreen app.
3. Expand/collapse the panel and open Overview, Active, Inbox, and a session.
4. Disconnect/restart the helper; confirm existing rows remain and the offline
   banner clears after reconnect.
5. Navigate Inbox with the keyboard and approve/deny a fixture request.
6. Repeat with Reduce Motion enabled and VoiceOver running.
7. Launch once in English and once in Turkish; confirm no raw localization keys.

## Commands

```sh
make contract-test
./Scripts/test_swift.sh
./Scripts/test_all.sh
```
