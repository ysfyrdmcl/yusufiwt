# ADR 0005: Zero-knowledge end-to-end relay

- Status: Accepted
- Date: 2026-07-17

## Decision

The relay transports ciphertext, routing metadata, expiry, and delivery state only. Device identities and content keys remain at trusted endpoints.

## Consequences

A relay compromise cannot expose prompt, command, path, or decision content. The relay cannot execute an agent action or declare it applied.

