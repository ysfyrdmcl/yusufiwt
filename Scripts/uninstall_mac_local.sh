#!/bin/sh
set -eu

destination=${DESTINATION:-/Applications/yusufiwt.app}
data_root="$HOME/Library/Application Support/AgentControl"
launch_plist="$HOME/Library/LaunchAgents/com.yusuf.agentcontrol.helper.plist"

launchctl bootout "gui/$(id -u)/com.yusuf.agentcontrol.helper" >/dev/null 2>&1 || true
rm -f "$launch_plist"
if [ -x "$destination/Contents/MacOS/agentcontrol-hook" ]; then
  "$destination/Contents/MacOS/agentcontrol-hook" managed-uninstall codex >/dev/null 2>&1 || true
  "$destination/Contents/MacOS/agentcontrol-hook" managed-uninstall claude >/dev/null 2>&1 || true
  "$destination/Contents/MacOS/agentcontrol-hook" managed-uninstall gemini >/dev/null 2>&1 || true
fi
rm -rf "$destination"
if [ "${PURGE_DATA:-0}" = 1 ]; then
  rm -rf "$data_root"
  echo 'uninstall-mac-local: app and yusufiwt local data removed'
else
  echo 'uninstall-mac-local: app removed; local history preserved (use PURGE_DATA=1 to remove it)'
fi
