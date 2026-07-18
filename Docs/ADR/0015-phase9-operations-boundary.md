# ADR 0015 — Phase 9 operations and automation boundary

## Status

Accepted for implementation; release verification remains gated by the earlier phase evidence listed in the project plan.

## Decision

The helper remains the authority for rules, analytics, diagnostics, retention,
and deletion. The macOS app accesses these operations only through typed local
IPC. SQLite performs filtered history and aggregate analytics queries so raw
event payloads do not move into the UI merely to calculate charts.

Alert evaluation is a pure deterministic function of normalized session state,
stored rules, and `AgentClock`. Automated approval is fail-closed: an explicit
enabled rule may approve only a normalized `low`-risk file read or read-only
tool. Commands, writes, network actions, custom actions, and every medium/high/
critical request always require a person regardless of stored rule content.

Diagnostic exports contain a bounded structured report. Sensitive and secret
attachments are omitted, credential-like values and user paths are redacted,
and private metadata is excluded unless the user explicitly opts in.

## Consequences

- Fake clocks make duration rules deterministic.
- Adding a broader automation action requires a new ADR and security fixtures.
- Analytics can be disabled without disabling history.
- Audit entries for automatic decisions remain append-only after history deletion.
