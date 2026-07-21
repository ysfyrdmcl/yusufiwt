#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentDomain/Policies/OperationsRules.swift \
  Packages/AgentControlKit/Sources/AgentPersistence/OperationsTypes.swift \
  Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor+Operations.swift \
  Packages/AgentControlKit/Sources/AgentPersistence/DiagnosticExport.swift \
  Packages/AgentControlKit/Sources/AgentPersistence/EventPayloadPrivacyFilter.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/Phase9Views.swift \
  Packages/AgentControlKit/Tests/AgentDomainTests/OperationsRuleEngineTests.swift \
  Packages/AgentControlKit/Tests/AgentPersistenceTests/Phase9OperationsTests.swift \
  Packages/AgentControlKit/Tests/AgentLocalIPCTests/Phase9RuntimeTests.swift \
  Docs/ADR/0015-phase9-operations-boundary.md
do
  test -f "$path" || { echo "missing Phase 9 file: $path" >&2; exit 1; }
done

grep -q 'guard request.risk.level == .low' Packages/AgentControlKit/Sources/AgentDomain/Policies/OperationsRules.swift
grep -q 'narrowActionKind' Packages/AgentControlKit/Sources/AgentDomain/Policies/OperationsRules.swift
grep -q 'FixedAgentClock' Packages/AgentControlKit/Tests/AgentDomainTests/OperationsRuleEngineTests.swift
grep -q 'func history' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor+Operations.swift
grep -q 'func analytics' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor+Operations.swift
grep -q 'deleteCompletedHistory' Packages/AgentControlKit/Sources/AgentPersistence/DatabaseActor+Operations.swift
grep -q 'RedactedDiagnosticExporter' Packages/AgentControlKit/Sources/AgentPersistence/DiagnosticExport.swift
grep -q 'Chart(summary.buckets)' Packages/AgentControlKit/Sources/AgentMacUI/Phase9Views.swift
grep -q 'case activeAlerts' Packages/AgentControlKit/Sources/AgentLocalIPC/IPCModels.swift
jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 9 contract: ok'
