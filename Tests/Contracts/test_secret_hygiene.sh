#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

secret_file=$(git ls-files --cached -- \
  ':(glob)**/*.p8' \
  ':(glob)**/*.p12' \
  ':(glob)**/*.key' \
  ':(glob)**/*.pem' \
  ':(glob)**/*.mobileprovision' \
  ':(glob)**/Local.xcconfig' \
  ':(glob)**/.env' \
  ':(glob)**/.env.*' \
  ':(exclude,glob)**/.env.example' \
  | sed -n '1p')

if [ -n "$secret_file" ]; then
  echo "tracked-secret-shaped file found: $secret_file" >&2
  exit 1
fi

artifact_file=$(git ls-files --cached -- \
  ':(glob)**/build/**' \
  ':(top,glob)dist/**' \
  ':(top,glob)output/**' \
  | sed -n '1p')

if [ -n "$artifact_file" ]; then
  echo "tracked build or output artifact found: $artifact_file" >&2
  exit 1
fi

echo 'secret hygiene: ok'
