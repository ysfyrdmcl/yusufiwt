# Mac Local V1 Scope

## Included

- Native macOS menu bar, panel and dashboard backed by the local helper.
- Local provider hooks, with Codex hook mode as the release-blocking integration.
- Helper-owned Unix socket, SQLite persistence, XPC read model, decisions, rules, diagnostics, retention and local notifications.
- Preview-first managed hook install/repair/uninstall and terminal/IDE navigation.
- Development or ad-hoc local packaging with explicit signing evidence.

The product works without an account or internet connection. Provider decisions are never shown as applied before provider acknowledgment.

## Deferred to V2, preserved

iOS/watchOS companions, notification service extension, widgets/live activities, relay runtime, APNs, Sign in with Apple, pairing, remote/SSH nodes, TestFlight/App Store, Developer ID notarization and Sparkle update delivery remain in the repository but outside the Mac Local V1 build/runtime/release gate.

## Feature defaults

`MacLocalRelease` disables remote mode, SSH, watch, direct LAN, telemetry, iOS companion, relay, APNs, Sparkle and managed Codex sessions. Local hooks, helper persistence and macOS local notifications remain enabled.
