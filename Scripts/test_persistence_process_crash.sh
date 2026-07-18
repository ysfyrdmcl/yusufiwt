#!/bin/sh
set -eu

work_dir=$(mktemp -d /private/tmp/agentcontrol-persistence-crash.XXXXXX)
database="$work_dir/agent-control.sqlite"
trap 'rm -rf "$work_dir"' EXIT INT TERM

sqlite3 "$database" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE session_events(event_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
CREATE TABLE session_snapshots(session_id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, checksum TEXT NOT NULL);
SQL

# Kill the sqlite process after both writes but before COMMIT. Reopening must
# recover the WAL transaction as an all-or-nothing rollback.
(
    sqlite3 "$database" <<'SQL'
BEGIN IMMEDIATE;
INSERT INTO session_events VALUES('crashed-event', 1);
INSERT INTO session_snapshots VALUES('session-1', 1);
.shell kill -9 $PPID
COMMIT;
SQL
) >/dev/null 2>&1 || true

crashed_counts=$(sqlite3 "$database" 'SELECT (SELECT count(*) FROM session_events) || ":" || (SELECT count(*) FROM session_snapshots);')
test "$crashed_counts" = '0:0' || {
    echo "partial transaction survived process crash: $crashed_counts" >&2
    exit 1
}

sqlite3 "$database" <<'SQL'
BEGIN IMMEDIATE;
INSERT INTO session_events VALUES('committed-event', 1);
INSERT INTO session_snapshots VALUES('session-1', 1);
COMMIT;
INSERT OR IGNORE INTO session_events VALUES('committed-event', 99);
INSERT INTO schema_migrations VALUES(1, 'sha256:fixture');
INSERT OR IGNORE INTO schema_migrations VALUES(1, 'sha256:fixture');
SQL

committed_counts=$(sqlite3 "$database" 'SELECT (SELECT count(*) FROM session_events) || ":" || (SELECT count(*) FROM session_snapshots) || ":" || (SELECT count(*) FROM schema_migrations);')
test "$committed_counts" = '1:1:1' || {
    echo "committed transaction or duplicate no-op was lost: $committed_counts" >&2
    exit 1
}

integrity=$(sqlite3 "$database" 'PRAGMA integrity_check;')
test "$integrity" = 'ok'
echo 'persistence process-crash smoke: ok'
