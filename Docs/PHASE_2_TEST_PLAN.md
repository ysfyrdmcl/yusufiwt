# Phase 2 Test Plan

Phase 2 establishes the local SQLite event store, materialized session reads,
migration safety, privacy boundary, retention, backup, and recovery diagnostics.

## Automated coverage

- Event append and session snapshot update commit in one transaction.
- Duplicate event IDs do not reapply newer snapshots.
- A sequence conflict rolls back the entire event batch.
- Committed WAL data survives checkpoint, close, and reopen.
- Migrations are idempotent, contiguous, and checksum protected.
- Pending migrations create a checkpointed pre-migration backup.
- All planned tables, foreign keys, indexes, and append-only audit triggers exist.
- WAL, foreign keys, full synchronous writes, and busy timeout are configured.
- Sensitive fields round-trip through AES-GCM and are absent from raw DB bytes.
- Secret fields and sensitive writes without encryption fail closed.
- Retention deletion respects its batch bound and may run at utility priority.
- Backup, immutable read-only inspection, export, and corrupt-file diagnosis work.

## Performance fixture

Run `make persistence-performance` to append and count 100,000 events in 1,000
event transactions. It is opt-in so the normal unit suite remains fast. Record
wall time and database size on release hardware before Phase 15 performance
hardening.

## Acceptance

`make test` must pass. `DatabaseActor` is the sole public SQLite owner, which is
enforced by Swift actor isolation and strict concurrency compilation. Recovery
callers receive a typed report suitable for the later recovery UI; Phase 2 does
not add application UI.
