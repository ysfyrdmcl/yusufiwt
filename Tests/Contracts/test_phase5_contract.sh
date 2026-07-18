#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexRPC.swift \
  Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexProcessManager.swift \
  Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexManagedSessionController.swift \
  Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexApprovalCoordinator.swift \
  Packages/AgentControlKit/Tests/AgentCodexAdapterTests/Fixtures/managed-session.jsonl \
  Docs/PHASE_5_TEST_PLAN.md \
  Docs/ADR/0010-codex-app-server-contract.md
do
  test -f "$path" || { echo "missing Phase 5 file: $path" >&2; exit 1; }
done

grep -q 'name: "AgentCodexAdapter"' Package.swift
grep -q 'name: "AgentCodexAdapterTests"' Package.swift
grep -q 'serverRequest/resolved' Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexManagedSessionController.swift
grep -q 'providerAcknowledged' Packages/AgentControlKit/Sources/AgentCodexAdapter/CodexApprovalCoordinator.swift

if grep -R -E 'ws://|wss://|websocket|WebSocket' Packages/AgentControlKit/Sources/AgentCodexAdapter; then
  echo 'experimental WebSocket transport leaked into production adapter' >&2
  exit 1
fi

echo 'phase 5 contract: ok'
