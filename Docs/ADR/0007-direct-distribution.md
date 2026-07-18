# ADR 0007: Direct macOS distribution

- Status: Accepted
- Date: 2026-07-17

## Decision

The macOS app uses Developer ID signing, notarization, and Sparkle updates. iOS and watchOS use Apple distribution channels.

## Consequences

Deep helper and CLI integration remain possible. Private signing and update keys stay in CI secret storage and never enter the repository.

