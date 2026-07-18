# ADR 0009: Deterministic domain and versioned wire contract

- Status: Accepted
- Date: 2026-07-17

## Decision

AgentDomain contains platform-independent value models, pure transition guards,
and deterministic risk classification. Provider payloads cross the boundary as
a versioned `EventEnvelope` with bounded `JSONValue` payloads. Unknown event
types are preserved as diagnostics-safe unknown values and never mutate session
state. Ordering uses provider sequence when available; duplicate event IDs and
non-increasing source sequences are idempotent no-ops.

Approval applied states are reachable only after `providerAcknowledged`.
Terminal sessions require an explicit provider resume event before returning to
active states. Parent and child sessions have independent aggregates.

## Consequences

UI and adapters cannot bypass lifecycle rules. Wire evolution may add fields and
event types without crashing older clients. Raw provider payloads do not enter
domain models. Persistence and IPC will consume these contracts in later phases.

