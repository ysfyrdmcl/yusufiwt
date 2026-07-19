#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

"$repo_root/Scripts/build_mac_local.sh"
zip_path="$repo_root/dist/yusufiwt-macOS-local-v1.zip"
payload="$repo_root/.build/MacLocalPackage"
rm -f "$zip_path" "$repo_root/dist/SHA256SUMS.txt"
rm -rf "$payload"
mkdir -p "$payload"
ditto "$repo_root/dist/yusufiwt.app" "$payload/yusufiwt.app"
ditto "$repo_root/Scripts/install_mac_local.sh" "$payload/install_mac_local.sh"
ditto "$repo_root/Scripts/uninstall_mac_local.sh" "$payload/uninstall_mac_local.sh"
ditto "$repo_root/dist/SIGNING_MODE.txt" "$payload/SIGNING_MODE.txt"
test ! -f "$repo_root/Docs/MAC_LOCAL_V1_INSTALL.md" || ditto "$repo_root/Docs/MAC_LOCAL_V1_INSTALL.md" "$payload/INSTALL.md"
ditto -c -k "$payload" "$zip_path"

app_sha=$(find "$repo_root/dist/yusufiwt.app" -type f -print | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done | shasum -a 256 | cut -d ' ' -f 1)
zip_sha=$(shasum -a 256 "$zip_path" | cut -d ' ' -f 1)
{
  printf '%s  %s\n' "$app_sha" 'yusufiwt.app'
  printf '%s  %s\n' "$zip_sha" 'yusufiwt-macOS-local-v1.zip'
} > "$repo_root/dist/SHA256SUMS.txt"
echo 'package-mac-local: ok (Developer ID/notarization not applicable)'
