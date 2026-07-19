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
echo 'mac local v1 contract: ok'
