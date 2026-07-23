//
//  MacKeyboardView.swift
//  SpaceManager
//

import SwiftUI

struct MacKeyboardView: View {
    let highlightedModifiers: Set<MagnetShortcutModifier>
    let highlightedKeys: [String: Color]
    let modifierColor: Color

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKey: String,
        highlightColor: Color = .accentColor,
        modifierColor: Color = Color(nsColor: .labelColor)
    ) {
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = WindowLayoutSectionColors.keyboardHighlights(
            for: [(highlightedKey, highlightColor)])
        self.modifierColor = modifierColor
    }

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKeys: [String: Color],
        modifierColor: Color = Color(nsColor: .labelColor)
    ) {
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = highlightedKeys
        self.modifierColor = modifierColor
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 4) {
                keyboardRow([key("esc", 1.2), spacer(0.4)] + functionKeys)
                keyboardRow(numberRow)
                keyboardRow([key("tab", 1.45)] + letters("QWERTYUIOP") + [key("["), key("]"), key("\\", 1.55)])
                keyboardRow([key("caps", 1.72)] + letters("ASDFGHJKL") + [key(";"), key("'"), key("return", 2.05)])
                keyboardRow([key("shift", 2.25, modifier: .shift)] + letters("ZXCVBNM") + [key(","), key("."), key("/"), key("shift", 2.65, modifier: .shift)])
                keyboardRow(bottomRow)
            }

            extendedKeyboard
                .frame(width: 220)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.3), lineWidth: 1)
        }
        .debugLabel("MacKeyboardView")
    }

    private var functionKeys: [KeyboardKey] {
        (1...12).map { key("F\($0)", 0.86) }
    }

    private var numberRow: [KeyboardKey] {
        [key("`", 1)] +
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { key($0) } +
        [key("delete", 1.7)]
    }

    private var bottomRow: [KeyboardKey] {
        [
            key("fn", 1),
            key("control", 1.05, modifier: .control),
            key("option", 1.05, modifier: .option),
            key("command", 1.35, modifier: .command),
            key("space", 5.1),
            key("command", 1.35, modifier: .command),
            key("option", 1.05, modifier: .option),
            key("←", 1), key("↓", 1), key("→", 1)
        ]
    }

    private var extendedKeyboard: some View {
        VStack(spacing: 4) {
            compactRow(["F13", "F14", "F15", "F16", "F17", "F18", "F19"])
            compactRow(["help", "home", "pg up", "clear", "KP=", "KP/", "KP*"])
            compactRow(["delete", "end", "pg dn", "KP7", "KP8", "KP9", "KP-"])
            compactRow(["", "↑", "", "KP4", "KP5", "KP6", "KP+"])
            compactRow(["←", "↓", "→", "KP1", "KP2", "KP3", "KP enter"])
            compactRow(["", "", "", "KP0", "KP0", "KP.", "KP enter"])
        }
    }

    private func compactRow(_ labels: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                if label.isEmpty {
                    Color.clear
                } else {
                    let item = key(label)
                    KeyboardKeyView(item: item, highlightColor: highlightColor(for: item))
                }
            }
        }
        .frame(height: 34)
    }

    private func keyboardRow(_ keys: [KeyboardKey]) -> some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(0, keys.count - 1)) * 4
            let units = keys.reduce(0) { $0 + $1.width }
            let unitWidth = max(8, (proxy.size.width - spacing) / units)

            HStack(spacing: 4) {
                ForEach(keys) { item in
                    if item.isSpacer {
                        Color.clear.frame(width: unitWidth * item.width)
                    } else {
                        KeyboardKeyView(
                            item: item,
                            highlightColor: highlightColor(for: item)
                        )
                        .frame(width: unitWidth * item.width)
                    }
                }
            }
        }
        .frame(height: 34)
    }

    private func highlightColor(for item: KeyboardKey) -> Color? {
        if let modifier = item.modifier {
            return highlightedModifiers.contains(modifier) ? modifierColor : nil
        }
        return highlightedKeys[normalized(item.label)]
    }

    private func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }

    private func letters(_ value: String) -> [KeyboardKey] {
        value.map { key(String($0)) }
    }

    private func key(
        _ label: String,
        _ width: CGFloat = 1,
        modifier: MagnetShortcutModifier? = nil
    ) -> KeyboardKey {
        KeyboardKey(label: label, width: width, modifier: modifier, isSpacer: false)
    }

    private func spacer(_ width: CGFloat) -> KeyboardKey {
        KeyboardKey(label: UUID().uuidString, width: width, modifier: nil, isSpacer: true)
    }
}

private struct KeyboardKey: Identifiable {
    let id = UUID()
    let label: String
    let width: CGFloat
    let modifier: MagnetShortcutModifier?
    let isSpacer: Bool
}

private struct KeyboardKeyView: View {
    let item: KeyboardKey
    let highlightColor: Color?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(highlightColor?.opacity(0.2) ?? Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 4)
                .stroke(highlightColor ?? Color.secondary.opacity(0.35), lineWidth: highlightColor == nil ? 1 : 2)

            Text(displayLabel)
                .font(.system(size: item.label.count > 2 ? 8 : 11, weight: highlightColor == nil ? .regular : .semibold, design: .rounded))
                .foregroundStyle(highlightColor ?? Color.primary)
                .lineLimit(1)
        }
        .debugLabel("KeyboardKeyView")
    }

    private var displayLabel: String {
        if let modifier = item.modifier {
            return "\(modifier.glyph) \(item.label)"
        }
        if item.label.lowercased().hasPrefix("kp") {
            return String(item.label.dropFirst(2)).uppercased()
        }
        return item.label.uppercased()
    }
}

enum WindowLayoutSectionColors {
    private static let colors: [String: Color] = [
        "Corners": .blue,
        "Halves": .red,
        "Two Thirds": .green,
        "Full Width": .orange,
        "Full Height": .yellow,
        "Grid": .purple,
        "Split": .mint,
        "Displays": .cyan,
        "Window": .pink
    ]
    private static let fallback: [Color] = [
        .indigo, .yellow, .teal, .brown, .blue, .red, .green, .orange, .purple, .pink
    ]

    static func color(for section: String) -> Color {
        if let color = colors[section] { return color }
        let value = section.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return fallback[Int(value.magnitude % UInt(fallback.count))]
    }

    static func keyboardHighlights(for commands: [MagnetShortcutCommand]) -> [String: Color] {
        keyboardHighlights(for: commands.map { ($0.destinationKey, color(for: $0.section)) })
    }

    static func keyboardHighlights(for entries: [(String, Color)]) -> [String: Color] {
        var result: [String: Color] = [:]
        for (key, color) in entries {
            let normalized = normalize(key)
            result[normalized] = color
            if normalized.count == 1, normalized.first?.isNumber == true {
                result["kp\(normalized)"] = color
            } else if normalized.hasPrefix("kp"), normalized.dropFirst(2).count == 1,
                      normalized.last?.isNumber == true {
                result[String(normalized.suffix(1))] = color
            }
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
