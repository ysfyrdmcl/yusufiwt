#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repo_root/dist/yusufiwt.app"
zip="$repo_root/dist/yusufiwt-macOS-local-v1.zip"

test -d "$app"
test -f "$zip"
test -f "$repo_root/dist/SHA256SUMS.txt"
codesign --verify --deep --strict --verbose=2 "$app"
"$app/Contents/MacOS/agentcontrol-hook" version | grep -q '^agentcontrol-hook '
plutil -extract AgentControlReleaseScope raw "$app/Contents/Info.plist" | grep -q '^mac-local-v1$'
grep -q '"releaseScope":"mac-local-v1"' "$app/Contents/Resources/release-manifest.json"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/agentcontrol-zip.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
ditto -x -k "$zip" "$temporary"
codesign --verify --deep --strict "$temporary/yusufiwt.app"

if find "$app" -type f \( -name '*Watch*' -o -name '*NotificationService*' -o -name '*Relay*' -o -name 'Sparkle*' \) | grep -q .; then
  echo 'Deferred V2 runtime artifact found' >&2
  exit 1
fi
echo 'verify-mac-local-v1: package contract ok'

if "$app/Contents/MacOS/agentcontrol-hook" doctor | grep -q '"health"'; then
  echo 'verify-mac-local-v1: live helper doctor ok'
else
  echo 'verify-mac-local-v1: BLOCKED_EXTERNAL helper is not registered/approved; complete onboarding and rerun' >&2
  exit 2
fi
