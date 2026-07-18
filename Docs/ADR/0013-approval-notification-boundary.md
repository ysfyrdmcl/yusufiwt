# ADR 0013: Approval UX and notification acknowledgment boundary

- Status: Accepted
- Date: 2026-07-18

## Context

macOS must present actionable agent requests without leaking secret answers,
duplicating alerts, accepting stale actions, or claiming a decision was applied
before the provider acknowledges it.

## Decision

The helper remains authoritative for request revision and expiry. Pending XPC
items carry normalized approval, question, plan, project, terminal, privacy,
and risk context. The UI independently checks expiry before sending and keeps
only the newest revision for each request ID.

Local notifications use separate approval, question, secret-question, and plan
categories. They group by session and deduplicate by request ID plus revision.
Secret questions have no answer action. Quiet hours produce silent delivery;
focus-aware delivery uses passive interruption and never requests a Focus
bypass.

An accepted local resolution is shown as `sentToProvider`. Only a normalized
provider acknowledgment may later produce an applied state.

## Consequences

- Stale notification and dashboard actions are harmless.
- Secret answers stay in the provider terminal.
- Parallel queues remain deterministic and notification noise is bounded.
- The UI cannot manufacture a false applied state.
