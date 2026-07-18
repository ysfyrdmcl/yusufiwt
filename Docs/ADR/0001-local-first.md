# ADR 0001: Local-first operation

- Status: Accepted
- Date: 2026-07-17

## Decision

Monitoring and local approval operate without an account, relay, or network. Companion access is optional and cannot become a dependency of the local event path.

## Consequences

The Mac helper remains the local authority. Relay outages may delay companion delivery but cannot stop local agent workflows. Agent execution is limited to this local Mac as specified by ADR 0017.
