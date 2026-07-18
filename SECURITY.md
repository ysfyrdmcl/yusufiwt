# Security Policy

Report vulnerabilities privately to the repository owner. Do not open a public issue containing secrets, exploit steps, private keys, user prompts, commands, or file paths.

## Baseline guarantees

- The Mac helper is the final authority for agent decisions.
- Approval is not shown as applied before correlated provider acknowledgment.
- Unsupported capabilities never return synthetic success.
- Secrets belong in Keychain, CI secret storage, or a server secret manager.
- User configuration is patched through owned entries with backup, atomic write, and rollback; whole-file replacement is prohibited.

## Companion relay

- Sign in with Apple identity tokens are verified against Apple JWKS with issuer, audience, expiry and optional nonce checks.
- Access tokens are short lived; refresh tokens are hashed, single-use, rotated and revoked with the device.
- An account has one active local-Mac execution authority. iPhone and Watch routes cannot send provider acknowledgments or start processes.
- X25519/HKDF, ChaChaPoly and Ed25519 protect companion content; expiry, nonce and monotonic sequence checks reject replay.
- Critical approvals are forbidden on companion devices; Watch approval is Low-only and High iPhone approval requires strong-authentication evidence.
- Relay persistence and logs must never contain plaintext prompt, command, path, code or decision content.
- PostgreSQL pending fetch is authoritative; Redis/WebSocket/APNs delivery is advisory and cannot mark a decision applied.
