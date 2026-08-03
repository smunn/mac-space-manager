#!/bin/bash

configure_xcode_environment() {
    if xcodebuild -version >/dev/null 2>&1; then
        return
    fi

    local xcode_path
    for xcode_path in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -d "$xcode_path" ]]; then
            export DEVELOPER_DIR="$xcode_path/Contents/Developer"
            return
        fi
    done

    echo "Xcode is required. Install Xcode or set DEVELOPER_DIR." >&2
    return 1
}
