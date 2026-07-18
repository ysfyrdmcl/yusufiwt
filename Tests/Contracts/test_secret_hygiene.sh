#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

secret_file=$(find . \
  \( -type d \( -name .git -o -name .build -o -name AgentControl.xcodeproj \) -prune \) -o \
  \( -type f \( -name '*.p8' -o -name '*.p12' -o -name '*.key' -o -name 'Local.xcconfig' -o -name '.env' \) -print \) \
  | sed -n '1p')

if [ -n "$secret_file" ]; then
  echo 'tracked-secret-shaped file found' >&2
  exit 1
fi

echo 'secret hygiene: ok'
