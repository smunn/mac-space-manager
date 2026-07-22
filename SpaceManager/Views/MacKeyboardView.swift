//
//  MacKeyboardView.swift
//  SpaceManager
//

import SwiftUI

struct MacKeyboardView: View {
    let highlightedModifiers: Set<MagnetShortcutModifier>
    let highlightedKey: String

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
                    KeyboardKeyView(item: item, isHighlighted: isHighlighted(item))
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
                            isHighlighted: isHighlighted(item)
                        )
                        .frame(width: unitWidth * item.width)
                    }
                }
            }
        }
        .frame(height: 34)
    }

    private func isHighlighted(_ item: KeyboardKey) -> Bool {
        if let modifier = item.modifier {
            return highlightedModifiers.contains(modifier)
        }
        return normalized(item.label) == normalized(highlightedKey)
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
    let isHighlighted: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 4)
                .stroke(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isHighlighted ? 1.5 : 1)

            Text(displayLabel)
                .font(.system(size: item.label.count > 2 ? 8 : 11, weight: isHighlighted ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
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
