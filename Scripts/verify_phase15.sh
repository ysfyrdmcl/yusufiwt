#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

plutil -lint Config/Privacy/PrivacyInfo.xcprivacy >/dev/null
plutil -convert json -o - Config/Privacy/PrivacyInfo.xcprivacy | jq -e '
  .NSPrivacyTracking == false and
  (.NSPrivacyCollectedDataTypes | length) == 0 and
  any(.NSPrivacyAccessedAPITypes[];
    .NSPrivacyAccessedAPIType == "NSPrivacyAccessedAPICategoryUserDefaults" and
    (.NSPrivacyAccessedAPITypeReasons | index("CA92.1")) != null)
' >/dev/null

for catalog in $(find Apps -name '*.xcstrings' -type f | sort); do
  jq -e '
    .sourceLanguage == "en" and
    (.strings | to_entries | all(
      ((.value.localizations.en.stringUnit.value? // "") | length) > 0 and
      ((.value.localizations.tr.stringUnit.value? // "") | length) > 0 and
      (.value.localizations.en.stringUnit.state? // "translated") != "needs_review" and
      (.value.localizations.tr.stringUnit.state? // "translated") != "needs_review"
    ))
  ' "$catalog" >/dev/null || {
    echo "incomplete English/Turkish catalog: $catalog" >&2
    exit 1
  }
done

test "$(ruby Scripts/generate_sbom.rb | jq '.components | length')" -ge 1
Scripts/test_persistence_process_crash.sh
Scripts/test_database_recovery.sh

grep -q 'accessibilityLabel' Packages/AgentControlKit/Sources/AgentMacUI/DashboardViews.swift
grep -q 'keyboardShortcut(.defaultAction)' Packages/AgentControlKit/Sources/AgentMacUI/DecisionViews.swift
grep -q 'accessibilityLabel' Apps/iOS/CompanionViews.swift
grep -q 'accessibilityReduceMotion' Packages/AgentControlKit/Sources/AgentMacUI/NotchPanelView.swift

echo 'phase 15 privacy/localization/accessibility/recovery gates: ok'
