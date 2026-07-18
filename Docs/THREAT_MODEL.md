# Threat Model

## Trust boundaries

- Provider process to hook or adapter.
- Hook to user-level helper.
- Helper to UI over authenticated XPC.
- Trusted endpoint to untrusted relay using end-to-end encrypted envelopes.
- Managed integration patch to user-owned configuration.

## Primary threats

Replay, forged or stale decisions, malicious local socket peers, oversized input, symlink configuration attacks, secret leakage, relay compromise, downgrade to unsupported provider behavior, and incorrect success state.

## Required controls

Versioned envelopes, nonces and expiry; peer validation; bounded parsing; atomic managed-entry patching with backup and rollback; deterministic risk; redaction; least privilege; monitor-only fallback; and provider acknowledgment before applied state.

