# SM Space Manager

A macOS menu bar app that auto-detects Spaces, names them by their window contents, and lets you switch between them.

## What It Does

- Detects all macOS Spaces across displays via Core Graphics private APIs
- Shows current space number in the menu bar
- Dropdown lists every space with auto-generated names and app lists
- Click a space to switch to it (uses arrow-key chaining — no "Switch to Desktop N" shortcuts required)
- Rename spaces manually; names persist across rearranges and reboots
- Rename the current space from scripts via `spacemanager://rename-current?name=Project`
- Toggle "Open at login" from Settings
- Create a new empty space or a starter Terminal space from the menu
- Auto-names spaces based on: Xcode project names, Cursor/VS Code folder names, terminal working directories, Chrome profile/page context
- Attach a persistent floating task label to each Space
- Move the frontmost window to a labeled Space from a global keyboard chooser

## Reference Project

Core space detection and switching code adapted from **[Spaceman](https://github.com/ruittenb/Spaceman)** by Sasindu Jayasinghe and René Uittenbogaard (MIT License). Spaceman solves the hard problems — private API bridging for space enumeration, handling ID reassignment on wake/reboot, and reading keyboard shortcuts from system prefs. This project builds on that foundation with auto-naming, window-to-space mapping, and a different UI approach.

Key Spaceman files referenced during development:
- `SpaceObserver.swift` — `CGSCopyManagedDisplaySpaces()` usage, multi-strategy ID matching
- `SpaceSwitcher.swift` — AppleScript keystroke simulation, chained arrow navigation
- `ShortcutHelper.swift` — reading `com.apple.symbolichotkeys` for desktop shortcuts
- `Space.swift` — space data model and switch index mapping

## Permissions Required

The app shows permission status in Settings.

| Permission | Purpose | Required? |
|---|---|---|
| **Accessibility** | Simulate keyboard shortcuts to switch spaces | Yes |
| **Automation (System Events)** | Execute AppleScript keystrokes | Yes |
| **Screen Recording** | Read window titles from other apps (`kCGWindowName`) | Yes, for auto-naming |

**Important:** After granting Screen Recording, you must quit and relaunch the app. If permissions show `-` after granting, the app's code signature may have changed (e.g., after a rebuild). Run `tccutil reset Accessibility com.smunn.SpaceManager && tccutil reset ScreenCapture com.smunn.SpaceManager && tccutil reset AppleEvents com.smunn.SpaceManager` then re-grant.

## Architecture

```
SpaceManager/
├── App/
│   ├── SpaceManagerApp.swift          # @main SwiftUI entry
│   └── AppDelegate.swift              # Orchestrates subsystems
├── Core/
│   ├── SpaceObserver.swift            # Space detection (CGSCopyManagedDisplaySpaces)
│   ├── SpaceSwitcher.swift            # Space switching (AppleScript + arrow chaining)
│   ├── ShortcutHelper.swift           # Reads keyboard shortcuts from macOS prefs
│   ├── WindowDetector.swift           # Maps windows to spaces via CGWindowListCopyWindowInfo
│   ├── SpaceNamer.swift               # Auto-naming from window titles + process CWDs
│   ├── WorkspaceAutomation.swift      # Space templates built from Mission Control + app launch actions
│   └── DisplayGeometryUtilities.swift # Multi-display ordering
├── Models/
│   ├── Space.swift                    # Space data model
│   ├── SpaceWindow.swift              # Window info (app, title, PID, bounds)
│   ├── SpaceNameInfo.swift            # Persisted name + override flag
│   └── DisplayDirection.swift         # Display sort enums
├── Views/
│   ├── StatusBarController.swift      # NSMenu-based menu bar UI
│   └── SpaceLabelController.swift     # Per-Space floating task labels
├── Utilities/
│   ├── SpaceNameStore.swift           # UserDefaults persistence
│   ├── SpaceLabelStore.swift          # Label profiles, themes, and positions
│   ├── ProcessHelper.swift            # Terminal shell CWD resolution (async + cached)
│   ├── AppPermissions.swift           # Permission checks + System Settings links
│   ├── LaunchAtLoginManager.swift     # SMAppService open-at-login wrapper
│   └── Extensions.swift
├── Resources/
│   ├── Info.plist
│   ├── SpaceManager.entitlements
│   └── Assets.xcassets/
└── SpaceManager-Bridging-Header.h     # Private CG API declarations
```

## How It Works

### Settings
The Settings window is opened from the menu bar item. It currently manages:
- Open at login (`SMAppService.mainApp`)
- Permission status and System Settings links

### Space Detection
Uses `CGSCopyManagedDisplaySpaces()` (private Core Graphics API declared in the bridging header) to enumerate all spaces. Handles three scenarios with different matching strategies:
- **Normal operation** — ID-based matching tracks user rearranges
- **Wake/reboot** — position-based matching handles macOS ID reassignment
- **Display topology change** — ID-first with position fallback

### Window-to-Space Mapping
`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` snapshots visible windows when a space becomes active. The mapping builds up over time as you visit spaces. Only the current space's windows are known on first launch.

### Auto-Naming Priority
1. Xcode project name (parsed from "ProjectName — file.swift" window title)
2. Cursor / VS Code folder name (parsed from "file — FolderName" title)
3. Terminal CWD (resolved via process tree: `pgrep` child PIDs + `lsof` for CWD)
4. Chrome profile name (parsed from "Page - Profile - Google Chrome" title)
5. Dominant app name if single app
6. Top 2 app names
7. "Space N" fallback

### Space Switching
Reads macOS keyboard shortcuts from `com.apple.symbolichotkeys`. If "Switch to Desktop N" shortcuts are configured (IDs 118–132), uses direct switching. Otherwise falls back to arrow-key chaining — sends Ctrl+Left/Right repeatedly, waiting for `activeSpaceDidChangeNotification` between each step.

### Name Persistence
User-overridden names are stored in UserDefaults keyed by macOS space ID (`ManagedSpaceID`). The `isUserOverride` flag distinguishes manual names from auto-generated ones. Clearing an override reverts to auto-detection.

### Script API
Space Manager registers the `spacemanager://` URL scheme for simple script integration.

```bash
# Rename the currently active space
open "spacemanager://rename-current?name=WGU"

# Clear its name override and restore a random wallpaper from the configured folder
open "spacemanager://reset-current"

# Clear the current space's manual name
open "spacemanager://clear-current-name"

# Refresh detected spaces
open "spacemanager://refresh"

# Open Settings
open "spacemanager://settings"
```

### Space Labels

Use **Current Label...** or **Control-Option-Command-L** to edit the current Space's floating task label. Labels retain their theme, handle side, and screen position when loaded again from recent labels.

Use **Move Frontmost Window...** or **Control-Option-Command-M** to open the Space chooser. Press a displayed Space number or select its menu item to move the focused window.

For a project name that may contain spaces or special characters, URL-encode the name first:

```bash
name=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "My Project")
open "spacemanager://rename-current?name=${name}"
```

### Workspace Automation
macOS does not expose a public API for "create a desktop, name it, and assign windows to it." Space Manager composes available mechanisms:
- Mission Control accessibility actions create or close Spaces.
- Mission Control button clicks switch to a target Desktop.
- `NSWorkspace` launches apps after the app has switched Spaces.
- The script API applies the stored Space Manager name after creation.

The first template is **New > Terminal Space**, which creates a desktop, switches to it, then launches Terminal. More templates can build on the same sequence with app-specific launch commands.

## Build & Deploy

Requires [xcodegen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project from `project.yml`.

```bash
# Generate Xcode project (after modifying project.yml or adding files)
xcodegen generate

# Build and deploy to /Applications
npm run deploy

# The deploy script:
# 1. Builds Release config with local derivedDataPath
# 2. Kills running instance
# 3. Copies .app to /Applications
# 4. Launches the app
```

Do not run Space Manager from DerivedData. Always launch `/Applications/Space Manager.app` after changes so macOS permissions, URL scheme ownership, login item registration, and automation trust all point at the same app bundle.

The app is signed with `Apple Development: Scott Munn` to maintain a stable code signature across rebuilds, preserving macOS permission grants.

## Known Limitations

- Window titles require Screen Recording permission — without it, only generic app names are available
- Terminal CWD detection works best with single-window terminal apps; Terminal.app shares one PID across all windows, so CWD resolution may return any shell's directory
- Window mapping only knows spaces you've visited since launch
- No "Switch to Desktop N" shortcuts configured by default on macOS — the app uses arrow-key chaining which is slightly slower for distant spaces

## License

MIT — see [LICENSE](LICENSE). Portions adapted from [Spaceman](https://github.com/ruittenb/Spaceman) (MIT).
