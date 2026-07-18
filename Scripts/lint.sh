#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

swiftformat Apps Services Packages --lint --cache ignore
swiftlint lint --strict --no-cache
