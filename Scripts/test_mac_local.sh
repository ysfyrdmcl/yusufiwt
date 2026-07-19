#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/clang-module-cache" \
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config \
  --security-path .build/security --scratch-path .build
./Tests/Contracts/test_mac_local_v1_contract.sh
echo 'test-mac-local: ok'
