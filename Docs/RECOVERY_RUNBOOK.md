# Database recovery runbook

## Trigger and containment

Use this runbook when startup reports an unreadable/corrupt database, an
integrity check fails, or a migration backup must be restored. Stop the helper
before touching files. Preserve the database plus `-wal` and `-shm` sidecars;
never run repair commands against the only copy.

## Recovery

1. Copy the database and sidecars to a timestamped, user-private directory.
2. Run `PRAGMA integrity_check` against the copy. Do not reopen a suspect file
   read-write.
3. Prefer the latest pre-migration/application backup whose integrity check is
   `ok`. Restore it to a new path, verify it, then atomically select that file.
4. If no healthy backup exists, use `DatabaseActor.inspectForRecovery` and
   `exportRecoverableDatabase` to produce a read-only salvage copy. Keep the
   original for diagnosis and tell the user what may be missing.
5. Start the helper, verify schema migrations, session/event counts and a new
   append/checkpoint. Roll back to the preserved files if any check fails.

## Drills and evidence

- `Scripts/test_persistence_process_crash.sh` proves uncommitted event/snapshot
  writes roll back and committed/idempotent writes survive.
- `Scripts/test_database_recovery.sh` creates a backup, corrupts only a
  disposable database, verifies detection, restores, checks integrity and data.

Production drills must record date, build/commit, operator, source/backup hashes,
integrity output, row-count comparison, recovery time and any lost-event window.
