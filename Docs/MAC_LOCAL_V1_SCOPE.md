# Mac Local V1 Scope

## Included

- A notch-first native macOS shell: the helper and menu bar start at launch, while the full Control Center opens only after an explicit user action.
- A focused Control Center for integrations, automation/rules, history/analytics and privacy/diagnostics, plus native persisted Settings for language, notification/sound and panel behavior.
- Managed local hooks for Codex, Claude Code, Gemini CLI and Cursor. Cursor session, scoped `preToolUse` write/delete/task decisions, shell/MCP decisions and context-compaction events use its official hook contract; Cursor Agent questions and plan-review waiting remain explicitly unsupported because that contract does not expose them.
- Helper-owned Unix socket, SQLite persistence, XPC read model, decisions, rules, diagnostics, retention and local notifications.
- Preview-first managed hook install/repair/uninstall and terminal/IDE navigation.
- Development or ad-hoc local packaging with explicit signing evidence.

The product works without an account or internet connection. Provider decisions are never shown as applied before provider acknowledgment. Usage is displayed only from structured provider fields: quota remaining, context remaining and token counters remain distinct, and unavailable data is never represented as zero.

## Deferred to V2, preserved

iOS/watchOS companions, notification service extension, widgets/live activities, relay runtime, APNs, Sign in with Apple, pairing, remote/SSH nodes, TestFlight/App Store, Developer ID notarization and Sparkle update delivery remain in the repository but outside the Mac Local V1 build/runtime/release gate.

## Feature defaults

`MacLocalRelease` disables remote mode, SSH, watch, direct LAN, telemetry, iOS companion, relay, APNs, Sparkle and managed Codex sessions. Local hooks, helper persistence and macOS local notifications remain enabled.
