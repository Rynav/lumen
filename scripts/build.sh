#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
xcodebuild -quiet -project Lumen.xcodeproj -scheme Lumen -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
