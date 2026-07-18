#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift \
  Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift \
  Packages/AgentControlKit/Sources/AgentHookKit/ProviderHookMapper.swift \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Phase6AdapterTests.swift \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Fixtures/codex-permission.json \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Fixtures/claude-question.json \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Fixtures/gemini-before-tool.json \
  Docs/PHASE_6_TEST_PLAN.md \
  Docs/ADR/0011-provider-hook-integration.md
do
  test -f "$path" || { echo "missing Phase 6 file: $path" >&2; exit 1; }
done

grep -q 'case "provider-hook"' Tools/AgentControlHook/AgentControlHookMain.swift
grep -q 'case codex' Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift
grep -q 'case claude' Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift
grep -q 'case gemini' Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift
grep -q 'case generic' Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift
grep -q 'unsafeSymbolicLink' Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift
grep -q 'concurrentModification' Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift
grep -q 'return CapabilityMatrix(supported: \[.monitorSessions\])' Packages/AgentControlKit/Sources/AgentHookKit/ProviderIntegrations.swift

echo 'phase 6 contract: ok'
