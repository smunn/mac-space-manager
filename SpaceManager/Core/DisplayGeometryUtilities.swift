//
//  DisplayGeometryUtilities.swift
//  SpaceManager
//
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

class DisplayGeometryUtilities {
    static func getDisplayCenter(display: NSDictionary) -> CGPoint {
        guard let uuidString = display["Display Identifier"] as? String else { return .zero }
        let did = displayID(for: uuidString)
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(num.uint32Value) == did {
                let frame = screen.frame
                return CGPoint(x: frame.origin.x + frame.size.width / 2, y: frame.origin.y + frame.size.height / 2)
            }
        }
        let bounds = CGDisplayBounds(did)
        return CGPoint(x: bounds.origin.x + bounds.size.width / 2, y: bounds.origin.y + bounds.size.height / 2)
    }

    static func displayID(for uuidString: String) -> CGDirectDisplayID {
        let uuid = CFUUIDCreateFromString(kCFAllocatorDefault, uuidString as CFString)
        return CGDisplayGetDisplayIDFromUUID(uuid)
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = unmanaged.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(for uuidString: String) -> NSScreen? {
        let did = displayID(for: uuidString)
        return NSScreen.screens.first { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(num.uint32Value) == did
        }
    }

    static func displayName(for uuidString: String) -> String {
        screen(for: uuidString)?.localizedName ?? "Display"
    }

    static func displayUUID(containing point: CGPoint, candidates: [String]) -> String? {
        for candidate in candidates {
            guard let screen = screen(for: candidate) else { continue }
            if screen.frame.contains(point) {
                return candidate
            }
        }
        return nil
    }

    /// Returns the display UUID that has keyboard focus, matched against known UUIDs.
    /// Uses NSScreen.main which tracks the screen with the key window.
    static func activeDisplayUUID(from candidates: [String]) -> String? {
        guard let mainScreen = NSScreen.main,
              let num = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let mainID = CGDirectDisplayID(num.uint32Value)
        return candidates.first { displayID(for: $0) == mainID }
    }
}
