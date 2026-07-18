# ADR 0002: Separate helper and local IPC

- Status: Accepted
- Date: 2026-07-17

## Decision

A user-level LaunchAgent helper owns sessions, pending decisions, persistence, rules, and adapters. UI clients communicate through authenticated XPC; hooks use a bounded Unix-domain socket protocol.

The helper is embedded in the macOS app and registered with `SMAppService`.
Its XPC listener accepts only the current UID, the macOS app bundle identifier,
and the helper's signing team (ad-hoc signatures are debug-only). XPC payloads
use an `NSSecureCoding` data wrapper around versioned Codable requests.

The hook socket lives in the private Application Support/app-group directory,
has mode `0600`, validates peer UID with `getpeereid`, and uses an `ACIP` frame:
magic, protocol version, message type, payload length, SHA-256 checksum, then
payload. Frames are limited to 1 MiB. A private spool provides helper-unavailable
fallback without ever implying approval.

## Consequences

Closing the UI does not interrupt an agent. Root privileges, screen recording, and a UI-owned agent process are excluded.

`SessionRegistryActor` restores non-terminal snapshots from SQLite after helper
restart. Shutdown/update handoff checkpoints SQLite, drains the spool, and
persists a typed handoff marker. Socket removal always validates ownership and
file type first.
