//
//  SpaceSwitcher.swift
//  SpaceManager
//
//  Switches between macOS Spaces via simulated keyboard shortcuts.
//  Uses arrow-key chaining when direct Desktop N shortcuts are unavailable.
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

class SpaceSwitcher {
    private let shortcutHelper = ShortcutHelper()
    private var chainObserver: NSObjectProtocol?
    private var chainTimeout: DispatchWorkItem?

    init() {
        AXIsProcessTrusted()
    }

    func reloadShortcuts() {
        shortcutHelper.reload()
    }

    /// Switches to a space by clicking its button in Mission Control.
    /// Constant time regardless of distance -- no stepping through intermediate spaces.
    func switchViaMissionControl(desktopNumber: Int) {
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
        lines.append("            click button \"Desktop \(desktopNumber)\"")
        lines.append("          end tell")
        lines.append("        end tell")
        lines.append("      end tell")
        lines.append("    end tell")
        lines.append("  end tell")
        lines.append("end tell")

        let script = lines.joined(separator: "\n")
        DispatchQueue.global(qos: .userInteractive).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
        }
    }

    func canDirectSwitch(spaceNumber: Int) -> Bool {
        shortcutHelper.getKeyCode(spaceNumber: spaceNumber) >= 0
    }

    func switchToSpace(spaceNumber: Int, onError: (() -> Void)? = nil) {
        let keyCode = shortcutHelper.getKeyCode(spaceNumber: spaceNumber)
        if keyCode < 0 {
            onError?()
            return
        }
        let modifiers = shortcutHelper.getModifiers(spaceNumber: spaceNumber)
        let appleScript = makeAppleScript(keyCode: keyCode, modifiers: modifiers)
        DispatchQueue.global(qos: .userInteractive).async {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: appleScript) {
                scriptObject.executeAndReturnError(&error)
                if error != nil {
                    DispatchQueue.main.async { onError?() }
                }
            }
        }
    }

    func navigateToSpace(from currentNumber: Int, to targetNumber: Int, onError: (() -> Void)? = nil) {
        cancelChain()
        let delta = targetNumber - currentNumber
        guard delta != 0 else { return }
        let goRight = delta > 0
        executeChain(stepsRemaining: abs(delta), goRight: goRight, onError: onError)
    }

    private func executeChain(stepsRemaining: Int, goRight: Bool, onError: (() -> Void)? = nil) {
        guard stepsRemaining > 0 else { return }
        if goRight {
            switchToNextSpace(onError: onError)
        } else {
            switchToPreviousSpace(onError: onError)
        }
        if stepsRemaining == 1 { return }
        waitForSpaceChange {
            self.executeChain(stepsRemaining: stepsRemaining - 1, goRight: goRight, onError: onError)
        }
    }

    private func waitForSpaceChange(onComplete: @escaping () -> Void) {
        let timeout = DispatchWorkItem { [weak self] in
            self?.cancelChain()
        }
        chainTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)

        chainObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            timeout.cancel()
            self?.removeChainObserver()
            onComplete()
        }
    }

    func cancelChain() {
        chainTimeout?.cancel()
        chainTimeout = nil
        removeChainObserver()
    }

    private func removeChainObserver() {
        if let observer = chainObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            chainObserver = nil
        }
    }

    private func switchToPreviousSpace(onError: (() -> Void)? = nil) {
        let sc = shortcutHelper.moveLeftShortcut
        sendKeyCode(sc?.keyCode ?? 123, modifiers: sc?.modifiers ?? "control down", onError: onError)
    }

    private func switchToNextSpace(onError: (() -> Void)? = nil) {
        let sc = shortcutHelper.moveRightShortcut
        sendKeyCode(sc?.keyCode ?? 124, modifiers: sc?.modifiers ?? "control down", onError: onError)
    }

    private func sendKeyCode(_ keyCode: Int, modifiers: String, onError: (() -> Void)? = nil) {
        let script = makeAppleScript(keyCode: keyCode, modifiers: modifiers)
        NSLog("SpaceSwitcher: sending keyCode=\(keyCode) modifiers=\(modifiers)")
        DispatchQueue.global(qos: .userInteractive).async {
            if let scriptObject = NSAppleScript(source: script) {
                var error: NSDictionary?
                scriptObject.executeAndReturnError(&error)
                if let error = error {
                    let num = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let msg = error[NSAppleScript.errorBriefMessage] as? String ?? "unknown"
                    NSLog("SpaceSwitcher FAILED: error \(num) — \(msg)")
                    DispatchQueue.main.async { onError?() }
                }
            }
        }
    }

    private func makeAppleScript(keyCode: Int, modifiers: String) -> String {
        if modifiers.isEmpty {
            return "tell application \"System Events\" to key code \(keyCode)"
        }
        return "tell application \"System Events\" to key code \(keyCode) using {\(modifiers)}"
    }
}
