//
//  WorkspaceAutomation.swift
//  SpaceManager
//
//  Higher-level space automation built on the same Mission Control accessibility
//  actions as SpaceCloser. macOS has no public API to create a named desktop or
//  assign an app to it directly, so templates have to compose UI automation:
//  create a desktop, switch to it, then launch the desired app/window.
//

import Cocoa

enum WorkspaceAutomation {
    static func createTerminalSpace(
        targetDesktopNumber: Int,
        displayGroupIndex: Int = 1,
        targetDisplayID: String,
        completion: @escaping (Bool) -> Void
    ) {
        let existingTerminalWindowIDs = Set(terminalWindowsSnapshot().map(\.windowID))

        SpaceCloser.addSpaceAndSwitch(
            toDesktopNumber: targetDesktopNumber,
            displayID: targetDisplayID,
            displayGroupIndex: displayGroupIndex
        ) { success in
            guard success else {
                completion(false)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                openTerminalWindow(
                    targetDisplayID: targetDisplayID,
                    existingWindowIDs: existingTerminalWindowIDs,
                    completion: completion)
            }
        }
    }

    private static func openTerminalWindow(
        targetDisplayID: String,
        existingWindowIDs: Set<Int>,
        completion: @escaping (Bool) -> Void
    ) {
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Activating Terminal's existing process can make macOS jump back to the
        // Space containing its last window before Command-N is posted. Launch a
        // fresh Terminal instance instead so its initial window is created on the
        // newly selected Space. There is no public API for targeting a Space when
        // opening an application window.
        configuration.createsNewApplicationInstance = true
        // A new Terminal process otherwise restores every window saved by its
        // previous process. This launch is specifically for one new Space, so
        // suppress state restoration and let Terminal create one default window.
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        NSWorkspace.shared.openApplication(
            at: terminalURL,
            configuration: configuration
        ) { application, error in
            if let error {
                NSLog("WorkspaceAutomation: could not open Terminal: \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            guard let application else {
                NSLog("WorkspaceAutomation: Terminal launch returned no running application")
                DispatchQueue.main.async { completion(false) }
                return
            }

            DispatchQueue.main.async {
                moveNewTerminalWindow(
                    ownerPID: application.processIdentifier,
                    toDisplay: targetDisplayID,
                    existingWindowIDs: existingWindowIDs
                ) { moved in
                    completion(moved)
                }
            }
        }
    }

    private static func moveNewTerminalWindow(
        ownerPID: pid_t,
        toDisplay targetDisplayID: String,
        existingWindowIDs: Set<Int>,
        attempt: Int = 1,
        completion: @escaping (Bool) -> Void
    ) {
        let windows = terminalWindowsSnapshot()
        let targetWindow = windows.first(where: {
            $0.ownerPID == ownerPID && !existingWindowIDs.contains($0.windowID)
        })

        guard let targetWindow else {
            if attempt >= 10 {
                NSLog("WorkspaceAutomation: could not find a Terminal window to place on display %@", targetDisplayID)
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    moveNewTerminalWindow(
                        ownerPID: ownerPID,
                        toDisplay: targetDisplayID,
                        existingWindowIDs: existingWindowIDs,
                        attempt: attempt + 1,
                        completion: completion)
                }
            }
            return
        }

        let moved = moveFocusedWindow(ownerPID: targetWindow.ownerPID, toDisplay: targetDisplayID)
        guard moved else {
            if attempt >= 10 {
                NSLog("WorkspaceAutomation: failed to move focused Terminal window to display %@", targetDisplayID)
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    moveNewTerminalWindow(
                        ownerPID: ownerPID,
                        toDisplay: targetDisplayID,
                        existingWindowIDs: existingWindowIDs,
                        attempt: attempt + 1,
                        completion: completion)
                }
            }
            return
        }

        if window(targetWindow.windowID, isOnDisplay: targetDisplayID) {
            completion(true)
            return
        }

        if attempt >= 10 {
            NSLog("WorkspaceAutomation: Terminal window did not settle on target display %@", targetDisplayID)
            completion(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                moveNewTerminalWindow(
                    ownerPID: ownerPID,
                    toDisplay: targetDisplayID,
                    existingWindowIDs: existingWindowIDs,
                    attempt: attempt + 1,
                    completion: completion)
            }
        }
    }

    private static func moveFocusedWindow(ownerPID: pid_t, toDisplay targetDisplayID: String) -> Bool {
        let targetBounds = CGDisplayBounds(DisplayGeometryUtilities.displayID(for: targetDisplayID))
        guard targetBounds.width > 0, targetBounds.height > 0 else { return false }

        let appElement = AXUIElementCreateApplication(ownerPID)
        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef) == .success,
              let focusedWindow = focusedWindowRef,
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID()
        else { return false }

        var point = CGPoint(x: targetBounds.origin.x + 120, y: targetBounds.origin.y + 120)
        guard let positionValue = AXValueCreate(.cgPoint, &point) else { return false }

        let moved = AXUIElementSetAttributeValue(
            focusedWindow as! AXUIElement,
            kAXPositionAttribute as CFString,
            positionValue) == .success

        if moved {
            AXUIElementPerformAction(focusedWindow as! AXUIElement, kAXRaiseAction as CFString)
        }

        return moved
    }

    private static func window(_ windowID: Int, isOnDisplay targetDisplayID: String) -> Bool {
        let windows = terminalWindowsSnapshot()
        guard let window = windows.first(where: { $0.windowID == windowID }) else { return false }

        let candidateDisplayIDs = NSScreen.screens.compactMap { screen -> String? in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayGeometryUtilities.uuidString(for: CGDirectDisplayID(num.uint32Value))
        }

        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        return DisplayGeometryUtilities.displayUUID(containing: center, candidates: candidateDisplayIDs) == targetDisplayID
    }

    private static func terminalWindowsSnapshot() -> [SpaceWindow] {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var windows: [SpaceWindow] = []
        for info in windowInfoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == "Terminal",
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            var bounds = CGRect.zero
            if let boundsDict = info[kCGWindowBounds as String] as? [String: Any] {
                let x = boundsDict["X"] as? CGFloat ?? 0
                let y = boundsDict["Y"] as? CGFloat ?? 0
                let w = boundsDict["Width"] as? CGFloat ?? 0
                let h = boundsDict["Height"] as? CGFloat ?? 0
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }

            windows.append(SpaceWindow(
                windowID: windowID,
                ownerName: ownerName,
                ownerPID: ownerPID,
                windowTitle: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? true))
        }

        return windows
    }
}
