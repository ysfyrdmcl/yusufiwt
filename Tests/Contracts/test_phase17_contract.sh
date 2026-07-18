#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

ruby -c Scripts/verify_phase17.rb >/dev/null
ruby Scripts/verify_phase17.rb --structural
if ruby Scripts/verify_phase17.rb --release-evidence Config/Operations/release-evidence.example.json >/dev/null 2>&1; then
  echo 'pending release evidence unexpectedly passed' >&2
  exit 1
fi

grep -q 'ReleaseFeatureConfiguration.internalAlpha' Packages/AgentControlKit/Tests/BuildSupportTests/Phase17FeatureFlagTests.swift
grep -q 'DiagnosticFeedbackPackageBuilder' Packages/AgentControlKit/Sources/AgentPersistence/DiagnosticExport.swift
grep -q 'EMERGENCY_DISABLE_ENVELOPE_SUBMISSION' Services/AgentControlRelay/Sources/AgentControlRelay/OperationsServices.swift
grep -q 'internal", "metrics' Services/AgentControlRelay/Sources/AgentControlRelay/OperationsServices.swift
grep -q 'routes.delete("account"' Services/AgentControlRelay/Sources/AgentControlRelay/DevicePairingController.swift
grep -q 'make release-verify' .github/workflows/release.yml

if jq -r '.panels[].query' Config/Operations/operations-dashboard.json | grep -E '(device_id|user_id|token)=' >/dev/null; then
  echo 'operations dashboard contains a high-cardinality or secret label' >&2
  exit 1
fi

echo 'phase 17 launch operations contract: ok'
