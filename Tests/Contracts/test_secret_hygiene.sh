#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

if find . -type f \
  ! -path './.git/*' \
  ! -path './.build/*' \
  ! -path './AgentControl.xcodeproj/*' \
  \( -name '*.p8' -o -name '*.p12' -o -name '*.key' -o -name 'Local.xcconfig' -o -name '.env' \) | grep -q .; then
  echo 'tracked-secret-shaped file found' >&2
  exit 1
fi

echo 'secret hygiene: ok'
