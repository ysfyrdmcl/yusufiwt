#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

common_args="-project AgentControl.xcodeproj -configuration Debug SYMROOT=$repo_root/.build/XcodeProducts OBJROOT=$repo_root/.build/XcodeIntermediates CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
build_log="$repo_root/.build/xcodebuild.log"

build_target() {
  target_name=$1
  sdk_name=$2
  if ! xcodebuild $common_args -target "$target_name" -sdk "$sdk_name" build >"$build_log" 2>&1; then
    cat "$build_log" >&2
    return 1
  fi
  echo "xcode target: $target_name ok"
}

build_scheme() {
  scheme_name=$1
  destination_name=$2
  if ! xcodebuild -project AgentControl.xcodeproj -scheme "$scheme_name" -configuration Debug \
    -destination "$destination_name" -derivedDataPath "$repo_root/.build/XcodeDerivedData-$scheme_name" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$build_log" 2>&1; then
    cat "$build_log" >&2
    return 1
  fi
  echo "xcode scheme: $scheme_name ok"
}

build_target AgentControlMac macosx
build_target AgentControlHelper macosx
build_target AgentControlHook macosx
build_target FakeAgentSimulator macosx
build_target ProtocolInspector macosx
build_scheme AgentControliOS 'generic/platform=iOS Simulator'
build_target NotificationService iphonesimulator
build_target AgentLiveActivity iphonesimulator
build_target AgentWidgets iphonesimulator
build_scheme AgentControlWatch 'generic/platform=watchOS Simulator'

echo 'xcode shell targets: ok'
