//
//  SpaceCloser.swift
//  SpaceManager
//
//  Closes macOS Spaces via Mission Control's accessibility API.
//
//  macOS provides no public API for removing Spaces. The private CGSSpaceDestroy
//  function exists in the SkyLight framework, but the WindowServer restricts it
//  to Dock.app's connection -- calls from other processes are silently ignored.
//  Tools like yabai bypass this by injecting code into Dock.app, which requires
//  partially disabling SIP.
//
//  This implementation uses a different approach: the AXRemoveDesktop accessibility
//  action exposed on Mission Control's space buttons. This is the same mechanism
//  behind the close button that appears when hovering over a space thumbnail in
//  Mission Control. It requires only standard Accessibility and Automation permissions.
//
//  In multi-display setups, Mission Control's accessibility tree has one group
//  per display. Before macOS 27, these groups live under Dock's "Mission Control"
//  group. Starting in macOS 27, they are top-level groups owned by WindowManager.
//  The displayGroupIndex parameter (1-based) selects which display to target.
//  The visible button labels can be globally numbered across every display
//  ("Desktop 1" ... "Desktop 9"), so we target desktop buttons by their
//  position among the "Desktop *" buttons inside each display group instead.
//
//  Limitations:
//  - Mission Control briefly flashes during the operation
//  - Cannot close fullscreen spaces (exit the app instead)
//  - Cannot close the last remaining desktop space on a display
//

import Cocoa

class SpaceCloser {

    /// A space to close, identified by its Mission Control group and the
    /// 1-based position of its desktop button within that display's desktop list.
    struct CloseTarget {
        let displayGroup: Int
        let desktopIndex: Int
    }

    /// A desktop to activate after closing spaces, addressed by 1-based position
    /// within the destination display's desktop-button list.
    struct FocusTarget {
        let displayGroup: Int
        let desktopIndex: Int
    }

    /// Closes desktop spaces by performing AXRemoveDesktop in Mission Control.
    ///
    /// Opens Mission Control, locates desktop buttons inside each display's Spaces Bar,
    /// performs AXRemoveDesktop on each (highest index first within each group to preserve
    /// per-display ordering), then dismisses Mission Control via Escape.
    static func closeSpaces(
        targets: [CloseTarget],
        focusTarget: FocusTarget? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        guard !targets.isEmpty else {
            completion(false)
            return
        }

        let script = buildCloseScript(targets: targets, focusTarget: focusTarget)
        execute(script: script, completion: completion)
    }

    /// Adds a new desktop space on the specified display via Mission Control's add button.
    static func addSpace(displayGroupIndex: Int = 1, completion: @escaping (Bool) -> Void) {
        let script = buildAddScript(displayGroupIndex: displayGroupIndex)
        execute(script: script, completion: completion)
    }

    /// Adds a new desktop space on the specified display, then switches to it.
    static func addSpaceAndSwitch(
        toDesktopNumber desktopNumber: Int,
        displayGroupIndex: Int = 1,
        completion: @escaping (Bool) -> Void
    ) {
        let script = buildAddAndSwitchScript(desktopNumber: desktopNumber, displayGroupIndex: displayGroupIndex)
        execute(script: script, completion: completion)
    }

    private static func execute(script: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error {
                NSLog("SpaceCloser AppleScript failed: \(error)")
            }
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    // MARK: - Script Builders

    // Groups targets by display, sorts highest desktop index first within each
    // group to preserve per-display ordering during removal.
    private static func buildCloseScript(targets: [CloseTarget], focusTarget: FocusTarget?) -> String {
        let grouped = Dictionary(grouping: targets, by: { $0.displayGroup })

        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        MissionControlAccessibility.appendProcessStart(to: &lines)

        let sortedGroups = grouped.keys.sorted()
        for (i, group) in sortedGroups.enumerated() {
            if i > 0 {
                lines.append("      delay 0.5")
            }
            let desktopIndexes = grouped[group]!.map(\.desktopIndex).sorted(by: >)
            lines.append("      tell group \(group)")
            lines.append("        tell group \"Spaces Bar\"")
            lines.append("          tell list 1")

            for index in desktopIndexes {
                lines.append("            try")
                lines.append("              set desktopButtons to (every button whose name starts with \"Desktop \")")
                lines.append("              perform action \"AXRemoveDesktop\" of (item \(index) of desktopButtons)")
                lines.append("              delay 0.8")
                lines.append("            end try")
            }

            lines.append("          end tell")
            lines.append("        end tell")
            lines.append("      end tell")
        }

        if let focusTarget {
            lines.append("      tell group \(focusTarget.displayGroup)")
            lines.append("        tell group \"Spaces Bar\"")
            lines.append("          tell list 1")
            lines.append("            set didClickDesktop to false")
            lines.append("            repeat 20 times")
            lines.append("              try")
            lines.append("                set desktopButtons to (every button whose name starts with \"Desktop \")")
            lines.append("                click (item \(focusTarget.desktopIndex) of desktopButtons)")
            lines.append("                set didClickDesktop to true")
            lines.append("                exit repeat")
            lines.append("              on error")
            lines.append("                delay 0.1")
            lines.append("              end try")
            lines.append("            end repeat")
            lines.append("            if didClickDesktop is false then error \"Could not find desktop index \(focusTarget.desktopIndex)\"")
            lines.append("          end tell")
            lines.append("        end tell")
            lines.append("      end tell")
        }

        MissionControlAccessibility.appendProcessEnd(to: &lines)
        if focusTarget == nil {
            lines.append("  delay 0.3")
            lines.append("  key code 53")
        }
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }

    private static func buildAddScript(displayGroupIndex: Int) -> String {
        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        MissionControlAccessibility.appendProcessStart(to: &lines)
        lines.append("      tell group \(displayGroupIndex)")
        lines.append("        tell group \"Spaces Bar\"")
        lines.append("          click button 1")
        lines.append("        end tell")
        lines.append("      end tell")
        MissionControlAccessibility.appendProcessEnd(to: &lines)
        lines.append("  delay 0.5")
        lines.append("  key code 53")
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }

    private static func buildAddAndSwitchScript(desktopNumber: Int, displayGroupIndex: Int) -> String {
        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        MissionControlAccessibility.appendProcessStart(to: &lines)
        lines.append("      tell group \(displayGroupIndex)")
        lines.append("        tell group \"Spaces Bar\"")
        lines.append("          click button 1")
        lines.append("          delay 0.6")
        lines.append("          tell list 1")
        lines.append("            set didClickDesktop to false")
        lines.append("            repeat 20 times")
        lines.append("              try")
        lines.append("                set desktopButtons to (every button whose name starts with \"Desktop \")")
        lines.append("                click (item \(desktopNumber) of desktopButtons)")
        lines.append("                set didClickDesktop to true")
        lines.append("                exit repeat")
        lines.append("              on error")
        lines.append("                delay 0.1")
        lines.append("              end try")
        lines.append("            end repeat")
        lines.append("            if didClickDesktop is false then error \"Could not find desktop index \(desktopNumber)\"")
        lines.append("          end tell")
        lines.append("        end tell")
        lines.append("      end tell")
        MissionControlAccessibility.appendProcessEnd(to: &lines)
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }
}
