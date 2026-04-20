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
//  per display under "Mission Control" > "Dock" > group "Mission Control".
//  The displayGroupIndex parameter (1-based) selects which display to target.
//  Desktop numbers are per-display ("Desktop 1", "Desktop 2", etc. within each group).
//
//  Limitations:
//  - Mission Control briefly flashes during the operation
//  - Cannot close fullscreen spaces (exit the app instead)
//  - Cannot close the last remaining desktop space on a display
//

import Cocoa

class SpaceCloser {

    /// A space to close, identified by its Mission Control group and per-display desktop number.
    struct CloseTarget {
        let displayGroup: Int
        let desktopNumber: Int
    }

    /// Closes desktop spaces by performing AXRemoveDesktop in Mission Control.
    ///
    /// Opens Mission Control, locates "Desktop N" buttons in each display's Spaces Bar,
    /// performs AXRemoveDesktop on each (highest first within each group to preserve numbering),
    /// then dismisses Mission Control via Escape.
    static func closeSpaces(targets: [CloseTarget], completion: @escaping (Bool) -> Void) {
        guard !targets.isEmpty else {
            completion(false)
            return
        }

        let script = buildCloseScript(targets: targets)
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

    // Groups targets by display, sorts highest desktop number first within each
    // group to preserve numbering during removal.
    private static func buildCloseScript(targets: [CloseTarget]) -> String {
        let grouped = Dictionary(grouping: targets, by: { $0.displayGroup })

        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        lines.append("tell application \"System Events\"")
        lines.append("  tell process \"Dock\"")
        lines.append("    tell group \"Mission Control\"")

        for group in grouped.keys.sorted() {
            let desktopNumbers = grouped[group]!.map(\.desktopNumber).sorted(by: >)
            lines.append("      tell group \(group)")
            lines.append("        tell group \"Spaces Bar\"")
            lines.append("          tell list 1")

            for num in desktopNumbers {
                lines.append("            try")
                lines.append("              perform action \"AXRemoveDesktop\" of button \"Desktop \(num)\"")
                lines.append("              delay 0.8")
                lines.append("            end try")
            }

            lines.append("          end tell")
            lines.append("        end tell")
            lines.append("      end tell")
        }

        lines.append("    end tell")
        lines.append("  end tell")
        lines.append("  delay 0.3")
        lines.append("  key code 53")
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }

    private static func buildAddScript(displayGroupIndex: Int) -> String {
        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        lines.append("tell application \"System Events\"")
        lines.append("  tell process \"Dock\"")
        lines.append("    tell group \"Mission Control\"")
        lines.append("      tell group \(displayGroupIndex)")
        lines.append("        tell group \"Spaces Bar\"")
        lines.append("          click button 1")
        lines.append("        end tell")
        lines.append("      end tell")
        lines.append("    end tell")
        lines.append("  end tell")
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
        lines.append("tell application \"System Events\"")
        lines.append("  tell process \"Dock\"")
        lines.append("    tell group \"Mission Control\"")
        lines.append("      tell group \(displayGroupIndex)")
        lines.append("        tell group \"Spaces Bar\"")
        lines.append("          click button 1")
        lines.append("          delay 0.6")
        lines.append("          tell list 1")
        lines.append("            set didClickDesktop to false")
        lines.append("            repeat 20 times")
        lines.append("              try")
        lines.append("                click button \"Desktop \(desktopNumber)\"")
        lines.append("                set didClickDesktop to true")
        lines.append("                exit repeat")
        lines.append("              on error")
        lines.append("                delay 0.1")
        lines.append("              end try")
        lines.append("            end repeat")
        lines.append("            if didClickDesktop is false then error \"Could not find Desktop \(desktopNumber)\"")
        lines.append("          end tell")
        lines.append("        end tell")
        lines.append("      end tell")
        lines.append("    end tell")
        lines.append("  end tell")
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }
}
