#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

test -f Docs/ARCHITECTURE.md
test -f Docs/THREAT_MODEL.md
test -f Docs/PRIVACY.md
test -f Config/Privacy/PrivacyInfo.xcprivacy
test -f Docs/ADR/0001-local-first.md
test -f Docs/ADR/0008-strict-concurrency.md
grep -q 'swift-tools-version: 6.2' Package.swift
echo 'phase 0 contract: ok'
