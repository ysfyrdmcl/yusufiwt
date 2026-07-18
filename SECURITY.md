# Security Policy

Report vulnerabilities privately to the repository owner. Do not open a public issue containing secrets, exploit steps, private keys, user prompts, commands, or file paths.

## Baseline guarantees

- The Mac helper is the final authority for agent decisions.
- Approval is not shown as applied before correlated provider acknowledgment.
- Unsupported capabilities never return synthetic success.
- Secrets belong in Keychain, CI secret storage, or a server secret manager.
- User configuration is patched through owned entries with backup, atomic write, and rollback; whole-file replacement is prohibited.

Phase 0 contains no network service or credential handling implementation.

