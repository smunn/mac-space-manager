#!/bin/bash

set -euo pipefail

REPOSITORY="smunn/mac-space-manager"
APP_PATH="/Applications/Space Manager.app"
PLIST_PATH="$APP_PATH/Contents/Info.plist"

if ! command -v gh >/dev/null 2>&1; then
    echo "Missing required command: gh" >&2
    exit 1
fi

if ! LATEST_TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq '.tagName' 2>/dev/null)"; then
    echo "No GitHub release is available for $REPOSITORY." >&2
    exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"

if [[ ! -f "$PLIST_PATH" ]]; then
    echo "Space Manager is not installed. Latest release: $LATEST_TAG"
    exit 1
fi

INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"

if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
    echo "Space Manager is up to date ($LATEST_TAG)."
    exit 0
fi

echo "Space Manager is not up to date. Installed: v$INSTALLED_VERSION. Latest: $LATEST_TAG."
exit 1
