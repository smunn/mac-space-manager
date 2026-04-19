//
//  SpaceSwitcher.swift
//  SpaceManager
//
//  Switches between macOS Spaces via simulated keyboard shortcuts.
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

class SpaceSwitcher {
    private let shortcutHelper = ShortcutHelper()

    init() {
        AXIsProcessTrusted()
    }

    func reloadShortcuts() {
        shortcutHelper.reload()
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
                if let error = error {
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let briefMessage = error[NSAppleScript.errorBriefMessage] as? String ?? "Unknown error"
                    NSLog("SpaceSwitcher error \(errorNumber): \(briefMessage)")
                    DispatchQueue.main.async { onError?() }
                }
            }
        }
    }

    func switchToPreviousSpace() {
        let sc = shortcutHelper.moveLeftShortcut
        sendKeyCode(sc?.keyCode ?? 123, modifiers: sc?.modifiers ?? "control down")
    }

    func switchToNextSpace() {
        let sc = shortcutHelper.moveRightShortcut
        sendKeyCode(sc?.keyCode ?? 124, modifiers: sc?.modifiers ?? "control down")
    }

    private func sendKeyCode(_ keyCode: Int, modifiers: String) {
        let script = "tell application \"System Events\" to key code \(keyCode) using {\(modifiers)}"
        DispatchQueue.global(qos: .userInteractive).async {
            if let scriptObject = NSAppleScript(source: script) {
                var error: NSDictionary?
                scriptObject.executeAndReturnError(&error)
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
