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
//  Limitations:
//  - Mission Control briefly flashes during the operation
//  - Single-display only (multi-display requires per-display group targeting
//    in the Mission Control accessibility tree)
//  - Cannot close fullscreen spaces (exit the app instead)
//  - Cannot close the last remaining desktop space
//

import Cocoa

class SpaceCloser {

    /// Closes desktop spaces by performing AXRemoveDesktop in Mission Control.
    ///
    /// Opens Mission Control, locates "Desktop N" buttons in the Spaces Bar,
    /// performs AXRemoveDesktop on each (highest first to preserve numbering),
    /// then dismisses Mission Control via Escape.
    ///
    /// Windows on closed spaces are automatically moved to adjacent spaces by macOS.
    ///
    /// - Parameters:
    ///   - desktopNumbers: 1-based desktop numbers matching "Desktop N" in Mission Control.
    ///     Must not include fullscreen spaces or the last remaining desktop.
    ///   - completion: Called on the main thread with true if the script executed without error.
    static func closeSpaces(desktopNumbers: [Int], completion: @escaping (Bool) -> Void) {
        guard !desktopNumbers.isEmpty else {
            completion(false)
            return
        }

        let script = buildCloseScript(desktopNumbers: desktopNumbers.sorted(by: >))

        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    /// Adds a new desktop space via Mission Control's add button.
    static func addSpace(completion: @escaping (Bool) -> Void) {
        let script = buildAddScript()

        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    // Closes from highest desktop number to lowest so that
    // earlier removals don't shift the numbering of later targets.
    private static func buildCloseScript(desktopNumbers: [Int]) -> String {
        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        lines.append("tell application \"System Events\"")
        lines.append("  tell process \"Dock\"")
        lines.append("    tell group \"Mission Control\"")
        lines.append("      tell group 1")
        lines.append("        tell group \"Spaces Bar\"")
        lines.append("          tell list 1")

        for num in desktopNumbers {
            lines.append("            try")
            lines.append("              perform action \"AXRemoveDesktop\" of button \"Desktop \(num)\"")
            lines.append("              delay 0.3")
            lines.append("            end try")
        }

        lines.append("          end tell")
        lines.append("        end tell")
        lines.append("      end tell")
        lines.append("    end tell")
        lines.append("  end tell")
        lines.append("  delay 0.3")
        lines.append("  key code 53")
        lines.append("end tell")

        return lines.joined(separator: "\n")
    }

    private static func buildAddScript() -> String {
        var lines: [String] = []
        lines.append("tell application \"Mission Control\" to launch")
        lines.append("delay 0.7")
        lines.append("")
        lines.append("tell application \"System Events\"")
        lines.append("  tell process \"Dock\"")
        lines.append("    tell group \"Mission Control\"")
        lines.append("      tell group 1")
        lines.append("        tell group \"Spaces Bar\"")
        // The "+" button is a standalone button inside Spaces Bar (outside the list)
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
}
