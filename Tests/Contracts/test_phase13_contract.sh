#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Apps/iOS/AgentControliOSApp.swift \
  Apps/iOS/CompanionAppModel.swift \
  Apps/iOS/CompanionViews.swift \
  Apps/iOS/Resources/Localizable.xcstrings \
  Apps/Extensions/NotificationService/NotificationService.swift \
  Packages/AgentControlKit/Sources/AgentCompanion/CompanionExperience.swift \
  Packages/AgentControlKit/Sources/AgentCompanion/CompanionRelayClient.swift \
  Packages/AgentControlKit/Tests/AgentCompanionTests/Phase13CompanionTests.swift \
  Config/Entitlements/AgentControliOS.entitlements \
  Config/Entitlements/NotificationService.entitlements \
  Docs/PHASE_13_TEST_PLAN.md \
  Docs/ADR/0018-ios-companion-authority-boundary.md
do
  test -f "$path" || { echo "missing Phase 13 file: $path" >&2; exit 1; }
done

grep -q 'SignInWithAppleButton' Apps/iOS/CompanionViews.swift
grep -q 'DataScannerViewController' Apps/iOS/CompanionViews.swift
grep -q 'BiometricAuthenticator.authenticate' Apps/iOS/CompanionAppModel.swift
grep -q 'minimumDuration: 1.5' Apps/iOS/CompanionViews.swift
grep -q 'awaitingProviderAcknowledgment' Packages/AgentControlKit/Sources/AgentCompanion/CompanionExperience.swift
grep -q 'criticalApprovalForbidden' Packages/AgentControlKit/Sources/AgentCompanion/CompanionExperience.swift
grep -q 'approvalRequiresApplication' Packages/AgentControlKit/Sources/AgentCompanion/CompanionExperience.swift
grep -q 'genericFallback' Apps/Extensions/NotificationService/NotificationService.swift
grep -q 'CompanionKeyStore(accessGroup:' Apps/Extensions/NotificationService/NotificationService.swift
grep -q 'AgentControlRelayBaseURL' project.yml
grep -q 'product: AgentCompanion' project.yml
grep -q 'target: NotificationService' project.yml
grep -q 'com.apple.developer.applesignin' Config/Entitlements/AgentControliOS.entitlements
grep -q 'aps-environment' Config/Entitlements/AgentControliOS.entitlements
grep -q 'keychain-access-groups' Config/Entitlements/NotificationService.entitlements
grep -q 'alert: .init' Services/AgentControlRelay/Sources/AgentControlRelay/DeliveryServices.swift

jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/iOS/Resources/Localizable.xcstrings >/dev/null

if sed -n '/identifier: CompanionNotificationCategory.highApproval/,/),/p' Apps/iOS/AgentControliOSApp.swift | grep -q 'approveAction'; then
  echo 'high-risk notification category must not expose approve' >&2
  exit 1
fi
if sed -n '/identifier: CompanionNotificationCategory.criticalApproval/,/),/p' Apps/iOS/AgentControliOSApp.swift | grep -q 'approveAction'; then
  echo 'critical notification category must not expose approve' >&2
  exit 1
fi

echo 'phase 13 contract: ok'
