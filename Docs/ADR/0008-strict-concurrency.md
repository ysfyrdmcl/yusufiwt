# ADR 0008: Swift strict concurrency and dependency direction

- Status: Accepted
- Date: 2026-07-17

## Decision

Swift 6 complete concurrency checking is mandatory. Mutable shared state is actor-owned. Dependencies point toward the platform-independent AgentDomain module.

## Consequences

Global mutable singletons, unjustified unsafe Sendable declarations, and UI/network/database imports in AgentDomain are prohibited.

