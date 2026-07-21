#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

for path in \
  Services/AgentControlRelay/Package.swift \
  Services/AgentControlRelay/Dockerfile \
  Services/AgentControlRelay/docker-compose.yml \
  Services/AgentControlRelay/Sources/AgentControlRelay/configure.swift \
  Services/AgentControlRelay/Sources/AgentControlRelay/Migrations.swift \
  Services/AgentControlRelay/Sources/AgentControlRelay/AuthController.swift \
  Services/AgentControlRelay/Sources/AgentControlRelay/DevicePairingController.swift \
  Services/AgentControlRelay/Sources/AgentControlRelay/EnvelopeController.swift \
  Packages/AgentControlKit/Sources/AgentCompanion/CompanionCrypto.swift \
  Packages/AgentControlKit/Sources/AgentCompanion/ReplayProtection.swift \
  Docs/ADR/0017-single-mac-companion-scope.md
do
  test -f "$path" || { echo "missing Phase 12 file: $path" >&2; exit 1; }
done

grep -q 'vapor/vapor' Services/AgentControlRelay/Package.swift
grep -q 'fluent-postgres-driver' Services/AgentControlRelay/Package.swift
grep -q 'vapor/redis' Services/AgentControlRelay/Package.swift
grep -q 'unique(on: "sender_device_id", "sequence")' Services/AgentControlRelay/Sources/AgentControlRelay/Migrations.swift
grep -q 'single local Mac authority' Services/AgentControlRelay/Sources/AgentControlRelay/AuthController.swift
grep -q 'kind != .companionDecision' Services/AgentControlRelay/Sources/AgentControlRelay/EnvelopeController.swift
grep -q 'kind == .companionDecision' Services/AgentControlRelay/Sources/AgentControlRelay/EnvelopeController.swift
grep -q 'ChaChaPoly.seal' Packages/AgentControlKit/Sources/AgentCompanion/CompanionCrypto.swift
grep -q 'Curve25519.Signing.PublicKey' Services/AgentControlRelay/Sources/AgentControlRelay/EnvelopeController.swift

if rg -n 'AgentControlRemoteNode|SSH bootstrap|systemd' Services Packages/AgentControlKit/Sources project.yml Package.swift; then
  echo 'remote-node/SSH scope must not be implemented' >&2
  exit 1
fi

if rg -n '@Field\(key: "(prompt|path|command|decision_content)"' Services/AgentControlRelay/Sources; then
  echo 'relay persistence must not contain plaintext agent content fields' >&2
  exit 1
fi

echo 'phase 12 contract: ok'
