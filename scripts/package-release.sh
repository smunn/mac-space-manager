#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/xcode-environment.sh"
configure_xcode_environment

for command in xcodegen xcodebuild codesign ditto node; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done

VERSION="$(node -p "require('./package.json').version")"
PROJECT_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION: "\([^"]*\)"/\1/p' project.yml)"

if [[ "$VERSION" != "$PROJECT_VERSION" ]]; then
    echo "Version mismatch: package.json is $VERSION but project.yml is $PROJECT_VERSION" >&2
    exit 1
fi

APP_PATH="$ROOT_DIR/build/Build/Products/Release/Space Manager.app"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/Space-Manager-v$VERSION.zip"

xcodegen generate

BUILD_ARGUMENTS=(
    -project SpaceManager.xcodeproj
    -scheme SpaceManager
    -configuration Release
    -derivedDataPath build
    -destination generic/platform=macOS
    clean build
)

xcodebuild "${BUILD_ARGUMENTS[@]}"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Created $ZIP_PATH"
