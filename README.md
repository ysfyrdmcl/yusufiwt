# AgentControl

Native Swift operations center for AI coding agents. The authoritative scope and phase order are defined in [`AgentControl_PROJECT_PLAN.md`](AgentControl_PROJECT_PLAN.md).

## Development

Requirements: Xcode 26.6, Swift 6.3, Homebrew, and `make`.

```sh
make bootstrap && make generate && make test
```

Phases 0–7 provide the repository foundation, deterministic domain/wire
contracts, SQLite persistence, the independent macOS LaunchAgent helper, and a
working local hook/decision spine. Phase 4 adds `agentcontrol-hook`, a dev-only
Fake Agent Simulator, and a Protocol Inspector. Phase 5 adds the managed Codex
app-server adapter with schema-aware fallback, managed thread/turn control,
authoritative approval acknowledgment, bounded reconnect, and redacted
diagnostics. Phase 6 adds lossless managed hook configuration and normalized
Codex, Claude Code, Gemini CLI, and generic monitoring adapters. Phase 7 adds
the native menu bar, multi-display floating panel, dashboard, inbox, session
detail, reconnect-safe UI store, keyboard operation, and English/Turkish UI.
Phases 8–17 add decision UX, operations/navigation, encrypted companion
surfaces, hardening, release pipelines, privacy-safe support, account deletion,
emergency controls, and the evidence-backed 1.0 release gate.

```sh
swift run agentcontrol-hook doctor
swift run agentcontrol-hook provider-hook codex < codex-hook-input.json
swift run fake-agent-simulator approval --auto-decision approve
swift run protocol-inspector pending
```

Run the opt-in 100k-event persistence fixture with:

```sh
make persistence-performance
```
