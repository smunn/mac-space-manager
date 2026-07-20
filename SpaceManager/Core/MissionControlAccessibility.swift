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
                    "Mission Control ready attempt=\(attempt) displays=\(snapshots.count) desktops=\(snapshots.map { $0.desktopButtons.count })")
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
            let spacesBars = descendants(of: root, maximumDepth: 6).filter(isSpacesBar)
            let snapshots = spacesBars.compactMap(snapshot(forSpacesBar:))
            if !snapshots.isEmpty {
                return snapshots
            }
        }

        return []
    }

    static func waitForDesktopCount(
        displayGroupIndex: Int,
        timeout: TimeInterval = mutationTimeout,
        predicate: @escaping (Int) -> Bool
    ) -> [DisplaySnapshot]? {
        waitForSnapshots(timeout: timeout) { snapshots in
            guard snapshots.indices.contains(displayGroupIndex - 1) else { return false }
            return predicate(snapshots[displayGroupIndex - 1].desktopButtons.count)
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

    private static func snapshot(forSpacesBar spacesBar: AXUIElement) -> DisplaySnapshot? {
        let allDescendants = descendants(of: spacesBar, maximumDepth: 3)
        guard let list = allDescendants.first(where: {
            identifier(of: $0) == "mc.spaces.list" || role(of: $0) == kAXListRole as String
        }) else { return nil }

        let desktopButtons = children(of: list).filter { element in
            guard role(of: element) == kAXButtonRole as String else { return false }
            let actions = actionNames(of: element)
            return actions.contains(removeDesktopAction as String)
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

        return DisplaySnapshot(desktopButtons: desktopButtons, addButton: addButton)
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
