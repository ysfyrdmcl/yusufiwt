#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Docs/RECOVERY_RUNBOOK.md \
  Docs/DEPENDENCY_AUDIT.md \
  Scripts/verify_phase15.sh \
  Scripts/test_database_recovery.sh \
  Scripts/generate_sbom.rb \
  Config/Privacy/PrivacyInfo.xcprivacy \
  Config/SBOM/agentcontrol.cdx.json \
  Packages/AgentControlKit/Tests/AgentLocalIPCTests/Phase15ProtocolFuzzTests.swift \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Phase15ConfigHardeningTests.swift \
  Packages/AgentControlKit/Tests/AgentCompanionTests/Phase15CryptoHardeningTests.swift
do
  test -f "$path" || { echo "missing Phase 15 file: $path" >&2; exit 1; }
done

grep -q 'unsafeSymbolicLink' Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift
grep -q 'invalidManagedEntry' Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift
grep -q 'maximumCiphertextBytes' Packages/AgentControlKit/Sources/AgentCompanion/CompanionCrypto.swift
grep -q 'rotatesKeys' Services/AgentControlRelay/Sources/AgentControlRelay/AuthController.swift
grep -q '100_000' Packages/AgentControlKit/Tests/AgentPersistenceTests/PerformanceFixtureTests.swift
grep -q 'summary.totalSessions == 100' Packages/AgentControlKit/Tests/AgentPersistenceTests/PerformanceFixtureTests.swift
grep -q 'PrivacyInfo.xcprivacy' project.yml

Scripts/verify_phase15.sh
echo 'phase 15 contract: ok'
