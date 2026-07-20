//
//  SpaceCloser.swift
//  SpaceManager
//
//  Creates and closes macOS Spaces through Mission Control accessibility actions.
//
//  macOS provides no public API for adding or removing Spaces. The private
//  CGSSpaceDestroy function is restricted to Dock.app, so this implementation opens
//  Mission Control and performs the accessibility actions exposed by its controls.
//  It uses AXUIElement directly rather than AppleScript/System Events, polls for UI
//  readiness, and verifies each requested mutation by observing the desktop count.
//
//  Limitations:
//  - Mission Control briefly appears during the operation
//  - Full-screen Spaces cannot be removed this way
//  - The final desktop on a display cannot be removed
//  - Mission Control's hierarchy and AXRemoveDesktop action remain undocumented
//

import Cocoa

class SpaceCloser {
    struct CloseTarget {
        let displayGroup: Int
        let desktopIndex: Int
    }

    struct FocusTarget {
        let displayGroup: Int
        let desktopIndex: Int
    }

    static func closeSpaces(
        targets: [CloseTarget],
        focusTarget: FocusTarget? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard !targets.isEmpty else {
            completion(false)
            return
        }

        MissionControlAccessibility.operationQueue.async {
            let success = closeSpacesSynchronously(targets: targets, focusTarget: focusTarget)
            DispatchQueue.main.async { completion(success) }
        }
    }

    static func addSpace(displayGroupIndex: Int = 1, completion: @escaping (Bool) -> Void) {
        MissionControlAccessibility.operationQueue.async {
            let success = addSpaceSynchronously(
                displayGroupIndex: displayGroupIndex,
                switchToDesktopIndex: nil)
            DispatchQueue.main.async { completion(success) }
        }
    }

    static func addSpaceAndSwitch(
        toDesktopNumber desktopNumber: Int,
        displayGroupIndex: Int = 1,
        completion: @escaping (Bool) -> Void
    ) {
        MissionControlAccessibility.operationQueue.async {
            let success = addSpaceSynchronously(
                displayGroupIndex: displayGroupIndex,
                switchToDesktopIndex: desktopNumber)
            DispatchQueue.main.async { completion(success) }
        }
    }

    private static func closeSpacesSynchronously(
        targets: [CloseTarget],
        focusTarget: FocusTarget?
    ) -> Bool {
        guard MissionControlAccessibility.openAndWaitForDisplaySnapshots() != nil else {
            return failAndDismiss("Mission Control accessibility hierarchy did not appear")
        }

        let grouped = Dictionary(grouping: targets, by: \.displayGroup)
        for group in grouped.keys.sorted() {
            let desktopIndexes = grouped[group]!.map(\.desktopIndex).sorted(by: >)
            for desktopIndex in desktopIndexes {
                guard let snapshots = MissionControlAccessibility.currentDisplaySnapshots().nonEmpty,
                      snapshots.indices.contains(group - 1)
                else {
                    return failAndDismiss("display group \(group) was unavailable")
                }

                let snapshot = snapshots[group - 1]
                guard snapshot.desktopButtons.indices.contains(desktopIndex - 1) else {
                    return failAndDismiss("desktop index \(desktopIndex) was unavailable in display group \(group)")
                }

                let previousCount = snapshot.desktopButtons.count
                guard MissionControlAccessibility.performRemoveDesktop(
                    on: snapshot.desktopButtons[desktopIndex - 1])
                else {
                    return failAndDismiss("AXRemoveDesktop failed for display group \(group), desktop \(desktopIndex)")
                }

                guard MissionControlAccessibility.waitForDesktopCount(
                    displayGroupIndex: group,
                    predicate: { $0 == previousCount - 1 }) != nil
                else {
                    return failAndDismiss("desktop count did not decrease for display group \(group)")
                }
            }
        }

        if let focusTarget {
            guard let snapshots = MissionControlAccessibility.currentDisplaySnapshots().nonEmpty,
                  snapshots.indices.contains(focusTarget.displayGroup - 1)
            else {
                return failAndDismiss("focus display group \(focusTarget.displayGroup) was unavailable")
            }

            let buttons = snapshots[focusTarget.displayGroup - 1].desktopButtons
            guard buttons.indices.contains(focusTarget.desktopIndex - 1),
                  MissionControlAccessibility.performPress(on: buttons[focusTarget.desktopIndex - 1])
            else {
                return failAndDismiss("could not focus desktop \(focusTarget.desktopIndex)")
            }
        } else {
            MissionControlAccessibility.dismiss()
        }

        return true
    }

    private static func addSpaceSynchronously(
        displayGroupIndex: Int,
        switchToDesktopIndex: Int?
    ) -> Bool {
        guard let snapshots = MissionControlAccessibility.openAndWaitForDisplaySnapshots(),
              snapshots.indices.contains(displayGroupIndex - 1)
        else {
            return failAndDismiss("Mission Control display group \(displayGroupIndex) did not appear")
        }

        let snapshot = snapshots[displayGroupIndex - 1]
        let previousCount = snapshot.desktopButtons.count
        guard let addButton = snapshot.addButton else {
            return failAndDismiss("add-desktop button was unavailable for display group \(displayGroupIndex)")
        }
        guard MissionControlAccessibility.performPress(on: addButton) else {
            return failAndDismiss("add-desktop action failed for display group \(displayGroupIndex)")
        }

        guard let updatedSnapshots = MissionControlAccessibility.waitForDesktopCount(
            displayGroupIndex: displayGroupIndex,
            predicate: { $0 == previousCount + 1 })
        else {
            return failAndDismiss("desktop count did not increase for display group \(displayGroupIndex)")
        }

        if let switchToDesktopIndex {
            let buttons = updatedSnapshots[displayGroupIndex - 1].desktopButtons
            guard buttons.indices.contains(switchToDesktopIndex - 1),
                  MissionControlAccessibility.performPress(on: buttons[switchToDesktopIndex - 1])
            else {
                return failAndDismiss("could not switch to newly-created desktop \(switchToDesktopIndex)")
            }
        } else {
            MissionControlAccessibility.dismiss()
        }

        return true
    }

    private static func failAndDismiss(_ message: String) -> Bool {
        NSLog("SpaceCloser: \(message)")
        MissionControlAccessibility.dismiss()
        return false
    }
}

private extension Collection {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
