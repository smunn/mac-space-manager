# SM Space Manager - Project Specs

## Overview

A macOS menu bar application that automatically detects macOS Spaces (virtual desktops), identifies the windows and projects within each space, generates descriptive names, and allows quick switching between spaces via a dropdown menu.

## Motivation

macOS Spaces have no native naming or identification system beyond their numeric order. When working across multiple projects — each in its own space — there's no quick way to see "what's where" or jump to a specific project's space. This app solves that by auto-detecting window contents and presenting a named, clickable list in the menu bar.

## Core Features

### Phase 1 — MVP

1. **Space Detection**: Detect all macOS Spaces across all displays using Core Graphics private APIs (adapted from [Spaceman](https://github.com/ruittenb/Spaceman), MIT license).

2. **Window-to-Space Mapping**: Detect which windows belong to which space. Uses `CGWindowListCopyWindowInfo` to snapshot on-screen windows when a space becomes active, building up a map over time.

3. **Auto-Naming**: Automatically name spaces based on their contents:
   - Xcode projects: use project name
   - Cursor / VS Code: parse window title for project/folder name
   - Terminal / iTerm: parse window title for current directory
   - Single dominant app: use app name (e.g., "Mail", "Slack")
   - Mixed: "App1, App2" (top 2-3 apps)
   - Empty/unknown: "Space N"

4. **Menu Bar Dropdown**: Click the menu bar icon to see all spaces listed with:
   - Space number
   - Auto-generated (or user-overridden) name
   - List of apps in that space
   - Checkmark on current space
   - Click to switch

5. **Space Switching**: Switch spaces via simulated keyboard shortcuts (AppleScript + System Events), adapted from Spaceman.

### Phase 2 — Enhancements

6. **Manual Name Overrides**: Right-click a space in the menu to assign a custom name that persists across sessions.

7. **`work` Command Integration**: Expose current space info via CLI or AppleScript so the `work` shell function can query/switch spaces.

8. **Preferences Window**: Configure auto-naming rules, display ordering, launch at login.

9. **Keyboard Shortcuts**: Global hotkeys to switch to specific named spaces.

### Phase 3 — Polish

10. **Space Icons**: Show app icons next to space names in the dropdown.
11. **Notifications**: Optional notification when switching spaces.
12. **Multiple Display Support**: Show per-display space groupings.

## Architecture

```
SpaceManager/
├── App/
│   ├── SpaceManagerApp.swift      # @main entry, SwiftUI lifecycle
│   └── AppDelegate.swift          # NSApplicationDelegate, orchestrates subsystems
├── Core/
│   ├── SpaceObserver.swift        # Detects spaces via CGSCopyManagedDisplaySpaces
│   ├── SpaceSwitcher.swift        # Switches spaces via AppleScript keystrokes
│   ├── ShortcutHelper.swift       # Reads keyboard shortcuts from macOS prefs
│   ├── WindowDetector.swift       # Maps windows to spaces
│   ├── SpaceNamer.swift           # Auto-generates space names from window info
│   └── DisplayGeometryUtilities.swift # Display ordering helpers
├── Models/
│   ├── Space.swift                # Core space data model
│   ├── SpaceWindow.swift          # Window info (app name, title, bounds)
│   └── SpaceNameInfo.swift        # Persisted name data
├── Views/
│   ├── StatusBarController.swift  # NSMenu-based menu bar dropdown
│   └── PreferencesView.swift      # SwiftUI preferences window
├── Utilities/
│   ├── SpaceNameStore.swift       # UserDefaults persistence
│   └── Extensions.swift           # Helper extensions
├── Resources/
│   ├── Info.plist
│   ├── SpaceManager.entitlements
│   └── Assets.xcassets/
└── SpaceManager-Bridging-Header.h # Private CG API declarations
```

## Technical Approach

### Space Detection (from Spaceman)
- Uses `CGSCopyManagedDisplaySpaces()` private API to enumerate all spaces
- Handles space ID reassignment on wake/reboot with position-based fallback
- Listens for `NSWorkspace.activeSpaceDidChangeNotification`
- Handles display topology changes (connect/disconnect monitors)

### Window Detection (new)
- On space change: snapshot visible windows via `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`
- Store mapping: space ID -> [SpaceWindow]
- Parse window titles for project context (Xcode, Cursor, VS Code, Terminal)
- Refresh periodically and on app activation events

### Auto-Naming (new)
Priority-based naming from window contents:
1. IDE projects (Xcode `.xcodeproj`, Cursor/VS Code folder name)
2. Single dominant app (>50% of windows)
3. Top 2-3 app names
4. Fallback: "Space N"

### Space Switching (from Spaceman)
- Reads `com.apple.symbolichotkeys` for Switch to Desktop N shortcuts
- Executes via `NSAppleScript("tell app System Events to key code...")`
- Supports chained arrow-key navigation for spaces beyond shortcut limit

## Permissions Required

- **Accessibility**: For simulating keyboard shortcuts to switch spaces
- **Automation (System Events)**: For AppleScript-based space switching
- **Screen Recording** (optional): For `CGWindowListCopyWindowInfo` to get window titles from other apps

## Dependencies

- None (pure AppKit/SwiftUI, no third-party packages for MVP)

## Attribution

Core space detection and switching code adapted from [Spaceman](https://github.com/ruittenb/Spaceman) by Sasindu Jayasinghe and Rene Uittenbogaard, licensed under MIT.

## Build Requirements

- macOS 13 Ventura or later
- Xcode 15+
- Swift 5.9+
