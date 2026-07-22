//
//  MissionControlAccessibility.swift
//  SpaceManager
//
//  Direct Accessibility access to Mission Control's undocumented UI hierarchy.
//

import Cocoa
import ApplicationServices

enum MissionControlAccessibility {
    struct DisplaySnapshot {
        let displayID: String?
        let desktopButtons: [AXUIElement]
        let addButton: AXUIElement?
    }

    private static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static let removeDesktopAction = "AXRemoveDesktop" as CFString
    private static let pollInterval: TimeInterval = 0.05
    private static let appearanceTimeout: TimeInterval = 3.0
    private static let mutationTimeout: TimeInterval = 2.5
    static let operationQueue = DispatchQueue(
        label: "com.smunn.SpaceManager.MissionControlOperations",
        qos: .userInitiated)

    static func open() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: missionControlURL,
            configuration: configuration,
            completionHandler: { _, error in
                if let error {
                    NSLog("MissionControlAccessibility: launch request failed: \(error)")
                    SpaceOperationLog.write("Mission Control launch request failed: \(error)")
                }
            })
    }

    /// Opens Mission Control with NSWorkspace rather than an Apple event, then waits
    /// for its accessibility elements to appear. macOS 27 moved these elements from
    /// Dock.app to WindowManager and added identifiers such as `mc.spaces`; older
    /// releases expose a named hierarchy under Dock. Both remain undocumented.
    static func openAndWaitForDisplaySnapshots() -> [DisplaySnapshot]? {
        for attempt in 1...2 {
            open()
            if let snapshots = waitForSnapshots(
                timeout: appearanceTimeout,
                predicate: { !$0.isEmpty })
            {
                SpaceOperationLog.write(
                    "Mission Control ready attempt=\(attempt) displays=\(snapshots.count) snapshots=\(snapshots.map { "\($0.displayID ?? "unknown"):\($0.desktopButtons.count)" })")
                return snapshots
            }
        }
        SpaceOperationLog.write("Mission Control hierarchy unavailable after 2 attempts")
        return nil
    }

    static func currentDisplaySnapshots() -> [DisplaySnapshot] {
        for bundleIdentifier in accessibilityOwnerBundleIdentifiers {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            }) else { continue }

            let root = AXUIElementCreateApplication(app.processIdentifier)

            // WindowManager exposes one `mc.display` container per physical display on
            // macOS 27. Its child order does not match CGSCopyManagedDisplaySpaces, so
            // retain the stable Core Graphics display identity carried by AXDisplayID.
            let displayGroups = descendants(of: root, maximumDepth: 2).filter {
                identifier(of: $0) == "mc.display"
            }
            let identifiedSnapshots = displayGroups.compactMap(snapshot(forDisplayGroup:))
            if !identifiedSnapshots.isEmpty {
                return identifiedSnapshots
            }

            // Older macOS releases expose the Spaces bars under Dock without an
            // `mc.display` container or AXDisplayID. Preserve ordinal lookup there.
            let spacesBars = descendants(of: root, maximumDepth: 6).filter(isSpacesBar)
            let snapshots = spacesBars.compactMap {
                snapshot(forSpacesBar: $0, displayID: nil)
            }
            if !snapshots.isEmpty {
                return snapshots
            }
        }

        return []
    }

    static func snapshot(
        in snapshots: [DisplaySnapshot],
        displayID: String,
        fallbackDisplayGroupIndex: Int
    ) -> DisplaySnapshot? {
        if let identified = snapshots.first(where: { $0.displayID == displayID }) {
            return identified
        }

        // Only fall back to the undocumented ordinal hierarchy when the platform
        // supplies no display identities at all. Falling back after a UUID mismatch
        // could mutate a Space on the wrong monitor.
        guard snapshots.allSatisfy({ $0.displayID == nil }),
              snapshots.indices.contains(fallbackDisplayGroupIndex - 1)
        else { return nil }
        return snapshots[fallbackDisplayGroupIndex - 1]
    }

    static func waitForDesktopCount(
        displayID: String,
        displayGroupIndex: Int,
        timeout: TimeInterval = mutationTimeout,
        predicate: @escaping (Int) -> Bool
    ) -> [DisplaySnapshot]? {
        waitForSnapshots(timeout: timeout) { snapshots in
            guard let snapshot = snapshot(
                in: snapshots,
                displayID: displayID,
                fallbackDisplayGroupIndex: displayGroupIndex)
            else { return false }
            return predicate(snapshot.desktopButtons.count)
        }
    }

    static func performPress(on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func performRemoveDesktop(on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, removeDesktopAction) == .success
    }

    static func dismiss() {
        postKey(keyCode: 53, flags: [])
    }

    @discardableResult
    static func postKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            NSLog("MissionControlAccessibility: could not create keyboard event for key code \(keyCode)")
            SpaceOperationLog.write("Could not create keyboard event keyCode=\(keyCode) flags=\(flags.rawValue)")
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static var accessibilityOwnerBundleIdentifiers: [String] {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return ["com.apple.WindowManager", "com.apple.dock"]
        }
        return ["com.apple.dock", "com.apple.WindowManager"]
    }

    private static func waitForSnapshots(
        timeout: TimeInterval,
        predicate: ([DisplaySnapshot]) -> Bool
    ) -> [DisplaySnapshot]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let snapshots = currentDisplaySnapshots()
            if predicate(snapshots) {
                return snapshots
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline

        return nil
    }

    private static func snapshot(forDisplayGroup displayGroup: AXUIElement) -> DisplaySnapshot? {
        guard let spacesBar = descendants(of: displayGroup, maximumDepth: 2).first(where: isSpacesBar)
        else { return nil }

        return snapshot(
            forSpacesBar: spacesBar,
            displayID: displayUUID(for: displayGroup))
    }

    private static func snapshot(
        forSpacesBar spacesBar: AXUIElement,
        displayID: String?
    ) -> DisplaySnapshot? {
        let allDescendants = descendants(of: spacesBar, maximumDepth: 3)
        guard let list = allDescendants.first(where: {
            identifier(of: $0) == "mc.spaces.list" || role(of: $0) == kAXListRole as String
        }) else { return nil }

        let desktopButtons = children(of: list).filter { element in
            guard role(of: element) == kAXButtonRole as String else { return false }
            let actions = actionNames(of: element)
            return actions.contains(removeDesktopAction as String)
                || title(of: element) == "Desktop"
                || title(of: element)?.hasPrefix("Desktop ") == true
        }

        let identifiedAddButton = allDescendants.first(where: { element in
            if identifier(of: element) == "mc.spaces.add" { return true }
            guard role(of: element) == kAXButtonRole as String else { return false }
            return description(of: element) == "add desktop"
        })
        let addButton = identifiedAddButton ?? children(of: spacesBar).first(where: {
            role(of: $0) == kAXButtonRole as String
        })

        return DisplaySnapshot(
            displayID: displayID,
            desktopButtons: desktopButtons,
            addButton: addButton)
    }

    private static func displayUUID(for displayGroup: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            displayGroup,
            "AXDisplayID" as CFString,
            &value) == .success,
            let number = value as? NSNumber
        else { return nil }

        let directDisplayID = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private static func isSpacesBar(_ element: AXUIElement) -> Bool {
        identifier(of: element) == "mc.spaces" || title(of: element) == "Spaces Bar"
    }

    private static func descendants(of element: AXUIElement, maximumDepth: Int) -> [AXUIElement] {
        guard maximumDepth > 0 else { return [] }
        let directChildren = children(of: element)
        return directChildren + directChildren.flatMap {
            descendants(of: $0, maximumDepth: maximumDepth - 1)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value) == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute as CFString, of: element)
    }

    private static func title(of element: AXUIElement) -> String? {
        stringAttribute(kAXTitleAttribute as CFString, of: element)
    }

    private static func description(of element: AXUIElement) -> String? {
        stringAttribute(kAXDescriptionAttribute as CFString, of: element)
    }

    private static func identifier(of element: AXUIElement) -> String? {
        stringAttribute(kAXIdentifierAttribute as CFString, of: element)
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
}
