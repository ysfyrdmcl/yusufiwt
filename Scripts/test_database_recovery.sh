#!/bin/sh
set -eu

work_dir=$(mktemp -d /private/tmp/agentcontrol-recovery.XXXXXX)
database="$work_dir/agent-control.sqlite"
backup="$work_dir/agent-control.backup.sqlite"
restored="$work_dir/agent-control.restored.sqlite"
trap 'rm -rf "$work_dir"' EXIT INT TERM

sqlite3 "$database" >/dev/null <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE recovery_fixture(id INTEGER PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO recovery_fixture(value) VALUES('release-candidate');
PRAGMA wal_checkpoint(FULL);
SQL

sqlite3 "$database" ".backup '$backup'"
test "$(sqlite3 "$backup" 'PRAGMA integrity_check;')" = "ok"

# Damage only the disposable drill database, then prove it is detected.
dd if=/dev/zero of="$database" bs=512 count=1 conv=notrunc >/dev/null 2>&1
corrupt_result=$(sqlite3 "$database" 'PRAGMA integrity_check;' 2>&1 || true)
test "$corrupt_result" != "ok" || {
  echo 'corruption drill was not detected' >&2
  exit 1
}

cp "$backup" "$restored"
test "$(sqlite3 "$restored" 'PRAGMA integrity_check;')" = "ok"
test "$(sqlite3 "$restored" 'SELECT value FROM recovery_fixture;')" = "release-candidate"
echo 'database backup/corruption/restore drill: ok'
