#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
mkdir -p .build/cache .build/config .build/security .build/clang-module-cache

CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/clang-module-cache" \
swift test --quiet --enable-code-coverage --disable-sandbox \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security \
  --scratch-path .build

coverage_path=$(find .build -path '*/debug/codecov/AgentControl.json' -type f -print -quit)
if [ -z "$coverage_path" ]; then
  echo 'Swift coverage report is missing' >&2
  exit 1
fi
ruby Scripts/verify_coverage.rb "$coverage_path"
