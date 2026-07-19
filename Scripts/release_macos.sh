#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

require_env() {
  eval "value=\${$1-}"
  test -n "$value" || { echo "$1 is required" >&2; exit 1; }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }
}

require_env RELEASE_VERSION
require_env BUILD_NUMBER
require_env RELEASE_CHANNEL
require_env AGENTCONTROL_TEAM_ID
require_env DEVELOPER_ID_APPLICATION
require_env SPARKLE_PUBLIC_ED_KEY
require_command xcodebuild
require_command xcodegen
require_command jq

case "$RELEASE_VERSION" in
  *[!0-9A-Za-z.-]*|'') echo 'RELEASE_VERSION contains unsupported characters' >&2; exit 1 ;;
esac
case "$BUILD_NUMBER" in
  ''|0|*[!0-9]*) echo 'BUILD_NUMBER must be a positive integer' >&2; exit 1 ;;
esac
case "$RELEASE_CHANNEL" in
  stable|beta) ;;
  *) echo 'RELEASE_CHANNEL must be stable or beta' >&2; exit 1 ;;
esac

ruby -rbase64 -e 'abort "invalid SPARKLE_PUBLIC_ED_KEY" unless Base64.strict_decode64(ARGV.fetch(0)).bytesize == 32' "$SPARKLE_PUBLIC_ED_KEY"

channel_config="$repo_root/Config/Updates/channels.json"
feed_url=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("channels").fetch(ARGV[1]).fetch("appcastURL")' "$channel_config" "$RELEASE_CHANNEL")
download_prefix=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("channels").fetch(ARGV[1]).fetch("downloadURLPrefix")' "$channel_config" "$RELEASE_CHANNEL")

release_root=${AGENTCONTROL_RELEASE_ROOT:-"$repo_root/.build/releases"}
release_dir="$release_root/macos/$RELEASE_VERSION-$BUILD_NUMBER-$RELEASE_CHANNEL"
test ! -e "$release_dir" || { echo "release directory already exists: $release_dir" >&2; exit 1; }
mkdir -p "$release_dir"

archive_path="$release_dir/yusufiwt.xcarchive"
derived_data="$release_dir/DerivedData"
export_dir="$release_dir/export"
feed_dir="$release_dir/feed/$RELEASE_CHANNEL"
mkdir -p "$export_dir" "$feed_dir"

xcodegen generate --spec project.yml
xcodebuild -project yusufiwt.xcodeproj -scheme AgentControlMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
  -archivePath "$archive_path" archive \
  MARKETING_VERSION="$RELEASE_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$AGENTCONTROL_TEAM_ID" CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" SPARKLE_FEED_URL="$feed_url" \
  SPARKLE_CHANNEL="$RELEASE_CHANNEL"

xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_dir" \
  -exportOptionsPlist Config/ExportOptions/DeveloperID.plist

app_path="$export_dir/yusufiwt.app"
test -d "$app_path" || { echo 'Developer ID export did not contain yusufiwt.app' >&2; exit 1; }

notarization_required=1
if test "${AGENTCONTROL_SKIP_NOTARIZATION:-0}" = 1; then
  notarization_required=0
  : > "$release_dir/UNPUBLISHABLE-NOT-NOTARIZED"
else
  require_env NOTARY_KEYCHAIN_PROFILE
  initial_zip="$release_dir/yusufiwt-notary.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$initial_zip"
  xcrun notarytool submit "$initial_zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait --output-format json > "$release_dir/notary-app.json"
  test "$(jq -r '.status' "$release_dir/notary-app.json")" = Accepted || { echo 'app notarization was not accepted' >&2; exit 1; }
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  rm "$initial_zip"
fi

zip_path="$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

dmg_stage="$release_dir/dmg-root"
mkdir -p "$dmg_stage"
/usr/bin/ditto "$app_path" "$dmg_stage/yusufiwt.app"
ln -s /Applications "$dmg_stage/Applications"
dmg_path="$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.dmg"
hdiutil create -srcfolder "$dmg_stage" -volname "yusufiwt $RELEASE_VERSION" -format UDZO "$dmg_path" >/dev/null
rm "$dmg_stage/Applications"
rm -r "$dmg_stage"

if test "$notarization_required" = 1; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dmg_path"
  xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait --output-format json > "$release_dir/notary-dmg.json"
  test "$(jq -r '.status' "$release_dir/notary-dmg.json")" = Accepted || { echo 'DMG notarization was not accepted' >&2; exit 1; }
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

symbols_zip="$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER-dSYMs.zip"
/usr/bin/ditto -c -k --keepParent "$archive_path/dSYMs" "$symbols_zip"
RELEASE_VERSION="$RELEASE_VERSION" ruby Scripts/generate_sbom.rb > "$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.cdx.json"

/usr/bin/ditto "$zip_path" "$feed_dir/$(basename "$zip_path")"
if test -n "${RELEASE_NOTES_FILE:-}"; then
  test -f "$RELEASE_NOTES_FILE" || { echo 'RELEASE_NOTES_FILE does not exist' >&2; exit 1; }
  /usr/bin/ditto "$RELEASE_NOTES_FILE" "$feed_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.md"
fi

if test -n "${SPARKLE_BIN_DIR:-}"; then
  generate_appcast="$SPARKLE_BIN_DIR/generate_appcast"
else
  generate_appcast=$(find "$derived_data/SourcePackages/artifacts" -type f -name generate_appcast -perm +111 | head -n 1)
fi
test -x "$generate_appcast" || { echo 'Sparkle generate_appcast tool was not found' >&2; exit 1; }

if test "$RELEASE_CHANNEL" = beta; then
  if test -n "${SPARKLE_PRIVATE_KEY_FILE:-}"; then
    "$generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --channel beta \
      --download-url-prefix "$download_prefix" "$feed_dir"
  else
    "$generate_appcast" --channel beta --download-url-prefix "$download_prefix" "$feed_dir"
  fi
else
  if test -n "${SPARKLE_PRIVATE_KEY_FILE:-}"; then
    "$generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
      --download-url-prefix "$download_prefix" "$feed_dir"
  else
    "$generate_appcast" --download-url-prefix "$download_prefix" "$feed_dir"
  fi
fi

appcast_path="$feed_dir/appcast.xml"
test -s "$appcast_path" || { echo 'Sparkle appcast was not generated' >&2; exit 1; }
grep -q 'sparkle:edSignature=' "$appcast_path" || { echo 'Sparkle appcast has no EdDSA update signature' >&2; exit 1; }

checksums="$release_dir/SHA256SUMS"
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 \
    "$(basename "$zip_path")" "$(basename "$dmg_path")" "$(basename "$symbols_zip")" \
    "$(basename "$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.cdx.json")" \
    "feed/$RELEASE_CHANNEL/appcast.xml" > "$(basename "$checksums")"
)

verifier_args=""
test "$notarization_required" = 0 || verifier_args="--require-notarization"
ruby Scripts/release_verifier.rb --app "$app_path" --dmg "$dmg_path" \
  --sbom "$release_dir/yusufiwt-$RELEASE_VERSION-$BUILD_NUMBER.cdx.json" \
  --checksums "$checksums" --dsyms "$archive_path/dSYMs" $verifier_args \
  --report "$release_dir/release-verifier.json"

echo "macOS release artifacts: $release_dir"
