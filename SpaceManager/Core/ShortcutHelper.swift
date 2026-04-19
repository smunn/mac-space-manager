//
//  ShortcutHelper.swift
//  SpaceManager
//
//  Reads Mission Control keyboard shortcuts from macOS user defaults.
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

struct SpaceShortcut {
    let keyCode: Int
    let modifiers: String
    let modifierFlags: NSEvent.ModifierFlags
    let keyEquivalent: String
}

class ShortcutHelper {
    private static let desktopHotkeyBaseID = 118
    private static let moveLeftID = 79
    private static let moveRightID = 81

    private var desktopShortcuts: [Int: SpaceShortcut] = [:]
    private(set) var moveLeftShortcut: SpaceShortcut?
    private(set) var moveRightShortcut: SpaceShortcut?

    init() {
        reload()
    }

    func reload() {
        desktopShortcuts.removeAll()
        guard let plist = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = plist.persistentDomain(
                forName: "com.apple.symbolichotkeys"
              )?["AppleSymbolicHotKeys"] as? [String: Any]
        else { return }

        for desktop in 1...Space.maxSwitchableDesktop {
            let hotkeyID = ShortcutHelper.desktopHotkeyBaseID + desktop - 1
            if let shortcut = parseHotkey(id: hotkeyID, from: hotkeys) {
                desktopShortcuts[desktop] = shortcut
            }
        }

        moveLeftShortcut = parseHotkey(id: ShortcutHelper.moveLeftID, from: hotkeys)
        moveRightShortcut = parseHotkey(id: ShortcutHelper.moveRightID, from: hotkeys)
    }

    func shortcut(forDesktop desktop: Int) -> SpaceShortcut? {
        desktopShortcuts[desktop]
    }

    func getKeyCode(spaceNumber: Int) -> Int {
        desktopShortcuts[spaceNumber]?.keyCode ?? -1
    }

    func getModifiers(spaceNumber: Int) -> String {
        desktopShortcuts[spaceNumber]?.modifiers ?? ""
    }

    private func parseHotkey(id: Int, from hotkeys: [String: Any]) -> SpaceShortcut? {
        guard let entry = hotkeys[String(id)] as? [String: Any],
              let enabled = entry["enabled"] as? Bool, enabled,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int],
              params.count >= 3
        else { return nil }

        let keyCode = params[1]
        let modRaw = params[2]

        var mods: [String] = []
        if modRaw & (1 << 17) != 0 { mods.append("shift down") }
        if modRaw & (1 << 18) != 0 { mods.append("control down") }
        if modRaw & (1 << 19) != 0 { mods.append("option down") }
        if modRaw & (1 << 20) != 0 { mods.append("command down") }

        var flags = NSEvent.ModifierFlags()
        if modRaw & (1 << 17) != 0 { flags.insert(.shift) }
        if modRaw & (1 << 18) != 0 { flags.insert(.control) }
        if modRaw & (1 << 19) != 0 { flags.insert(.option) }
        if modRaw & (1 << 20) != 0 { flags.insert(.command) }

        let keyEquivalent = keyCodeToCharacter(keyCode)

        return SpaceShortcut(
            keyCode: keyCode,
            modifiers: mods.joined(separator: ","),
            modifierFlags: flags,
            keyEquivalent: keyEquivalent)
    }

    private func keyCodeToCharacter(_ keyCode: Int) -> String {
        switch keyCode {
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        default: return ""
        }
    }
}
