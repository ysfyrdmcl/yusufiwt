#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Packages/AgentControlKit/Sources/AgentMacUI/DecisionExperience.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/DecisionViews.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/NotificationPolicy.swift \
  Packages/AgentControlKit/Sources/AgentMacUI/MacNotificationCoordinator.swift \
  Docs/PHASE_8_TEST_PLAN.md \
  Docs/ADR/0013-approval-notification-boundary.md
do
  test -f "$path" || { echo "missing Phase 8 file: $path" >&2; exit 1; }
done

grep -q 'DecisionAvailability.evaluate' Packages/AgentControlKit/Sources/AgentMacUI/AgentControlStore.swift
grep -q 'sentToProvider' Packages/AgentControlKit/Sources/AgentMacUI/DecisionExperience.swift
grep -q 'isApplied: Bool { false }' Packages/AgentControlKit/Sources/AgentMacUI/DecisionExperience.swift
grep -q 'secretRequiresTerminal' Packages/AgentControlKit/Sources/AgentMacUI/DecisionViews.swift
grep -q 'threadIdentifier = decision.sessionID' Packages/AgentControlKit/Sources/AgentMacUI/MacNotificationCoordinator.swift
grep -q 'authenticationRequired' Packages/AgentControlKit/Sources/AgentMacUI/MacNotificationCoordinator.swift
grep -q 'MacNotificationCategory.secretQuestion' Packages/AgentControlKit/Sources/AgentMacUI/MacNotificationCoordinator.swift
grep -q 'quietHours' Packages/AgentControlKit/Sources/AgentMacUI/NotificationPolicy.swift
grep -q 'focusAware' Packages/AgentControlKit/Sources/AgentMacUI/MacNotificationCoordinator.swift
jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 8 contract: ok'
