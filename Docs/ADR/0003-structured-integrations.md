# ADR 0003: Structured integrations first

- Status: Accepted
- Date: 2026-07-17

## Decision

Adapters prefer managed structured protocols, official hooks, and official APIs in that order. Process discovery is monitor-only. Terminal text scraping is prohibited.

## Consequences

Unknown provider versions degrade to monitor-only. Unsupported capabilities are hidden or use an explicit navigation fallback; they never produce synthetic success.

