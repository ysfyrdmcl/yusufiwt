#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

required_files='.github/workflows/release.yml
Apps/macOS/SparkleUpdateController.swift
Config/ExportOptions/DeveloperID.plist
Config/ExportOptions/AppStoreExport.plist
Config/ExportOptions/TestFlightUpload.plist
Config/Updates/channels.json
Config/SBOM/agentcontrol.cdx.json
Docs/ADR/0020-release-pipeline.md
Docs/RELEASE_RUNBOOK.md
Scripts/release_macos.sh
Scripts/release_ios.sh
Scripts/release_verifier.rb'

printf '%s\n' "$required_files" | while IFS= read -r file; do
  test -f "$file" || { echo "missing Phase 16 file: $file" >&2; exit 1; }
done

grep -q 'ENABLE_HARDENED_RUNTIME = YES' Config/Release.xcconfig
grep -q 'DEBUG_INFORMATION_FORMAT = dwarf-with-dsym' Config/Release.xcconfig
grep -q 'SUPublicEDKey' Apps/macOS/Info.plist
grep -q 'SUFeedURL' Apps/macOS/Info.plist
grep -q 'Sparkle' project.yml
grep -q 'release-manifest.json' project.yml
grep -q 'notarytool submit' Scripts/release_macos.sh
grep -q 'stapler staple' Scripts/release_macos.sh
grep -q 'generate_appcast' Scripts/release_macos.sh
grep -q 'xcodebuild.*archive' Scripts/release_ios.sh
grep -q 'TestFlightUpload.plist' Scripts/release_ios.sh
grep -q 'generate_sbom.rb' Scripts/release_macos.sh
grep -q 'generate_sbom.rb' Scripts/release_ios.sh

for script in Scripts/release_macos.sh Scripts/release_ios.sh; do
  sh -n "$script"
done
ruby -c Scripts/release_verifier.rb >/dev/null
ruby Scripts/release_verifier.rb --structural
test "$(RELEASE_VERSION=1.2.3 ruby Scripts/generate_sbom.rb | jq -r '.components[] | select(.name == "sparkle") | .version')" = 2.9.2
test "$(RELEASE_VERSION=1.2.3 ruby Scripts/generate_sbom.rb | jq -r '.metadata.component.version')" = 1.2.3

if git ls-files | grep -E '\.(p8|p12|key)$' >/dev/null; then
  echo 'private signing material is tracked' >&2
  exit 1
fi

echo 'phase 16 release pipeline contract: ok'
