#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentDomain/Models/Navigation.swift \
  Packages/AgentControlKit/Sources/AgentHookKit/TerminalContextCapture.swift \
  Packages/AgentControlKit/Sources/AgentHookKit/IntegrationManagement.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/TerminalNavigation.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/Phase10Experience.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/Phase10Views.swift \
  Packages/AgentControlKit/Tests/AgentHookKitTests/Phase10IntegrationTests.swift \
  Packages/AgentControlKit/Tests/AgentMacUITests/Phase10NavigationTests.swift \
  Extensions/agentcontrol-navigation/package.json \
  Extensions/agentcontrol-navigation/src/extension.ts \
  Apps/macOS/Resources/Localizable.xcstrings \
  Apps/macOS/Info.plist \
  Docs/PHASE_10_TEST_PLAN.md \
  Docs/ADR/0016-phase10-navigation-and-onboarding.md
do
  test -f "$path" || { echo "missing Phase 10 file: $path" >&2; exit 1; }
done

grep -q 'TerminalContextCapture().capture' Packages/AgentControlKit/Sources/AgentHookKit/ProviderHookMapper.swift
grep -q 'case exactPane' Packages/AgentControlKit/Sources/AgentDomain/Models/Navigation.swift
grep -q 'AEDeterminePermissionToAutomateTarget' Packages/AgentControlKit/Sources/AgentMacUI/TerminalNavigation.swift
grep -q 'askUserIfNeeded: false' Packages/AgentControlKit/Sources/AgentMacUI/TerminalNavigation.swift
grep -q 'AXIsProcessTrusted()' Packages/AgentControlKit/Sources/AgentMacUI/TerminalNavigation.swift
grep -q 'installAtomically' Packages/AgentControlKit/Sources/AgentHookKit/ManagedConfigPatchEngine.swift
grep -q 'managedBlockIDs' Packages/AgentControlKit/Sources/AgentHookKit/IntegrationManagement.swift
grep -q 'afterHash' Packages/AgentControlKit/Sources/AgentHookKit/IntegrationManagement.swift
grep -q 'agentcontrol-hook' project.yml
grep -q 'registerUriHandler' Extensions/agentcontrol-navigation/src/extension.ts
grep -q 'terminal.show(false)' Extensions/agentcontrol-navigation/src/extension.ts
grep -q 'reportResult(token, "exactPane")' Extensions/agentcontrol-navigation/src/extension.ts
grep -q 'handleNavigationCallback' Apps/macOS/AgentControlMacApp.swift
plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw Apps/macOS/Info.plist | grep -qx agentcontrol

if rg -n '(/bin/(sh|zsh|bash)|shell -c)' Packages/AgentControlKit/Sources/AgentMacUI/TerminalNavigation.swift; then
  echo 'navigation must not invoke a shell' >&2
  exit 1
fi

jq -e '
  . as $catalog
  | [
      "sidebar.integrations",
      "integrations.title",
      "integration.state.healthy",
      "navigation.result.exactPane",
      "navigation.result.unsupported",
      "onboarding.title",
      "onboarding.navigation.accessibility",
      "onboarding.verify.success"
    ]
  | all(.[];
      . as $key
      | ($catalog.strings[$key].localizations.en.stringUnit.value? // "") != ""
      and ($catalog.strings[$key].localizations.tr.stringUnit.value? // "") != ""
    )
' Apps/macOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 10 contract: ok'
