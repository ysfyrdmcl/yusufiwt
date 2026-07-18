#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentMacUI/AgentControlTransport.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/AgentControlStore.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/DesignSystem.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift \
  Packages/AgentControlKit/Tests/AgentMacUITests/AgentMacUITests.swift \
  Apps/macOS/Resources/Localizable.xcstrings \
  Docs/PHASE_7_TEST_PLAN.md \
  Docs/ADR/0012-macos-ui-shell.md
do
  test -f "$path" || { echo "missing Phase 7 file: $path" >&2; exit 1; }
done

grep -q 'MenuBarExtra' Apps/macOS/AgentControlMacApp.swift
grep -q 'NSPanel' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'addGlobalMonitorForEvents' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'controlOptionSpace' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'keyCode: 49' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'GlobalHotKeyPreferences' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'List(store.activeSessions' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'accessibilityDisplayShouldReduceMotion' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'notifications() async -> AsyncStream' Packages/AgentControlKit/Sources/AgentMacUI/AgentControlTransport.swift
grep -q 'NavigationSplitView' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'keyboardShortcut(.space, modifiers: \[.control, .option\])' Apps/macOS/AgentControlMacApp.swift
grep -q 'accessibilityLabel' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'Control-Option-Space' Docs/PHASE_7_TEST_PLAN.md
jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 7 contract: ok'
