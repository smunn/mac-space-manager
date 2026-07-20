//
//  SpaceTransfer.swift
//  SpaceManager
//
//  Moves windows between displays using the Accessibility API,
//  and optionally copies wallpaper via NSWorkspace.
//

import Cocoa

class SpaceTransfer {

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
}
