#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentHookKit/AgentControlHookClient.swift \
  Packages/AgentControlKit/Sources/AgentLocalIPC/HookDecisionBroker.swift \
  Tools/AgentControlHook/AgentControlHookMain.swift \
  Tools/FakeAgentSimulator/FakeAgentSimulatorMain.swift \
  Tools/ProtocolInspector/ProtocolInspectorMain.swift \
  Docs/PHASE_4_TEST_PLAN.md
do
  test -f "$path" || { echo "missing Phase 4 file: $path" >&2; exit 1; }
done

for target in AgentControlHook FakeAgentSimulator ProtocolInspector AgentHookKitTests
do
  grep -q "name: \"$target\"" Package.swift || { echo "missing SwiftPM target: $target" >&2; exit 1; }
done

grep -q 'case requestDecision' Packages/AgentControlKit/Sources/AgentLocalIPC/IPCModels.swift
grep -q 'case resolveDecision' Packages/AgentControlKit/Sources/AgentLocalIPC/IPCModels.swift
grep -q 'FileHandle.standardError' Tools/AgentControlHook/AgentControlHookMain.swift

echo 'phase 4 contract: ok'
