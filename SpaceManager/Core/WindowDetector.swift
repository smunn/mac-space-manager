//
//  WindowDetector.swift
//  SpaceManager
//
//  Detects which application windows exist on each macOS Space.
//
//  Uses CGSCopySpacesForWindows (private API) to map every window to its
//  space without switching desktops. This gives accurate, real-time data
//  for ALL spaces in a single pass.
//

import Cocoa
import Foundation

class WindowDetector {
    private var windowsBySpaceID: [String: [SpaceWindow]] = [:]
    private let lock = NSLock()

    private static let ignoredOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "Spotlight", "WindowManager",
        "Space Manager"
    ]

    /// Snapshots windows across ALL spaces using CGSCopySpacesForWindows.
    /// Replaces any cached data with a complete, fresh mapping.
    func snapshotAllSpaces() {
        let mapping = Self.detectWindowsPerSpace()
        lock.lock()
        windowsBySpaceID = mapping
        lock.unlock()
    }

    /// Snapshots only the current space via on-screen window detection.
    /// Faster but only accurate for the active space.
    func snapshotCurrentSpace(spaceID: String) {
        let windows = getOnScreenWindows()
        lock.lock()
        windowsBySpaceID[spaceID] = windows
        lock.unlock()
    }

    func windows(for spaceID: String) -> [SpaceWindow] {
        lock.lock()
        defer { lock.unlock() }
        return windowsBySpaceID[spaceID] ?? []
    }

    func allMappings() -> [String: [SpaceWindow]] {
        lock.lock()
        defer { lock.unlock() }
        return windowsBySpaceID
    }

    func clearMapping(for spaceID: String) {
        lock.lock()
        windowsBySpaceID.removeValue(forKey: spaceID)
        lock.unlock()
    }

    // MARK: - All-Spaces Detection

    /// Queries every window on the system and maps each to its space(s)
    /// using the private CGSCopySpacesForWindows API. Returns a fresh
    /// mapping without modifying any stored state.
    static func detectWindowsPerSpace() -> [String: [SpaceWindow]] {
        let conn = _CGSDefaultConnection()

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var mapping: [String: [SpaceWindow]] = [:]

        for info in windowInfoList {
            guard let window = parseWindow(info) else { continue }

            let windowIDCF = [CGWindowID(window.windowID)] as CFArray
            guard let spacesCF = CGSCopySpacesForWindows(conn, 0x7, windowIDCF) else { continue }
            let spaceIDs = spacesCF.takeRetainedValue() as? [NSNumber] ?? []

            for num in spaceIDs {
                let key = String(num.intValue)
                mapping[key, default: []].append(window)
            }
        }

        return mapping
    }

    // MARK: - Current-Space Detection

    private func getOnScreenWindows() -> [SpaceWindow] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windowInfoList.compactMap { Self.parseWindow($0) }
    }

    // MARK: - Parsing

    private static func parseWindow(_ info: [String: Any]) -> SpaceWindow? {
        guard let ownerName = info[kCGWindowOwnerName as String] as? String,
              let windowID = info[kCGWindowNumber as String] as? Int,
              let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0
        else { return nil }

        if ignoredOwners.contains(ownerName) { return nil }

        let title = info[kCGWindowName as String] as? String ?? ""

        var bounds = CGRect.zero
        if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
            let x = boundsDict["X"] as? CGFloat ?? 0
            let y = boundsDict["Y"] as? CGFloat ?? 0
            let w = boundsDict["Width"] as? CGFloat ?? 0
            let h = boundsDict["Height"] as? CGFloat ?? 0
            bounds = CGRect(x: x, y: y, width: w, height: h)
        }

        let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true

        return SpaceWindow(
            windowID: windowID,
            ownerName: ownerName,
            ownerPID: ownerPID,
            windowTitle: title,
            bounds: bounds,
            isOnScreen: isOnScreen)
    }
}
