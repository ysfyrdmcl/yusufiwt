#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Apps/iOS/CompanionSurfaceCoordinator.swift \
  Apps/Extensions/AgentLiveActivity/AgentLiveActivityWidget.swift \
  Apps/Extensions/AgentWidgets/ActiveAgentsWidget.swift \
  Apps/watchOS/AgentControlWatchApp.swift \
  Packages/AgentControlKit/Sources/AgentCompanion/Phase14Surfaces.swift \
  Packages/AgentControlKit/Tests/AgentCompanionTests/Phase14CompanionTests.swift \
  Config/Entitlements/AgentWidgets.entitlements \
  Docs/ADR/0019-phase14-glanceable-surfaces.md
do
  test -f "$path" || { echo "missing Phase 14 file: $path" >&2; exit 1; }
done

grep -q 'ActivityConfiguration(for: AgentActivityAttributes.self)' Apps/Extensions/AgentLiveActivity/AgentLiveActivityWidget.swift
grep -q 'DynamicIsland' Apps/Extensions/AgentLiveActivity/AgentLiveActivityWidget.swift
grep -q 'PendingApprovalsWidget' Apps/Extensions/AgentWidgets/ActiveAgentsWidget.swift
grep -q 'WatchConnectivity' Apps/iOS/CompanionSurfaceCoordinator.swift
grep -q 'risk == .low' Packages/AgentControlKit/Sources/AgentCompanion/Phase14Surfaces.swift
grep -q 'item.risk != .low' Packages/AgentControlKit/Sources/AgentCompanion/CompanionExperience.swift
grep -q 'maximumPayloadBytes = 4096' Packages/AgentControlKit/Sources/AgentCompanion/Phase14Surfaces.swift
grep -q 'APNS_LIVE_ACTIVITY_TOPIC' Services/AgentControlRelay/Sources/AgentControlRelay/configure.swift
grep -q 'apns-push-type", value: "liveactivity"' Services/AgentControlRelay/Sources/AgentControlRelay/DeliveryServices.swift
grep -q 'target: AgentControlWatch' project.yml
grep -q 'target: AgentLiveActivity' project.yml
grep -q 'target: AgentWidgets' project.yml
grep -q 'com.apple.security.application-groups' Config/Entitlements/AgentWidgets.entitlements
grep -q 'NSSupportsLiveActivities' Apps/iOS/Info.plist

if grep -Eiq 'approve|deny' Apps/Extensions/AgentLiveActivity/AgentLiveActivityWidget.swift; then
  echo 'Live Activity must not expose direct approval controls' >&2
  exit 1
fi

jq -e '.strings | to_entries | all(.value.localizations.en.stringUnit.value and .value.localizations.tr.stringUnit.value)' \
  Apps/watchOS/Resources/Localizable.xcstrings >/dev/null

echo 'phase 14 contract: ok'
