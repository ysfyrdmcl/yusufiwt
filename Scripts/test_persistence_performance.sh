#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
mkdir -p .build/cache .build/config .build/security .build/clang-module-cache

AGENTCONTROL_RUN_PERFORMANCE_TESTS=1 \
CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/clang-module-cache" \
swift test --quiet --disable-sandbox \
  --filter 'PerformanceFixtureTests/hundredThousandEvents' \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security \
  --scratch-path .build
