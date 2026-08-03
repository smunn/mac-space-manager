#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/xcode-environment.sh"
configure_xcode_environment

if [[ $# -ne 1 ]]; then
    echo "Usage: npm run release -- <patch|minor|major|version>" >&2
    exit 1
fi

VERSION_SPEC="$1"

for command in git gh npm node; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done
gh auth status >/dev/null

if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "Releases must be created from main." >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "The working tree must be clean before creating a release." >&2
    exit 1
fi

git fetch origin

LOCAL_HEAD="$(git rev-parse HEAD)"
REMOTE_HEAD="$(git rev-parse origin/main)"
if [[ "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
    echo "main must exactly match origin/main before creating a release." >&2
    exit 1
fi

CHANGES_PENDING=1
restore_version_files() {
    if [[ "$CHANGES_PENDING" == "1" ]]; then
        git restore package.json project.yml
    fi
}
trap restore_version_files ERR INT TERM

npm version "$VERSION_SPEC" --no-git-tag-version
VERSION="$(node -p "require('./package.json').version")"
node scripts/sync-project-version.mjs "$VERSION"

TAG="v$VERSION"
if git rev-parse "$TAG" >/dev/null 2>&1 || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Tag already exists: $TAG" >&2
    exit 1
fi

npm run package

ARTIFACT="$ROOT_DIR/dist/Space-Manager-$TAG.zip"

git add package.json project.yml
git commit -m "Release $TAG"
git tag -a "$TAG" -m "Release $TAG"
CHANGES_PENDING=0
trap - ERR INT TERM

git push --atomic origin main "$TAG"
gh release create "$TAG" "$ARTIFACT" \
    --title "Space Manager $TAG" \
    --generate-notes \
    --verify-tag

echo "Published Space Manager $TAG"
