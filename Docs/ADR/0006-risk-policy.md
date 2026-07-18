# ADR 0006: Deterministic risk policy

- Status: Accepted
- Date: 2026-07-17

## Decision

Parsed action data and versioned deterministic rules calculate risk. Provider labels and natural-language descriptions may raise risk but never lower it.

## Consequences

Critical remote approval is rejected. Automated approval requires an explicit user rule and remains bounded by policy.

