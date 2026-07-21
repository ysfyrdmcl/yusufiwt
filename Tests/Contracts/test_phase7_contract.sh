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
  Packages/AgentControlKit/Sources/AgentMacUI/GlobalHotKey.swift \
  Packages/AgentControlKit/Tests/AgentMacUITests/AgentMacUITests.swift \
  Apps/macOS/Resources/Localizable.xcstrings \
  Docs/ADR/0012-macos-ui-shell.md
do
  test -f "$path" || { echo "missing Phase 7 file: $path" >&2; exit 1; }
done

grep -q 'MenuBarExtra' Apps/macOS/AgentControlMacApp.swift
if grep -Eq '^[[:space:]]*(Window|WindowGroup)\(' Apps/macOS/AgentControlMacApp.swift; then
  echo 'Mac Local must remain notch-first without an automatic main window scene' >&2
  exit 1
fi
grep -q 'Settings {' Apps/macOS/AgentControlMacApp.swift
grep -q 'ControlCenterWindowController' Apps/macOS/AgentControlMacApp.swift
grep -q 'NSPanel' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'addGlobalMonitorForEvents' Packages/AgentControlKit/Sources/AgentMacUI/GlobalHotKey.swift
grep -q 'controlOptionSpace' Packages/AgentControlKit/Sources/AgentMacUI/GlobalHotKey.swift
grep -q 'keyCode: 49' Packages/AgentControlKit/Sources/AgentMacUI/GlobalHotKey.swift
grep -q 'GlobalHotKeyPreferences' Packages/AgentControlKit/Sources/AgentMacUI/GlobalHotKey.swift
grep -q 'List(store.activeSessions' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'accessibilityDisplayShouldReduceMotion' Packages/AgentControlKit/Sources/AgentMacUI/FloatingPanel.swift
grep -q 'notifications() async -> AsyncStream' Packages/AgentControlKit/Sources/AgentMacUI/AgentControlTransport.swift
grep -q 'NavigationSplitView' Packages/AgentControlKit/Sources/AgentMacUI/ControlCenterViews.swift
grep -q 'keyboardShortcut(.space, modifiers: \[.control, .option\])' Apps/macOS/AgentControlMacApp.swift
grep -q 'accessibilityLabel' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'Control-Option-Space' PROJECT_AGENT_GUIDE.md
jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 7 contract: ok'
