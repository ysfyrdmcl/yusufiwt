#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

secret_file=$(git ls-files --cached -- \
  '*.p8' \
  '*.p12' \
  '*.key' \
  'Local.xcconfig' \
  '.env' \
  | sed -n '1p')

if [ -n "$secret_file" ]; then
  echo "tracked-secret-shaped file found: $secret_file" >&2
  exit 1
fi

echo 'secret hygiene: ok'
