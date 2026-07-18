#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

command -v xcodegen >/dev/null 2>&1 || {
  echo 'xcodegen is missing; run make bootstrap first' >&2
  exit 1
}

xcodegen generate --spec project.yml
echo 'generate: ok'

