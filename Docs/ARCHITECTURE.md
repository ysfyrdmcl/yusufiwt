# Architecture

Apps, services, and integrations depend on shared infrastructure modules, which depend on the platform-independent `AgentDomain`. The macOS helper is the local authority. This document will grow only as ordered phases add verified behavior.

`AgentPersistence` depends on `AgentDomain` and `AgentProtocol`. Its
`DatabaseActor` owns the SQLite connection and transaction boundaries, so app
and helper callers must cross an actor boundary for every disk operation. The
database stores append-only normalized envelopes and transactionally updated
session snapshots. Read models return small `Sendable` values rather than raw
SQLite handles or rows.

Phase 9 keeps operational policy in the helper. `OperationsRuleEngine` is a
platform-independent deterministic evaluator, while `DatabaseActor` owns rule
storage, indexed history/analytics queries, retention, diagnostics, and data
deletion. Typed XPC cases expose bounded read models to the macOS dashboard;
diagnostic payload redaction occurs before an export is written.

Phase 10 captures `TerminalContext` at the provider-hook boundary and keeps
navigation execution in the macOS UI process. `TerminalNavigationPlanner` is a
pure capability planner: VS Code/Cursor extension URIs, WezTerm CLI, official
Warp workspace URI, and permission-gated AppleScript precede opt-in
Accessibility, application activation, and project-folder fallback. Runtime
navigation never interpolates values into a shell command and never requests
Automation or Accessibility permission unless the user presses the matching
onboarding control.

`ManagedProviderIntegrationManager` owns discovery, managed diffs, receipts,
repair, backup restore, and scoped uninstall. Multi-provider onboarding
prepares every diff before writing and uses `IntegrationManagerActor` to roll
back earlier writes if a later file fails. Receipts store pre/post hashes and
managed block IDs; backup restore fails closed after an external edit, while
uninstall removes marked AgentControl entries from the current file so user
changes are preserved.

ADR 0017 limits execution to one local Mac. The local helper is the only agent
authority and the direct endpoint for the Phase 12 companion relay. iPhone and
Watch clients can submit bounded, signed decisions but are not execution nodes.
There is no remote-node service, SSH bootstrap, systemd package, or remote
terminal path. Existing `NodeID` naming is retained only for wire/database
compatibility and identifies the local Mac.

Phase 12 adds `AgentCompanion` and the separately deployable Vapor
`AgentControlRelay`. Endpoints derive X25519/HKDF keys and perform
ChaChaPoly/Ed25519 operations only on trusted endpoints. The relay verifies
device signatures over opaque envelopes, enforces sender/recipient ownership,
monotonic sequence and expiry, and stores only ciphertext plus routing state in
PostgreSQL. Redis holds short-lived presence/queue hints; PostgreSQL pending
fetch is authoritative after a WebSocket disconnect. The helper-owned
`HelperCompanionAuthority` is the sole bridge to a provider and emits success
only from a provider acknowledgment.

Phase 13 makes the iOS application a bounded companion client. Device keys and
relay credentials live in a device-only Keychain access group shared with the
Notification Service Extension. The extension may decrypt a short-lived
envelope for privacy-filtered rendering but cannot durably consume it or apply
a provider decision. The app owns pairing confirmation, cursor reconciliation,
the protected local snapshot and durable decision outbox. Low/Medium notification
actions are authentication-required; High requires in-app Face ID plus a hold;
Critical approval and secret answers are unavailable on companion devices.
`serverAccepted` is never success: only the Mac/provider acknowledgment produces
an applied state.
