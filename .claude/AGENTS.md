# SM Space Manager

macOS menu bar app for managing Spaces (virtual desktops). Built with AppKit, uses Core Graphics private APIs for space detection and Mission Control accessibility actions for space lifecycle management.

## Build & Deploy

**Always rebuild and deploy a Release app to `/Applications` after making changes.** Do not leave the user with unbuilt code.

**Never launch or leave Space Manager running from DerivedData.** Permissions, login items, URL schemes, and automation trust are tied to the signed app bundle path. Running a debug/DerivedData copy creates confusing duplicate app identities. The only acceptable running copy after changes is `/Applications/Space Manager.app`.

```bash
# 1. Regenerate Xcode project (sources auto-discovered from SpaceManager/ directory)
xcodegen generate

# 2. Build Release into the repo-local build directory
xcodebuild -project SpaceManager.xcodeproj -scheme SpaceManager -configuration Release -derivedDataPath build build

# 3. Kill any running copy, replace /Applications, and relaunch from /Applications
pkill -9 -x "Space Manager" 2>/dev/null; sleep 0.5
rm -rf "/Applications/Space Manager.app"
cp -R "build/Build/Products/Release/Space Manager.app" /Applications/
open "/Applications/Space Manager.app"
```

`npm run deploy` performs the Release build, `/Applications` install, and relaunch. Prefer it after `xcodegen generate`.

If the build fails, fix the issue and retry before moving on.

## Releases

- `npm run package` builds a universal macOS Release ZIP in `dist/`.
- `npm run release -- patch|minor|major|x.y.z` updates the version and build number, commits and tags it, pushes `main`, and publishes the ZIP in a GitHub release.
- `npm run checkRelease` compares `/Applications/Space Manager.app` with the latest GitHub release.
- `npm run installRelease` downloads the latest GitHub release, installs it in `/Applications`, and launches it.

## Project Structure

| Directory | Purpose |
|-----------|---------|
| `SpaceManager/App/` | Entry point, AppDelegate orchestration |
| `SpaceManager/Core/` | Space detection, window mapping, switching, closing |
| `SpaceManager/Models/` | Data structures (Space, SpaceWindow, SpaceNameInfo) |
| `SpaceManager/Views/` | Menu bar UI (StatusBarController) |
| `SpaceManager/Utilities/` | Storage, process helpers |

## Project Management

- `project.yml` is the source of truth (XcodeGen). Always run `xcodegen generate` after adding/removing files.
- `SpaceManager-Bridging-Header.h` declares private Core Graphics APIs.

## Private APIs

This app uses undocumented macOS APIs. Document usage thoroughly with comments explaining *why* the approach is needed and what the limitations are.

- **CGSCopyManagedDisplaySpaces** -- reads space layout (read-only, safe)
- **AXRemoveDesktop** -- closes spaces via Mission Control accessibility tree
- **Mission Control "+" button** -- adds spaces via accessibility click

## Component Identifiers (SwiftUI)

This project currently uses AppKit (NSMenu), not SwiftUI. If SwiftUI views are added:
- Page-level views: `.debugLabel("camelCaseName")`
- Singleton views: `.debugLabel("camelCaseName")`
- Reusable views: `.debugLabel("StructName")`
