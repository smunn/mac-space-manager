//
//  MissionControlAccessibility.swift
//  SpaceManager
//
//  Describes the undocumented accessibility hierarchy used by Mission Control.
//

import Foundation

enum MissionControlAccessibility {
    /// macOS 27 moved Mission Control's accessibility elements from Dock.app to
    /// WindowManager. The visible hierarchy also lost the intermediate group named
    /// "Mission Control". Neither hierarchy is public API, so keep both paths until
    /// the app no longer supports pre-macOS 27 releases.
    static var usesWindowManagerTree: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    static func appendProcessStart(to lines: inout [String]) {
        lines.append("tell application \"System Events\"")

        if usesWindowManagerTree {
            lines.append("  tell process \"WindowManager\"")
        } else {
            lines.append("  tell process \"Dock\"")
            lines.append("    tell group \"Mission Control\"")
        }
    }

    static func appendProcessEnd(to lines: inout [String]) {
        if !usesWindowManagerTree {
            lines.append("    end tell")
        }

        lines.append("  end tell")
    }
}
