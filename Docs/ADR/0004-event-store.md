# ADR 0004: Append-only event store with snapshots

- Status: Accepted
- Date: 2026-07-17

## Decision

Domain changes are appended to SQLite and materialized session snapshots are updated in the same transaction. Typed repositories and owned migrations are used without an ORM.

`DatabaseActor` is the only public write boundary. SQLite runs with WAL,
foreign keys, full synchronous commits, bounded busy waits, and explicit
checkpoints. Migration history is contiguous and checksum protected; an
existing database is checkpointed and backed up before a pending migration.

Event IDs provide idempotency and `(session_id, source_key, sequence)` protects
provider ordering. Secret payloads are rejected. Sensitive payloads require a
caller-supplied field cipher whose key is owned outside persistence (Keychain at
the application composition root). Audit rows are protected by database-level
update/delete triggers as well as the append-only API.

## Consequences

Audit history is retained while reads remain fast. Provider decisions remain pending until a correlated provider acknowledgment is persisted.

Recovery inspection opens suspect files with SQLite immutable/read-only mode.
It reports whether recovery UI is required and can export readable pages to a
new database. Retention deletes are bounded and schedulable at utility priority;
vacuum is intentionally not automatic.
