#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

grep -q 'SMAppService' Packages/AgentControlKit/Sources/AgentLocalIPC/LaunchAgentManager.swift
grep -q 'manager.register()' Apps/macOS/AgentControlMacApp.swift
grep -q 'unauthorizedClient' Packages/AgentControlKit/Sources/AgentLocalIPC/IPCModels.swift
grep -q 'mode 0o600\|0o600' Packages/AgentControlKit/Sources/AgentLocalIPC/UnixSocketServer.swift Packages/AgentControlKit/Tests/AgentLocalIPCTests/UnixSocketIntegrationTests.swift
grep -q 'cleans owned transient files' Packages/AgentControlKit/Tests/AgentLocalIPCTests/LaunchAgentAndXPCContractTests.swift
echo 'phase 3 contract: ok'
