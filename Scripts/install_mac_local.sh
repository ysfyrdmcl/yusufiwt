#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
if [ -d "$script_dir/yusufiwt.app" ]; then
  source_app="$script_dir/yusufiwt.app"
  signing_mode_file="$script_dir/SIGNING_MODE.txt"
else
  source_app="$repo_root/dist/yusufiwt.app"
  signing_mode_file="$repo_root/dist/SIGNING_MODE.txt"
fi
destination=${DESTINATION:-/Applications/yusufiwt.app}

test -d "$source_app" || "$repo_root/Scripts/build_mac_local.sh"
parent=$(dirname "$destination")
mkdir -p "$parent"
staging="$parent/.yusufiwt.installing.$$"
rm -rf "$staging"
ditto "$source_app" "$staging"
codesign --verify --deep --strict "$staging"
if [ -e "$destination" ]; then
  backup="$parent/.yusufiwt.previous.$$"
  mv "$destination" "$backup"
  if ! mv "$staging" "$destination"; then
    mv "$backup" "$destination"
    exit 1
  fi
  rm -rf "$backup"
else
  mv "$staging" "$destination"
fi

signing_mode=$(test -f "$signing_mode_file" && sed -n '1p' "$signing_mode_file" || printf 'adhoc')
if [ "$signing_mode" = adhoc ]; then
  # macOS launch constraints reject ad-hoc helpers registered through
  # SMAppService. A same-user LaunchAgent keeps local development builds usable;
  # development/Developer ID builds continue to use SMAppService in the app.
  launch_agents="$HOME/Library/LaunchAgents"
  launch_plist="$launch_agents/com.yusuf.agentcontrol.helper.plist"
  launch_staging="$launch_agents/.com.yusuf.agentcontrol.helper.plist.$$"
  mkdir -p "$launch_agents"
  launchctl bootout "gui/$(id -u)/com.yusuf.agentcontrol.helper" >/dev/null 2>&1 || true
  ditto "$destination/Contents/Library/LaunchAgents/com.yusuf.agentcontrol.helper.plist" "$launch_staging"
  plutil -remove BundleProgram "$launch_staging"
  plutil -insert ProgramArguments -json "[\"$destination/Contents/MacOS/AgentControlHelper\"]" "$launch_staging"
  chmod 600 "$launch_staging"
  mv "$launch_staging" "$launch_plist"
  launchctl bootstrap "gui/$(id -u)" "$launch_plist"
fi

if [ "${OPEN_APP:-1}" = 1 ]; then
  open "$destination"
fi
echo "install-mac-local: installed at $destination"
echo 'Complete first-run helper/notification approval, then run: make verify-mac-local-v1'
