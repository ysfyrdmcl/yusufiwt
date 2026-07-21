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
categories. They group by session and deduplicate by decision kind, request ID,
and revision. Secret and high/critical requests are review-only. A default tap
also routes to review and never approves. Routes contain only stable IDs and
revision, so cold launch can select the current request without carrying prompt
or command text. Quiet hours and the sound preference produce silent delivery;
focus-aware delivery uses passive interruption and never requests a Focus
bypass. Preference changes replace scheduled requests under the same stable ID,
and provider acknowledgment/removal reconciles both pending and delivered OS
notifications.

An accepted local resolution is shown as awaiting provider acknowledgment.
Only a normalized provider acknowledgment may later produce `applied` or
`deniedApplied`; a provider denial after a local approve is `providerRejected`.

## Consequences

- Stale notification and dashboard actions are harmless.
- Secret answers stay in the provider terminal.
- Parallel queues remain deterministic and notification noise is bounded.
- The UI cannot manufacture a false applied state.
