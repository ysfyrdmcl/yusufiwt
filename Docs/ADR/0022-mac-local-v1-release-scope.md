# ADR 0022 — Mac Local V1 release scope

Status: Accepted — 2026-07-19

## Decision

The first installable release is a macOS-only, local-first application. It composes the Mac UI, LaunchAgent helper, hook executable, Unix socket, XPC and SQLite authority. It requires neither an account nor a network connection.

The `AgentControlMacLocal` scheme and `MacLocalRelease` configuration exclude Sparkle and all iOS, watchOS, APNs and relay application targets. Their code and the existing full-product schemes remain preserved for V2. Managed Codex app-server startup is disabled in V1 unless a later evidence-backed release decision enables it; structured provider hooks are the release-blocking integration. The application shell is notch-first: no full dashboard window is created at launch, and the user opens the compact four-area Control Center explicitly.

Provider integrations consume only documented structured contracts. Codex, Claude Code and Gemini CLI hooks, plus Cursor's documented session, scoped mutable-tool, shell/MCP decision and compaction events, share the helper-owned normalized pipeline. A missing structured capability is reported as unsupported instead of being inferred from terminal text, accessibility, webviews or screen scraping. Usage kinds keep provider quota, context-window remaining and token counters semantically separate.

Local ad-hoc builds retain XPC authorization: the helper accepts only the current UID and the expected signed application identifier. Development signing uses the matching team identity. No mode permits arbitrary clients.

## Consequences

- Mac Local packaging can run without watch/iOS SDK gates, credentials, notarization or network services.
- Local decision delivery remains fail-neutral and revision checked; a local answer is shown as awaiting provider acknowledgment until a correlated structured provider event proves the result.
- Notification routes contain only non-sensitive request/session identifiers and open the relevant review surface without approving on a default click.
- Developer ID, notarization, Sparkle, companion pairing and remote decisions are not V1 release blockers.
- Ad-hoc signing can build and validate the bundle, but macOS may require user-controlled Open and helper approval; development signing is preferred for full `SMAppService` lifecycle evidence.
