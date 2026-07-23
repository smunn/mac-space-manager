//
//  MagnetShortcutEditorAdapter.swift
//  Space Manager
//
//  Bridges Magnet's Carbon/private-plist representation to the UI editor.
//

import Foundation

enum MagnetKeyCodes {
    static let byName: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35,
        "Return": 36, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47,
        "Space": 49, "Delete": 51,
        "F17": 64, "KP.": 65, "KP*": 67, "KP+": 69, "Clear": 71,
        "KP/": 75, "KP Enter": 76, "KP-": 78, "F18": 79, "F19": 80,
        "KP=": 81, "KP0": 82, "KP1": 83, "KP2": 84, "KP3": 85,
        "KP4": 86, "KP5": 87, "KP6": 88, "KP7": 89, "KP8": 91, "KP9": 92,
        "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101,
        "F11": 103, "F13": 105, "F16": 106, "F14": 107, "F10": 109,
        "F12": 111, "F15": 113, "F4": 118, "F2": 120, "F1": 122,
        "←": 123, "→": 124, "↓": 125, "↑": 126
    ]

    private static let byCode: [UInt32: String] = Dictionary(
        uniqueKeysWithValues: byName.map { ($0.value, $0.key) }
    )

    static func code(for name: String) -> UInt32? { byName[name] }
    static func name(for code: UInt32) -> String? { byCode[code] }
}

enum MagnetShortcutEditorError: LocalizedError {
    case unsupportedKey(String)
    case insufficientModifiers(String)
    case spaceManagerConflict(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedKey(let key):
            return "The key \(key) is not supported."
        case .insufficientModifiers(let name):
            return "\(name) must use at least two modifier keys."
        case .spaceManagerConflict(let shortcut):
            return "\(shortcut) is already used by Space Manager."
        }
    }
}

struct MagnetShortcutEditorAdapter {
    private static let control: UInt32 = 4096
    private static let option: UInt32 = 2048
    private static let shift: UInt32 = 512
    private static let command: UInt32 = 256

    func editorCommands(from configuration: MagnetShortcutConfiguration) -> [MagnetShortcutCommand] {
        MagnetOrientation.allCases.flatMap { orientation in
            configuration.commands(for: orientation).compactMap { command in
                makeEditorCommand(command, orientation: orientation)
            }
        }
    }

    func applying(
        _ edits: [MagnetShortcutCommand],
        to configuration: MagnetShortcutConfiguration
    ) throws -> MagnetShortcutConfiguration {
        var updated = configuration
        let editsByID = Dictionary(uniqueKeysWithValues: edits.map { ($0.id, $0) })

        for orientation in MagnetOrientation.allCases {
            var commands = updated.commands(for: orientation)
            for index in commands.indices {
                guard let edit = editsByID[commands[index].id] else { continue }
                if commands[index].name == "Top 3/8 Left" {
                    commands[index].primaryTargetFrame = MagnetTargetFrame(x: 0, y: 6, width: 6, height: 3)
                }
                if edit.isEnabled {
                    guard edit.modifiers.count >= 2 else {
                        throw MagnetShortcutEditorError.insufficientModifiers(edit.name)
                    }
                    guard let keyCode = MagnetKeyCodes.code(for: edit.destinationKey) else {
                        throw MagnetShortcutEditorError.unsupportedKey(edit.destinationKey)
                    }
                    let shortcut = MagnetShortcut(
                        carbonKeyCode: keyCode,
                        carbonModifiers: Self.carbonModifiers(for: edit.modifiers)
                    )
                    if Self.spaceManagerReservedShortcuts.contains(shortcut) {
                        throw MagnetShortcutEditorError.spaceManagerConflict(edit.shortcutText)
                    }
                    commands[index].shortcut = shortcut
                    commands[index].isShortcutEnabled = true
                } else {
                    commands[index].isShortcutEnabled = false
                }
            }
            updated.replaceCommands(commands, for: orientation)
        }
        return updated
    }

    private func makeEditorCommand(
        _ command: MagnetCommand,
        orientation: MagnetOrientation
    ) -> MagnetShortcutCommand? {
        guard command.category != "divider",
              command.isShortcutAvailable || command.primaryTargetFrame != nil,
              !command.name.isEmpty
        else { return nil }

        let displayOrientation: MagnetDisplayOrientation = orientation == .vertical ? .portrait : .horizontal
        let name = Self.displayName(for: command.name, orientation: displayOrientation)
        let group = Self.group(for: command, displayName: name)
        let frame = Self.normalizedFrame(for: command, orientation: orientation)
        let shortcut = command.shortcut

        return MagnetShortcutCommand(
            id: command.id,
            name: name,
            orientation: displayOrientation,
            group: group,
            section: Self.section(for: command, displayName: name, group: group),
            destinationKey: Self.cornerKey(for: name) ?? shortcut.flatMap { MagnetKeyCodes.name(for: $0.carbonKeyCode) } ?? "",
            modifiers: shortcut.map { Self.modifiers(for: $0.carbonModifiers) } ?? [],
            isEnabled: command.isShortcutEnabled,
            x: frame.x,
            y: frame.y,
            width: frame.width,
            height: frame.height
        )
    }

    private static func group(for command: MagnetCommand, displayName: String) -> MagnetShortcutGroup {
        let lower = displayName.lowercased()
        if lower.contains("two third") || lower.contains("maximize") || lower == "center" ||
            lower.contains("restore") || lower.contains("display") {
            return .basics
        }
        if lower.contains("corner") || lower.contains("top left") || lower.contains("top right") ||
            lower.contains("bottom left") || lower.contains("bottom right") {
            if !lower.contains("1/") { return .halves }
        }

        switch command.shortcut?.carbonModifiers {
        case control | option: return .halves
        case control | Self.command: return .thirds
        case control | option | shift: return .quarters
        case control | shift | Self.command: return .sixths
        case control | option | shift | Self.command: return .eighths
        default:
            if lower.contains("1/8") { return .eighths }
            if lower.contains("1/6") { return .sixths }
            if lower.contains("1/4") { return .quarters }
            if lower.contains("third") || lower.contains("1/3") { return .thirds }
            return .basics
        }
    }

    private static func section(
        for command: MagnetCommand,
        displayName: String,
        group: MagnetShortcutGroup
    ) -> String {
        let lower = displayName.lowercased()
        if lower.contains("two third") { return "Two Thirds" }
        if lower.contains("display") { return "Displays" }
        if lower.contains("maximize") || lower == "center" || lower.contains("restore") { return "Window" }
        if lower.contains("corner") || lower.contains("top left") || lower.contains("top right") ||
            lower.contains("bottom left") || lower.contains("bottom right") {
            if !lower.contains("1/") { return "Corners" }
        }
        if group == .halves { return "Halves" }
        if group != .basics, let frame = command.primaryTargetFrame {
            if command.orientation == .vertical, frame.x == 0, frame.width == 12 {
                return "Full Width"
            }
            if command.orientation == .horizontal, frame.y == 0, frame.height == 12 {
                return "Full Height"
            }
        }
        return "Grid"
    }

    private static func normalizedFrame(
        for command: MagnetCommand,
        orientation: MagnetOrientation
    ) -> MagnetTargetFrame {
        if orientation == .vertical, command.name == "Top 3/8 Left" {
            return MagnetTargetFrame(x: 0, y: 0.25, width: 0.5, height: 0.125)
        }
        guard let frame = command.primaryTargetFrame else {
            return MagnetTargetFrame(x: 0, y: 0, width: 1, height: 1)
        }
        let canvasWidth: Double
        let canvasHeight: Double
        switch orientation {
        case .vertical:
            canvasWidth = 12
            canvasHeight = 24
        case .horizontal:
            // Magnet stores its built-in horizontal commands on a 24×12
            // canvas, even though it labels them as `custom`. User-created
            // horizontal grid commands use 12×12. Treating every `custom`
            // command as 12 columns doubles built-in widths and can place a
            // right-side target beyond the current display.
            canvasWidth = command.name.hasPrefix("command:default.name.") ? 24 : 12
            canvasHeight = 12
        }
        let x = max(0, min(1, frame.x / canvasWidth))
        let y = max(0, min(1, frame.y / canvasHeight))
        return MagnetTargetFrame(
            x: x,
            y: y,
            width: max(0, min(1 - x, frame.width / canvasWidth)),
            height: max(0, min(1 - y, frame.height / canvasHeight))
        )
    }

    private static func displayName(
        for rawName: String,
        orientation: MagnetDisplayOrientation
    ) -> String {
        let longAxisNames: [String: String] = orientation == .portrait
            ? ["left": "Left Half", "right": "Right Half", "up": "Top Half", "down": "Bottom Half"]
            : ["left": "Left Half", "right": "Right Half", "up": "Top Half", "down": "Bottom Half"]
        let key = rawName.replacingOccurrences(of: "command:default.name.", with: "")
        if let name = longAxisNames[key] { return name }

        let names: [String: String] = [
            "topLeft": "Top Left Corner", "topRight": "Top Right Corner",
            "bottomLeft": "Bottom Left Corner", "bottomRight": "Bottom Right Corner",
            "leftThird": "Left Third", "centerThird": "Center Third", "rightThird": "Right Third",
            "topThird": "Top Third", "bottomThird": "Bottom Third",
            "leftTwoThirds": "Left Two Thirds", "centerTwoThirds": "Center Two Thirds",
            "rightTwoThirds": "Right Two Thirds", "topTwoThirds": "Top Two Thirds",
            "bottomTwoThirds": "Bottom Two Thirds", "nextDisplay": "Next Display",
            "previousDisplay": "Previous Display", "maximize": "Maximize", "center": "Center",
            "restore": "Restore"
        ]
        return names[key] ?? rawName
    }

    private static func cornerKey(for displayName: String) -> String? {
        switch displayName {
        case "Top Left Corner": return "Q"
        case "Top Right Corner": return "W"
        case "Bottom Left Corner": return "A"
        case "Bottom Right Corner": return "S"
        default: return nil
        }
    }

    private static func carbonModifiers(for modifiers: Set<MagnetShortcutModifier>) -> UInt32 {
        modifiers.reduce(0) { result, modifier in
            switch modifier {
            case .control: return result | control
            case .option: return result | option
            case .shift: return result | shift
            case .command: return result | command
            }
        }
    }

    private static func modifiers(for carbon: UInt32) -> Set<MagnetShortcutModifier> {
        var result = Set<MagnetShortcutModifier>()
        if carbon & control != 0 { result.insert(.control) }
        if carbon & option != 0 { result.insert(.option) }
        if carbon & shift != 0 { result.insert(.shift) }
        if carbon & command != 0 { result.insert(.command) }
        return result
    }

    private static let spaceManagerReservedShortcuts: Set<MagnetShortcut> = [
        MagnetShortcut(carbonKeyCode: 37, carbonModifiers: control | option | command), // L
        MagnetShortcut(carbonKeyCode: 46, carbonModifiers: control | option | command)  // M
    ]

}
