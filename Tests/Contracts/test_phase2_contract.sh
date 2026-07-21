#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

test -x Scripts/test_persistence_process_crash.sh
grep -q 'public actor DatabaseActor' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor.swift
grep -q 'connection.transaction' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor.swift
grep -q 'migrationChecksumMismatch' Packages/AgentControlKit/Tests/AgentPersistenceTests/DatabaseActorTests.swift
grep -q 'inspectForRecovery' Packages/AgentControlKit/Tests/AgentPersistenceTests/DatabaseActorTests.swift
grep -q 'scheduleRetentionCleanup' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor.swift
grep -q 'Task.detached(priority: .utility)' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor.swift
grep -q 'DatabaseActor.open' Packages/AgentControlKit/Sources/AgentLocalIPC/HelperHost.swift
grep -q 'kill -9' Scripts/test_persistence_process_crash.sh
echo 'phase 2 contract: ok'
