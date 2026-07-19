#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

mode=${1:-export}
case "$mode" in
  export|upload) ;;
  *) echo 'usage: Scripts/release_ios.sh [export|upload]' >&2; exit 1 ;;
esac

require_env() {
  eval "value=\${$1-}"
  test -n "$value" || { echo "$1 is required" >&2; exit 1; }
}

require_env RELEASE_VERSION
require_env BUILD_NUMBER
require_env AGENTCONTROL_TEAM_ID
case "$RELEASE_VERSION" in
  *[!0-9A-Za-z.-]*|'') echo 'RELEASE_VERSION contains unsupported characters' >&2; exit 1 ;;
esac
case "$BUILD_NUMBER" in
  ''|0|*[!0-9]*) echo 'BUILD_NUMBER must be a positive integer' >&2; exit 1 ;;
esac

release_root=${AGENTCONTROL_RELEASE_ROOT:-"$repo_root/.build/releases"}
release_dir="$release_root/ios/$RELEASE_VERSION-$BUILD_NUMBER"
test ! -e "$release_dir" || { echo "release directory already exists: $release_dir" >&2; exit 1; }
mkdir -p "$release_dir"

archive_path="$release_dir/yusufiwt-iOS.xcarchive"
derived_data="$release_dir/DerivedData"
export_dir="$release_dir/export"
mkdir -p "$export_dir"

xcodegen generate --spec project.yml

archive_build() {
  if test -n "${ASC_KEY_PATH:-}" || test -n "${ASC_KEY_ID:-}" || test -n "${ASC_ISSUER_ID:-}"; then
    require_env ASC_KEY_PATH
    require_env ASC_KEY_ID
    require_env ASC_ISSUER_ID
    xcodebuild -project yusufiwt.xcodeproj -scheme AgentControliOS -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
      -archivePath "$archive_path" archive -allowProvisioningUpdates \
      -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
      MARKETING_VERSION="$RELEASE_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      DEVELOPMENT_TEAM="$AGENTCONTROL_TEAM_ID"
  else
    xcodebuild -project yusufiwt.xcodeproj -scheme AgentControliOS -configuration Release \
      -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
      -archivePath "$archive_path" archive -allowProvisioningUpdates \
      MARKETING_VERSION="$RELEASE_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      DEVELOPMENT_TEAM="$AGENTCONTROL_TEAM_ID"
  fi
}

archive_build
ruby Scripts/release_verifier.rb --ios-archive "$archive_path" --report "$release_dir/archive-verifier.json"

if test "$mode" = upload; then
  export_options=Config/ExportOptions/TestFlightUpload.plist
else
  export_options=Config/ExportOptions/AppStoreExport.plist
fi

if test -n "${ASC_KEY_PATH:-}"; then
  xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
else
  xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" -allowProvisioningUpdates
fi

symbols_zip="$release_dir/yusufiwt-iOS-$RELEASE_VERSION-$BUILD_NUMBER-dSYMs.zip"
/usr/bin/ditto -c -k --keepParent "$archive_path/dSYMs" "$symbols_zip"
sbom="$release_dir/yusufiwt-iOS-$RELEASE_VERSION-$BUILD_NUMBER.cdx.json"
RELEASE_VERSION="$RELEASE_VERSION" ruby Scripts/generate_sbom.rb > "$sbom"

checksums="$release_dir/SHA256SUMS"
(
  cd "$release_dir"
  checksum_inputs="$(basename "$symbols_zip") $(basename "$sbom")"
  ipa=$(find export -maxdepth 1 -type f -name '*.ipa' -print -quit)
  test -z "$ipa" || checksum_inputs="$checksum_inputs $ipa"
  # shellcheck disable=SC2086 -- inputs are controlled release filenames.
  /usr/bin/shasum -a 256 $checksum_inputs > "$(basename "$checksums")"
)

echo "iOS/watchOS release artifacts: $release_dir"
