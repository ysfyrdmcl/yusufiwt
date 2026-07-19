#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

derived_data="$repo_root/.build/MacLocalDerivedData"
product="$derived_data/Build/Products/MacLocalRelease/yusufiwt.app"
output="$repo_root/dist/yusufiwt.app"
signing_mode=${SIGNING_MODE:-adhoc}

make generate
mkdir -p "$repo_root/dist"
xcodebuild -project yusufiwt.xcodeproj -scheme AgentControlMacLocal \
  -configuration MacLocalRelease -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

test -x "$product/Contents/MacOS/yusufiwt"
test -x "$product/Contents/MacOS/AgentControlHelper"
test -x "$product/Contents/MacOS/agentcontrol-hook"
test -f "$product/Contents/Library/LaunchAgents/com.yusuf.agentcontrol.helper.plist"
test -f "$product/Contents/Resources/release-manifest.json"

rm -rf "$output"
ditto "$product" "$output"
rm -f "$output/Contents/Resources/AgentControlHelper" "$output/Contents/Resources/agentcontrol-hook"

case "$signing_mode" in
  adhoc)
    identity=-
    ;;
  development)
    identity=${CODE_SIGN_IDENTITY:-}
    if [ -z "$identity" ]; then
      identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)
    fi
    test -n "$identity" || { echo 'No Apple Development identity found; use SIGNING_MODE=adhoc.' >&2; exit 1; }
    ;;
  *)
    echo 'SIGNING_MODE must be adhoc or development' >&2
    exit 64
    ;;
esac

codesign --force --sign "$identity" --identifier com.yusuf.agentcontrol.helper \
  "$output/Contents/MacOS/AgentControlHelper"
codesign --force --sign "$identity" "$output/Contents/MacOS/agentcontrol-hook"
codesign --force --sign "$identity" --options runtime --entitlements Config/Entitlements/AgentControlMac.entitlements \
  "$output"
codesign --verify --deep --strict --verbose=2 "$output"

test "$(plutil -extract AgentControlReleaseScope raw "$output/Contents/Info.plist")" = mac-local-v1
if find "$output" -type f \( -name '*Watch*' -o -name '*NotificationService*' -o -name '*Relay*' -o -name 'Sparkle*' \) | grep -q .; then
  echo 'Mac Local bundle contains a deferred V2 artifact' >&2
  exit 1
fi
printf '%s\n' "$signing_mode" > "$repo_root/dist/SIGNING_MODE.txt"
echo "build-mac-local: ok ($signing_mode)"
