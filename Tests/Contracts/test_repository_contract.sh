#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

required_files='README.md LICENSE CHANGELOG.md SECURITY.md CONTRIBUTING.md CODEOWNERS Makefile project.yml Package.swift .gitignore .swiftformat .swiftlint.yml .editorconfig Config/Base.xcconfig Config/Debug.xcconfig Config/Staging.xcconfig Config/Release.xcconfig Config/Local.example.xcconfig Apps/macOS/Resources/Localizable.xcstrings Apps/iOS/Resources/Localizable.xcstrings'

for required_file in $required_files; do
  if [ ! -f "$required_file" ]; then
    echo "missing repository contract file: $required_file" >&2
    exit 1
  fi
done

for adr_number in 0001 0002 0003 0004 0005 0006 0007 0008; do
  if ! find Docs/ADR -maxdepth 1 -name "${adr_number}-*.md" -type f | grep -q .; then
    echo "missing accepted ADR: $adr_number" >&2
    exit 1
  fi
done

test -f Docs/ADR/0009-domain-and-wire-contract.md
test -f Docs/PROTOCOL.md
test -f Packages/AgentControlKit/Sources/AgentProtocol/JSONSchema/event-envelope-v1.schema.json

if rg -n '^import (SwiftUI|AppKit|UIKit|SQLite3|Network)$' Packages/AgentControlKit/Sources/AgentDomain >/dev/null; then
  echo 'AgentDomain imports a forbidden platform or infrastructure framework' >&2
  exit 1
fi

for target_name in AgentControlMac AgentControliOS AgentControlWatch NotificationService AgentLiveActivity AgentWidgets AgentControlHelper; do
  if ! grep -q "^  ${target_name}:" project.yml; then
    echo "missing XcodeGen target: $target_name" >&2
    exit 1
  fi
done

for configuration in Debug Staging Release; do
  if ! grep -q "^  ${configuration}:" project.yml; then
    echo "missing build configuration: $configuration" >&2
    exit 1
  fi
done

grep -q 'com.yusuf.agentcontrol.mac' Config/Base.xcconfig
grep -q 'group.com.yusuf.agentcontrol' Config/Base.xcconfig
grep -q 'SWIFT_STRICT_CONCURRENCY = complete' Config/Base.xcconfig
grep -q 'AGENTCONTROL_ALLOW_DEBUG_FEATURES = YES' Config/Debug.xcconfig
grep -q 'AGENTCONTROL_ALLOW_DEBUG_FEATURES = NO' Config/Staging.xcconfig
grep -q 'AGENTCONTROL_ALLOW_DEBUG_FEATURES = NO' Config/Release.xcconfig

if grep -R -E --exclude='test_repository_contract.sh' --exclude='test_secret_hygiene.sh' --exclude='AgentControl_PROJECT_PLAN.md' --exclude='yusufiwt_PROJECT_PLAN.md' '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|replace_me|password[[:space:]]*=[[:space:]]*[^$])' . \
  --exclude-dir=.git --exclude-dir=.build --exclude-dir=node_modules --exclude-dir=AgentControl.xcodeproj --exclude-dir=yusufiwt.xcodeproj >/dev/null; then
  echo 'potential secret or forbidden placeholder found' >&2
  exit 1
fi

echo 'repository contract: ok'
