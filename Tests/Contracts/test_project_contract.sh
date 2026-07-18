#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

test -d AgentControl.xcodeproj
test -f AgentControl.xcodeproj/project.pbxproj

for catalog in Apps/macOS/Resources/Localizable.xcstrings Apps/iOS/Resources/Localizable.xcstrings; do
  grep -q '"en"' "$catalog"
  grep -q '"tr"' "$catalog"
done

plutil -lint Config/LaunchAgents/com.yusuf.agentcontrol.helper.plist >/dev/null
grep -q '<key>BundleProgram</key>' Config/LaunchAgents/com.yusuf.agentcontrol.helper.plist
grep -q '<key>MachServices</key>' Config/LaunchAgents/com.yusuf.agentcontrol.helper.plist
grep -q 'product: AgentLocalIPC' project.yml
grep -q 'Embed LaunchAgent Helper' project.yml
test -f Docs/PHASE_3_TEST_PLAN.md

if find Apps Services Packages -type d -name .build -prune -o -type f -name '*.swift' -print0 \
  | xargs -0 grep -n 'fatalError("not implemented")\|TODO[^A-Z0-9-]' 2>/dev/null; then
  echo 'unfinished production implementation found' >&2
  exit 1
fi

echo 'generated project contract: ok'
