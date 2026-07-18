# Phase 10 Test Plan

## Automated acceptance coverage

`AgentHookKitTests` verifies terminal-context capture, multi-file rollback,
managed install/uninstall/reinstall, preservation of unrelated user hooks, and
hash-gated backup restore after an external edit.

`AgentMacUITests` verifies navigation planning for Terminal.app, iTerm2,
Ghostty, Warp, WezTerm, VS Code, and Cursor; official mechanism priority;
permission-free activation fallback; real result levels; and resumable
onboarding that performs no config write before explicit install.

The Phase 10 contract checks the runtime surfaces, bilingual strings, embedded
hook executable, extension protocol, ADR, test plan, and absence of shell-based
navigation.

## Manual signed-app smoke test

1. On a clean test account, cancel onboarding at every step before install and
   confirm no provider config changes. Interrupt a selected multi-provider
   install and confirm every file is either fully installed or rolled back.
2. Complete onboarding. Confirm notification and helper prompts occur only on
   the explanatory step. Skip navigation permissions and confirm a jump opens
   the application/project without any repeated TCC prompt.
3. Register a live pane in each installed supported terminal/IDE and jump from
   a notification. Confirm the UI reports the real result:
   Terminal.app/iTerm2/Ghostty AppleScript or AX, WezTerm CLI, VS Code/Cursor
   extension, and Warp workspace fallback.
4. Deny Accessibility and Automation, retry three times, and confirm no crash,
   no new system prompt, and an `application` or `projectFolder` result.
5. Add unrelated config fields and user hooks after AgentControl installation.
   Run repair and uninstall; confirm those user changes remain byte-for-byte.
6. Reinstall, externally edit the file, and attempt Restore Backup. Confirm the
   restore is rejected as a conflict rather than overwriting the edit.
7. Send the onboarding test event and confirm it appears in the dashboard.

## Commands

```sh
Tests/Contracts/test_phase10_contract.sh
./Scripts/test_swift.sh
make contract-test
./Scripts/test_all.sh
cd Extensions/agentcontrol-navigation && npm ci && npm run compile && npm run package
```
