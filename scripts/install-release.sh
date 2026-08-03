#!/bin/bash

set -euo pipefail

REPOSITORY="smunn/mac-space-manager"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

for command in gh ditto; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done

if ! TAG="$(gh release view --repo "$REPOSITORY" --json tagName --jq '.tagName' 2>/dev/null)"; then
    echo "No GitHub release is available for $REPOSITORY." >&2
    exit 1
fi
ASSET_NAME="Space-Manager-$TAG.zip"

gh release download "$TAG" \
    --repo "$REPOSITORY" \
    --pattern "$ASSET_NAME" \
    --dir "$TEMP_DIR"

ditto -x -k "$TEMP_DIR/$ASSET_NAME" "$TEMP_DIR/unpacked"

APP_PATH="$TEMP_DIR/unpacked/Space Manager.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "The release does not contain Space Manager.app." >&2
    exit 1
fi

pkill -9 -x "Space Manager" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/Space Manager.app"
cp -R "$APP_PATH" /Applications/
open "/Applications/Space Manager.app"

echo "Installed Space Manager $TAG"
