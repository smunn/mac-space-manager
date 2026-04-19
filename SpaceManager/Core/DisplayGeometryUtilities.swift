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
        let uuid = CFUUIDCreateFromString(kCFAllocatorDefault, uuidString as CFString)
        let did = CGDisplayGetDisplayIDFromUUID(uuid)
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
}
