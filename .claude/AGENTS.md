# SM Space Manager

macOS menu bar app for managing Spaces (virtual desktops). Built with AppKit, uses Core Graphics private APIs for space detection and Mission Control accessibility actions for space lifecycle management.

## Build & Deploy

**Always rebuild and deploy after making changes.** Do not leave the user with unbuilt code.

```bash
# 1. Regenerate Xcode project (sources auto-discovered from SpaceManager/ directory)
xcodegen generate

# 2. Build
xcodebuild -project SpaceManager.xcodeproj -scheme SpaceManager -configuration Debug build

# 3. Kill existing instance and relaunch
pkill -f "Space Manager" 2>/dev/null; sleep 0.5
open ~/Library/Developer/Xcode/DerivedData/SpaceManager-*/Build/Products/Debug/Space\ Manager.app
```

If the build fails, fix the issue and retry before moving on.

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
