#!/bin/sh
set -eu

required='Config/MacLocalRelease.xcconfig Docs/MAC_LOCAL_V1_SCOPE.md Docs/ADR/0022-mac-local-v1-release-scope.md Scripts/build_mac_local.sh Scripts/package_mac_local.sh Scripts/install_mac_local.sh Scripts/uninstall_mac_local.sh Scripts/verify_mac_local_v1.sh'
for path in $required; do test -f "$path"; done

grep -q '^  MacLocalRelease: release' project.yml
grep -q '^  AgentControlMacLocal:' project.yml
grep -q '^  AgentControlMacLocal:' project.yml
grep -q 'FEATURE_RELAY = NO' Config/MacLocalRelease.xcconfig
grep -q 'FEATURE_APNS = NO' Config/MacLocalRelease.xcconfig
grep -q 'FEATURE_SPARKLE = NO' Config/MacLocalRelease.xcconfig
if sed -n '/AgentControlMacLocal:/,/  AgentControlMac:/p' project.yml | grep -q 'product: AgentCompanion\|product: Sparkle'; then
  echo 'Mac Local target depends on a deferred V2 product' >&2
  exit 1
fi

app_shell='Apps/macOS/AgentControlMacApp.swift'
test -f Apps/macOS/ControlCenterWindowController.swift
test -f Apps/macOS/MacLocalSettingsView.swift
grep -q 'MenuBarExtra' "$app_shell"
grep -q 'Settings {' "$app_shell"
grep -q 'menu.openControlCenter' "$app_shell"
grep -q 'menu.settings' "$app_shell"
grep -q 'settings.sound.on' "$app_shell"
if grep -qE '^[[:space:]]*(Window|WindowGroup)\(' "$app_shell"; then
  echo 'Mac Local app shell must not auto-create a dashboard window' >&2
  exit 1
fi
jq -e '.strings["controlCenter.title"].localizations.en.stringUnit.value == "Control Center"' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null
jq -e '.strings["controlCenter.title"].localizations.tr.stringUnit.value == "Kontrol Merkezi"' \
  Apps/macOS/Resources/Localizable.xcstrings >/dev/null
echo 'mac local v1 contract: ok'
