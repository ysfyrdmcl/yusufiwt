#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

if ! command -v xcodebuild >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo 'Xcode and the Swift toolchain are required.' >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo 'Homebrew is required to install pinned repository tools.' >&2
  exit 1
fi

missing_tools=''
for tool in xcodegen swiftformat swiftlint; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools="$missing_tools $tool"
  fi
done

if [ -n "$missing_tools" ]; then
  # Homebrew installs only missing tools and never changes project config files.
  brew install $missing_tools
fi

chmod +x Scripts/*.sh Tests/Contracts/*.sh
mkdir -p .build/cache .build/config .build/security .build/clang-module-cache
CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/clang-module-cache" \
swift package resolve --disable-sandbox \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security 
echo 'bootstrap: ok'
