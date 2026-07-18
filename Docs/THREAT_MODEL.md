# Threat Model

## Trust boundaries

- Provider process to hook or adapter.
- Hook to user-level helper.
- Helper to UI over authenticated XPC.
- Trusted endpoint to untrusted relay using end-to-end encrypted envelopes.
- Managed integration patch to user-owned configuration.

## Primary threats

Replay, forged or stale decisions, malicious local socket peers, oversized input, symlink configuration attacks, secret leakage, relay compromise, downgrade to unsupported provider behavior, and incorrect success state.

Phase 15 additionally reviews parent-path and time-of-check/time-of-use symlink
swaps, JSON/TOML managed-entry injection, malformed protocol corpora, decomposed
or oversized companion payloads, retired/stolen device keys, refresh-token reuse,
relay/APNs/Redis partitions, database/WAL corruption, privacy-manifest drift,
unbounded resource growth, inaccessible security controls and compromised
transitive dependencies.

## Required controls

Versioned envelopes, nonces and expiry; peer validation; bounded parsing; atomic managed-entry patching with backup and rollback; deterministic risk; redaction; least privilege; monitor-only fallback; and provider acknowledgment before applied state.

Managed configuration rejects user-controlled symlinks in every existing path
component (while allowing macOS root-owned compatibility links), requires an
owned regular target and revalidates before replacement.
Companion decoding is bounded before cryptographic/JSON work. Key rotation
replaces the trusted public keys and revokes prior refresh tokens; device revoke
invalidates authentication immediately. PostgreSQL pending fetch and local Mac
authority remain canonical during advisory-delivery outages. Recovery operates
on preserved copies with integrity checks. Release is blocked by any open
Critical/High finding or unreviewed dependency/manifest drift.
