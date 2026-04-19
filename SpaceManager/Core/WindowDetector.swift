//
//  WindowDetector.swift
//  SpaceManager
//
//  Detects which application windows are visible on the current space
//  and builds a mapping of space ID -> windows over time.
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

    private func getOnScreenWindows() -> [SpaceWindow] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var windows: [SpaceWindow] = []

        for info in windowInfoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            if Self.ignoredOwners.contains(ownerName) { continue }

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

            let window = SpaceWindow(
                windowID: windowID,
                ownerName: ownerName,
                ownerPID: ownerPID,
                windowTitle: title,
                bounds: bounds,
                isOnScreen: isOnScreen)

            windows.append(window)
        }

        return windows
    }
}
