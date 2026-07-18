#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

test -f Docs/PHASE_1_TEST_PLAN.md
test -f Docs/ADR/0009-domain-and-wire-contract.md
grep -q 'public enum SessionState' Packages/AgentControlKit/Sources/AgentDomain/StateMachine/SessionStateMachine.swift
grep -q 'public enum ApprovalStatus' Packages/AgentControlKit/Sources/AgentDomain/StateMachine/ApprovalStateMachine.swift
grep -q 'public struct EventEnvelope' Packages/AgentControlKit/Sources/AgentProtocol/EventEnvelope.swift
grep -q 'Critical risk is never remotely approvable' Packages/AgentControlKit/Tests/AgentDomainTests/RiskClassifierTests.swift
echo 'phase 1 contract: ok'
