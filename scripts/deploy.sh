#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/xcode-environment.sh"
configure_xcode_environment

xcodegen generate
xcodebuild \
    -project SpaceManager.xcodeproj \
    -scheme SpaceManager \
    -configuration Release \
    -derivedDataPath build \
    -destination "generic/platform=macOS" \
    build

pkill -9 -x "Space Manager" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/Space Manager.app"
cp -R "build/Build/Products/Release/Space Manager.app" /Applications/
open "/Applications/Space Manager.app"
