# Mac Local V1 Gap Matrix

Baseline: `main` at `3ca9d6f`; working tree clean before generation. `make generate` passed. The Swift baseline passed 148 local-package tests and 12 relay tests when run outside the filesystem sandbox; five Unix-socket tests fail with `EPERM` only inside the sandbox. Xcode currently exposes the macOS app/helper/hook targets, but no Mac Local configuration or scheme.

| Area | Status | Evidence and release gap |
| --- | --- | --- |
| Mac-only build configuration and scheme | MISSING | `project.yml` has only Debug/Staging/Release and `AgentControlMac`; that target links Sparkle and companion code. |
| App → helper XPC | VERIFIED_EXISTING | `AgentControlStore` uses `XPCClient`; `HelperXPCListener` routes through the helper authority; XPC contract/auth tests exist. |
| Helper LaunchAgent register/restart/uninstall | PARTIAL | `LaunchAgentManager`, bundled plist, registration and idempotent unregister tests exist. A signed/installed live lifecycle remains to be run. |
| Hook → socket → helper → DB → XPC | VERIFIED_EXISTING | `AgentControlHookClient`, `UnixSocketServer`, `HelperRuntime`, `SessionRegistryActor`, SQLite and notification streams are connected; 148 Swift tests pass outside the sandbox. |
| Codex hook install/repair/uninstall | PARTIAL | Managed patch/backup/repair/uninstall and fixtures exist. Live mutation of the installed Codex config has not been verified on this machine. |
| Real Codex event and approval round-trip | BLOCKED_EXTERNAL | Prior evidence covers installed schema/initialize only. An authenticated disposable session with real approve, deny and provider acknowledgment must still run. |
| Claude/Gemini capability and fixture/live status | PARTIAL | Contract fixtures exist; no live installed-binary smoke evidence. They must ship as Experimental/Monitor-only unless detected capability evidence passes. |
| Menu bar/panel/dashboard live data | PARTIAL | UI reads helper snapshot/notifications through `AgentControlStore`; menu bar currently shows only aggregate counts rather than the required priority cards/details. |
| Completed/failed/waiting notifications | PARTIAL | Decision and rule-alert local notifications exist. Direct completed/failed/waiting notification coverage and persisted per-kind settings are missing. |
| Notification settings persistence | MISSING | `MacNotificationPreferences` is in-memory and Settings exposes only the global hotkey. |
| Questions and plan review | VERIFIED_EXISTING | Stable IDs, secret-terminal fallback, distinct plan semantics and notification action coverage exist in decision tests. Live provider smoke remains part of the real Codex blocker. |
| Rules/long-running/idle/stale detection | VERIFIED_EXISTING | Helper-owned `OperationsRuleEngine`, fake-clock tests and active-alert persistence exist; high/critical automation is rejected. |
| History/analytics/retention/delete | VERIFIED_EXISTING | Helper routes local SQLite history/analytics/privacy/delete operations; persistence/100k fixture tests exist. |
| Terminal/IDE jump | PARTIAL | Exact-pane/workspace/app fallback planner and permission-safe tests exist. A live terminal result-level smoke remains. |
| Diagnostics/self-healing | VERIFIED_EXISTING | Helper diagnostics cover DB/socket/spool and scoped repairs; diagnostic export/redaction tests exist. Live installed helper repair remains. |
| Privacy/redaction | VERIFIED_EXISTING | Persistence filter, masking settings, encrypted sensitive fields, secret-hygiene and diagnostic redaction coverage exist. |
| Accessibility/localization | PARTIAL | Critical views contain accessibility labels, keyboard shortcuts and Reduce Motion behavior; complete Turkish/English catalog coverage requires final verification. |
| Local package/install/uninstall | MISSING | No `build-mac-local`, package, install, uninstall or verify Make targets; no `dist/` app/ZIP/checksums. |
| Offline/no-network behavior | PARTIAL | Local transport/runtime has no network requirement, but the current Mac app still composes Sparkle. A Mac Local composition/build contract is missing. |
| iOS/watchOS/APNs/relay V2 preservation | DEFERRED_V2 | Targets and code exist and must remain buildable, but must be excluded from the Mac Local build/runtime gate. |
| Developer ID/notarization/Sparkle release gate | DEFERRED_V2 | Existing production release scripts remain; Mac Local V1 will use development or ad-hoc signing with explicit limitations. |
| Installable `.app`, ZIP and checksum | MISSING | Required physical outputs do not exist yet. |

The implementation order is A–G from the Mac Local V1 master prompt. `VERIFIED_EXISTING` rows will receive only release-contract coverage or packaging integration where needed; they will not be reimplemented.
