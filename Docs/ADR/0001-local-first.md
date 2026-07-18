# ADR 0001: Local-first operation

- Status: Accepted
- Date: 2026-07-17

## Decision

Monitoring and local approval operate without an account, relay, or network. Remote mode is optional and cannot become a dependency of the local event path.

## Consequences

The Mac helper remains the local authority. Remote outages may delay remote delivery but cannot stop local agent workflows.

