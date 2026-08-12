//
//  SpaceTransfer.swift
//  SpaceManager
//
//  Moves windows between displays using the Accessibility API,
//  and optionally copies wallpaper via NSWorkspace.
//

import Cocoa

class SpaceTransfer {

    struct ManagedSpaceAssignment {
        let window: SpaceWindow
        let targetSpaceID: String
        let targetFrame: CGRect
    }

    /// Moves individual windows to existing managed Spaces and verifies the result.
    /// Current macOS releases require the private bridged SkyLight operation; older
    /// releases fall back to CGSMoveWindowsToManagedSpace. Neither API is supported
    /// by Apple, so each move is checked through CGSCopySpacesForWindows.
    static func moveWindowsToManagedSpaces(_ assignments: [ManagedSpaceAssignment]) -> Int {
        var movedCount = 0

        for assignment in assignments {
            guard let targetSpaceID = UInt64(assignment.targetSpaceID) else { continue }
            let windowID = CGWindowID(assignment.window.windowID)
            // Normalize the frame while the source Space is still visible. AX can
            // stop enumerating a Terminal window immediately after SkyLight moves
            // it to a hidden Space, which previously preserved off-screen monitor
            // coordinates and left the window below the MacBook display.
            guard fillWindow(assignment.window, in: assignment.targetFrame) else {
                SpaceOperationLog.write(
                    "Terminal organization resize failed before move window=\(windowID)")
                continue
            }
            let windowIDs = [windowID] as CFArray
            let usedModernOperation = SMMoveWindowsToManagedSpaceModern(windowIDs, targetSpaceID) == 1
            if !usedModernOperation {
                CGSMoveWindowsToManagedSpace(
                    _CGSDefaultConnection(),
                    windowIDs,
                    targetSpaceID)
            }

            if waitForWindow(windowID, toReachSpaceID: assignment.targetSpaceID) {
                movedCount += 1
            } else {
                SpaceOperationLog.write(
                    "Terminal organization move or resize failed window=\(windowID) target=\(targetSpaceID)")
            }
        }

        return movedCount
    }

    static func fillWindows(_ windows: [SpaceWindow], in targetFrame: CGRect) -> Int {
        windows.reduce(into: 0) { filledCount, window in
            if fillWindow(window, in: targetFrame) {
                filledCount += 1
            }
        }
    }

    static func fillWindowsOnSpaces(
        _ assignments: [(window: SpaceWindow, displayID: String, displayGroup: Int, desktopIndex: Int)],
        targetFrame: CGRect
    ) -> Int {
        var filledCount = 0
        for assignment in assignments {
            guard SpaceCloser.focusDesktopSynchronously(
                displayID: assignment.displayID,
                displayGroupIndex: assignment.displayGroup,
                desktopIndex: assignment.desktopIndex)
            else { continue }
            if fillWindow(assignment.window, in: targetFrame) {
                filledCount += 1
            }
        }
        return filledCount
    }

    /// Moves windows from one display to another, preserving relative positions.
    /// Returns the number of windows successfully moved.
    static func transferWindows(
        _ windows: [SpaceWindow],
        fromDisplay sourceUUID: String,
        toDisplay targetUUID: String
    ) -> Int {
        let srcID = DisplayGeometryUtilities.displayID(for: sourceUUID)
        let tgtID = DisplayGeometryUtilities.displayID(for: targetUUID)
        let srcBounds = CGDisplayBounds(srcID)
        let tgtBounds = CGDisplayBounds(tgtID)

        guard srcBounds.width > 0, tgtBounds.width > 0 else { return 0 }

        var moved = 0
        let windowsByPID = Dictionary(grouping: windows, by: { $0.ownerPID })

        for (pid, pidWindows) in windowsByPID {
            let appElement = AXUIElementCreateApplication(pid)
            var axWindowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
                  let axWindows = axWindowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                guard let (pos, size) = axWindowFrame(axWindow) else { continue }

                guard pidWindows.contains(where: { sw in
                    abs(sw.bounds.origin.x - pos.x) < 3 &&
                    abs(sw.bounds.origin.y - pos.y) < 3 &&
                    abs(sw.bounds.width - size.width) < 3 &&
                    abs(sw.bounds.height - size.height) < 3
                }) else { continue }

                // Proportional mapping: preserve relative position within the display
                let relX = (pos.x - srcBounds.origin.x) / srcBounds.width
                let relY = (pos.y - srcBounds.origin.y) / srcBounds.height

                var newX = tgtBounds.origin.x + relX * tgtBounds.width
                var newY = tgtBounds.origin.y + relY * tgtBounds.height

                newX = max(tgtBounds.origin.x, min(newX, tgtBounds.maxX - size.width))
                newY = max(tgtBounds.origin.y, min(newY, tgtBounds.maxY - size.height))

                if setAXWindowPosition(axWindow, to: CGPoint(x: newX, y: newY)) {
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    moved += 1
                }
            }
        }

        return moved
    }

    /// Copies the source display's wallpaper to the target display.
    static func transferWallpaper(fromDisplay sourceUUID: String, toDisplay targetUUID: String) -> Bool {
        guard let srcScreen = DisplayGeometryUtilities.screen(for: sourceUUID),
              let tgtScreen = DisplayGeometryUtilities.screen(for: targetUUID) else { return false }

        guard let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: srcScreen) else { return false }

        do {
            try NSWorkspace.shared.setDesktopImageURL(wallpaperURL, for: tgtScreen, options: [:])
            return true
        } catch {
            NSLog("SpaceTransfer: failed to set wallpaper: \(error)")
            return false
        }
    }

    // MARK: - AX Helpers

    private static func axWindowFrame(_ window: AXUIElement) -> (CGPoint, CGSize)? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        // AXValue bridging: position and size are stored as AXValue wrappers
        guard let posRef,
              let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }

        return (pos, size)
    }

    private static func setAXWindowPosition(_ window: AXUIElement, to point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private static func waitForWindow(
        _ windowID: CGWindowID,
        toReachSpaceID targetSpaceID: String
    ) -> Bool {
        for _ in 0..<20 {
            let windowIDs = [NSNumber(value: windowID)] as CFArray
            if let spaces = CGSCopySpacesForWindows(_CGSDefaultConnection(), 0x7, windowIDs) {
                let spaceIDs = spaces.takeRetainedValue() as? [NSNumber] ?? []
                if spaceIDs.contains(where: { $0.stringValue == targetSpaceID }) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func fillWindow(_ window: SpaceWindow, in targetFrame: CGRect) -> Bool {
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue) == .success,
              let windowElements = windowsValue as? [AXUIElement],
              let windowElement = windowElements.first(where: { element in
                  var windowID = CGWindowID(0)
                  return _AXUIElementGetWindow(element, &windowID) == .success
                      && windowID == CGWindowID(window.windowID)
              })
        else { return false }

        var position = targetFrame.origin
        var size = targetFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        // AX frame changes are not atomic. Put the window at the work area's
        // top-left before resizing, then repeat both values so Terminal cannot
        // preserve an off-display bottom edge from its previous monitor.
        let initialPositionStatus = AXUIElementSetAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            sizeValue)
        let finalPositionStatus = AXUIElementSetAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            positionValue)
        _ = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)

        return initialPositionStatus == .success
            && sizeStatus == .success
            && finalPositionStatus == .success
    }
}
