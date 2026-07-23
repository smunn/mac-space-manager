//
//  MacKeyboardView.swift
//  SpaceManager
//

import SwiftUI

struct MacKeyboardView: View {
    @AppStorage("windowLayoutKeyboardStyle") private var keyboardStyleRaw = MacKeyboardStyle.standard.rawValue
    @State private var manualKeyboardStyle: MacKeyboardStyle?
    let highlightedModifiers: Set<MagnetShortcutModifier>
    let highlightedKeys: [String: Color]
    let modifierColor: Color
    let keyboardStyleOverride: MacKeyboardStyle?

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKey: String,
        highlightColor: Color = .accentColor,
        modifierColor: Color = Color(nsColor: .labelColor),
        keyboardStyleOverride: MacKeyboardStyle? = nil
    ) {
        _keyboardStyleRaw = AppStorage(
            wrappedValue: KeyboardHardwareDetector.detectedStyle.rawValue,
            "windowLayoutKeyboardStyle")
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = WindowLayoutCommandColors.keyboardHighlights(
            for: [(highlightedKey, highlightColor)])
        self.modifierColor = modifierColor
        self.keyboardStyleOverride = keyboardStyleOverride
    }

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKeys: [String: Color],
        modifierColor: Color = Color(nsColor: .labelColor),
        keyboardStyleOverride: MacKeyboardStyle? = nil
    ) {
        _keyboardStyleRaw = AppStorage(
            wrappedValue: KeyboardHardwareDetector.detectedStyle.rawValue,
            "windowLayoutKeyboardStyle")
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = highlightedKeys
        self.modifierColor = modifierColor
        self.keyboardStyleOverride = keyboardStyleOverride
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Picker("Keyboard", selection: keyboardStyleBinding) {
                    ForEach(MacKeyboardStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }

            GeometryReader { proxy in
                let layout = KeyboardLayout.layout(for: keyboardStyle)
                let gap: CGFloat = 4
                let shellPadding: CGFloat = 8
                let availableWidth = max(1, proxy.size.width - shellPadding * 2)
                let availableHeight = max(1, proxy.size.height - shellPadding * 2)
                let unit = min(
                    (availableWidth + gap) / layout.width - gap,
                    (availableHeight + gap) / layout.height - gap)
                let keyboardWidth = layout.width * (unit + gap) - gap
                let keyboardHeight = layout.height * (unit + gap) - gap
                let shellWidth = keyboardWidth + shellPadding * 2
                let shellHeight = keyboardHeight + shellPadding * 2
                let originX = (proxy.size.width - keyboardWidth) / 2
                let originY = (proxy.size.height - keyboardHeight) / 2

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.secondary.opacity(0.3), lineWidth: 1)
                        }
                        .frame(width: shellWidth, height: shellHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                    ForEach(layout.keys) { item in
                        let keyWidth = item.width * (unit + gap) - gap
                        let keyHeight = item.height * (unit + gap) - gap
                        KeyboardKeyView(item: item, highlightColor: highlightColor(for: item))
                            .frame(width: keyWidth, height: keyHeight)
                            .position(
                                x: originX + item.x * (unit + gap) + keyWidth / 2,
                                y: originY + item.y * (unit + gap) + keyHeight / 2)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(minHeight: 245, idealHeight: 270)
        }
        .debugLabel("MacKeyboardView")
    }

    private var keyboardStyle: MacKeyboardStyle {
        manualKeyboardStyle
            ?? keyboardStyleOverride
            ?? MacKeyboardStyle(rawValue: keyboardStyleRaw)
            ?? KeyboardHardwareDetector.detectedStyle
    }

    private var keyboardStyleBinding: Binding<MacKeyboardStyle> {
        Binding(
            get: { keyboardStyle },
            set: {
                manualKeyboardStyle = $0
                keyboardStyleRaw = $0.rawValue
            })
    }

    private func highlightColor(for item: KeyboardKeySpec) -> Color? {
        if let modifier = item.modifier {
            return highlightedModifiers.contains(modifier) ? modifierColor : nil
        }
        return highlightedKeys[normalized(item.label)]
    }

    private func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }

}

private struct KeyboardKeySpec: Identifiable {
    let id: String
    let label: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let modifier: MagnetShortcutModifier?
    let symbol: String?
    let labelPlacement: KeyboardLabelPlacement
}

private enum KeyboardLabelPlacement {
    case center
    case bottomLeading
    case bottomTrailing
    case stackedModifier
}

private struct KeyboardKeyView: View {
    let item: KeyboardKeySpec
    let highlightColor: Color?
    var isCompact = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isCompact ? 3 : 4)
                .fill(highlightColor?.opacity(0.2) ?? Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: isCompact ? 3 : 4)
                .stroke(highlightColor ?? Color.secondary.opacity(0.35), lineWidth: highlightColor == nil ? 1 : 2)

            keyLabel
                .foregroundStyle(highlightColor ?? Color.primary)
        }
        .debugLabel("KeyboardKeyView")
    }

    @ViewBuilder
    private var keyLabel: some View {
        if item.labelPlacement == .stackedModifier, let modifier = item.modifier {
            VStack(spacing: 0) {
                Text(modifier.glyph)
                    .font(.system(size: isCompact ? 8 : 10, weight: .medium, design: .rounded))
                Text(item.label.lowercased())
                    .font(.system(size: isCompact ? 5 : 6.5, weight: .regular, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .lineLimit(1)
            }
        } else {
            labelContents
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(.horizontal, isCompact ? 2 : 3)
                .padding(.vertical, isCompact ? 2 : 5)
        }
    }

    private var labelContents: some View {
        VStack(spacing: 1) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(
                        size: isCompact ? 8 : (item.label == "touch id" ? 15 : 10),
                        weight: .medium))
            }
            if item.label != "touch id" {
                Text(displayLabel)
                    .font(.system(
                        size: labelFontSize,
                        weight: highlightColor == nil ? .regular : .semibold,
                        design: .rounded))
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .lineLimit(1)
            }
        }
    }

    private var labelFontSize: CGFloat {
        if isCompact {
            return displayLabel.count > 5 ? 7 : 9
        }
        switch displayLabel.count {
        case 9...: return 6
        case 7...: return 7
        default: return 10
        }
    }

    private var alignment: Alignment {
        switch item.labelPlacement {
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        default: return .center
        }
    }

    private var displayLabel: String {
        if item.label.caseInsensitiveCompare("eject") == .orderedSame {
            return "⏏"
        }
        if item.label.lowercased().hasPrefix("kp") {
            return String(item.label.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
        }
        return item.label.lowercased()
    }
}

struct KeyboardShortcutView: View {
    let modifiers: Set<MagnetShortcutModifier>
    let key: String
    let color: Color

    init(
        modifiers: Set<MagnetShortcutModifier>,
        key: String,
        color: Color = .accentColor
    ) {
        self.modifiers = modifiers
        self.key = key
        self.color = color
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MagnetShortcutModifier.allCases.filter(modifiers.contains)) { modifier in
                keycap(label: modifier.title, modifier: modifier)
            }
            keycap(label: key)
        }
        .fixedSize()
        .debugLabel("KeyboardShortcutView")
    }

    private func keycap(
        label: String,
        modifier: MagnetShortcutModifier? = nil
    ) -> some View {
        KeyboardKeyView(
            item: KeyboardKeySpec(
                id: modifier?.rawValue ?? label,
                label: label,
                x: 0,
                y: 0,
                width: 1,
                height: 1,
                modifier: modifier,
                symbol: nil,
                labelPlacement: modifier == nil ? .center : .stackedModifier),
            highlightColor: color,
            isCompact: true)
            .frame(width: keycapWidth(label: label, modifier: modifier), height: 24)
    }

    private func keycapWidth(
        label: String,
        modifier: MagnetShortcutModifier?
    ) -> CGFloat {
        if modifier != nil { return 31 }
        switch label.count {
        case 8...: return 54
        case 5...: return 46
        case 2...: return 34
        default: return 25
        }
    }
}

private struct KeyboardLayout {
    let width: CGFloat
    let height: CGFloat
    let keys: [KeyboardKeySpec]

    static func layout(for style: MacKeyboardStyle) -> KeyboardLayout {
        style == .standard ? standard : extended
    }

    private static var standard: KeyboardLayout {
        var keys = mainKeys(
            includeStandardArrows: true,
            includeFunctionSymbols: true,
            includeFunctionRow: false)
        keys += [key("esc", 0, 0, width: 1.75, placement: .bottomLeading)]
        keys += functionKeys(range: 1...12, startX: 1.75, includeSymbols: true)
        keys += [key("touch id", 13.75, 0, width: 1.25, symbol: "touchid")]
        return KeyboardLayout(width: 15, height: 6, keys: keys)
    }

    private static var extended: KeyboardLayout {
        var keys = mainKeys(
            includeStandardArrows: false,
            includeFunctionSymbols: false,
            includeFunctionRow: true)
        // The original Magic Keyboard with Numeric Keypad places Eject at the
        // far-right edge of the main typing block. F13-F15 sit over the
        // navigation cluster, and F16-F19 sit over the keypad.
        keys += [key("Eject", 13.5, 0, placement: .bottomTrailing)]
        keys += [
            key("f13", 14.75, 0), key("f14", 15.75, 0), key("f15", 16.75, 0),
            key("f16", 18, 0), key("f17", 19, 0), key("f18", 20, 0),
            key("f19", 21, 0)
        ]
        keys += [
            key("home", 15.75, 1), key("page up", 16.75, 1),
            key("delete", 14.75, 2, placement: .bottomLeading), key("end", 15.75, 2), key("page down", 16.75, 2),
            // Extended Apple keyboards use four full-size arrow keys rather
            // than the half-height arrows on compact Magic Keyboards.
            key("↑", 15.75, 4),
            key("←", 14.75, 5), key("↓", 15.75, 5), key("→", 16.75, 5),
            key("Clear", 18, 1), key("KP=", 19, 1), key("KP/", 20, 1), key("KP*", 21, 1),
            key("KP7", 18, 2), key("KP8", 19, 2), key("KP9", 20, 2), key("KP-", 21, 2),
            key("KP4", 18, 3), key("KP5", 19, 3), key("KP6", 20, 3), key("KP+", 21, 3),
            key("KP1", 18, 4), key("KP2", 19, 4), key("KP3", 20, 4),
            key("KP0", 18, 5, width: 2), key("KP.", 20, 5), key("KP Enter", 21, 4, height: 2)
        ]
        return KeyboardLayout(width: 22, height: 6, keys: keys)
    }

    private static func mainKeys(
        includeStandardArrows: Bool,
        includeFunctionSymbols: Bool,
        includeFunctionRow: Bool
    ) -> [KeyboardKeySpec] {
        var keys: [KeyboardKeySpec] = []
        if includeFunctionRow {
            keys = [key("esc", 0, 0, width: 1.5, placement: .bottomLeading)]
            keys += functionKeys(range: 1...12, startX: 1.5, includeSymbols: includeFunctionSymbols)
        }
        keys += row(["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], y: 1)
        keys.append(key("delete", 13, 1, width: includeStandardArrows ? 2 : 1.5, placement: .bottomTrailing))
        keys += row(Array("QWERTYUIOP").map(String.init) + ["[", "]"], y: 2, startX: 1.5)
        keys.append(key("tab", 0, 2, width: 1.5, placement: .bottomLeading))
        keys.append(key("\\", 13.5, 2, width: includeStandardArrows ? 1.5 : 1))
        keys += row(Array("ASDFGHJKL").map(String.init) + [";", "'"], y: 3, startX: 1.75)
        keys.append(key("caps lock", 0, 3, width: 1.75, placement: .bottomLeading))
        keys.append(key("return", 12.75, 3, width: includeStandardArrows ? 2.25 : 1.75, placement: .bottomTrailing))
        keys += row(Array("ZXCVBNM").map(String.init) + [",", ".", "/"], y: 4, startX: 2.25)
        keys.append(key("⇧ shift", 0, 4, width: 2.25, modifier: .shift, placement: .bottomLeading))
        keys.append(key("shift ⇧", 12.25, 4, width: includeStandardArrows ? 2.75 : 2.25, modifier: .shift, placement: .bottomTrailing))
        if includeStandardArrows {
            keys += [
                key("fn", 0, 5, placement: .bottomLeading),
                key("control", 1, 5, modifier: .control, placement: .stackedModifier),
                key("option", 2, 5, width: 1.25, modifier: .option, placement: .stackedModifier),
                key("command", 3.25, 5, width: 1.5, modifier: .command, placement: .stackedModifier),
                key("space", 4.75, 5, width: 4.5),
                key("command", 9.25, 5, width: 1.5, modifier: .command, placement: .stackedModifier),
                key("option", 10.75, 5, width: 1.25, modifier: .option, placement: .stackedModifier)
            ]
        } else {
            // The extended layout has paired Control/Option/Command keys. Its
            // space bar spans precisely between the paired Command keys.
            keys += [
                key("control", 0, 5, width: 1.5, modifier: .control, placement: .stackedModifier),
                key("option", 1.5, 5, width: 1.25, modifier: .option, placement: .stackedModifier),
                key("command", 2.75, 5, width: 1.5, modifier: .command, placement: .stackedModifier),
                key("space", 4.25, 5, width: 6),
                key("command", 10.25, 5, width: 1.5, modifier: .command, placement: .stackedModifier),
                key("option", 11.75, 5, width: 1.25, modifier: .option, placement: .stackedModifier),
                key("control", 13, 5, width: 1.5, modifier: .control, placement: .stackedModifier)
            ]
        }
        if includeStandardArrows {
            keys += [
                key("←", 12, 5.5, height: 0.5), key("↑", 13, 5, height: 0.5),
                key("↓", 13, 5.5, height: 0.5), key("→", 14, 5.5, height: 0.5)
            ]
        }
        return keys
    }

    private static func functionKeys(
        range: ClosedRange<Int>,
        startX: CGFloat,
        includeSymbols: Bool
    ) -> [KeyboardKeySpec] {
        range.enumerated().map { offset, number in
            key(
                "f\(number)",
                startX + CGFloat(offset),
                0,
                symbol: includeSymbols ? functionSymbol(number) : nil)
        }
    }

    private static func functionSymbol(_ number: Int) -> String? {
        [
            1: "sun.min", 2: "sun.max", 3: "rectangle.3.group", 4: "square.grid.3x3",
            7: "backward.end.fill", 8: "playpause.fill", 9: "forward.end.fill",
            10: "speaker.slash.fill", 11: "speaker.wave.1.fill", 12: "speaker.wave.3.fill"
        ][number]
    }

    private static func row(_ labels: [String], y: CGFloat, startX: CGFloat = 0) -> [KeyboardKeySpec] {
        labels.enumerated().map { index, label in key(label, startX + CGFloat(index), y) }
    }

    private static func key(
        _ label: String,
        _ x: CGFloat,
        _ y: CGFloat,
        width: CGFloat = 1,
        height: CGFloat = 1,
        modifier: MagnetShortcutModifier? = nil,
        symbol: String? = nil,
        placement: KeyboardLabelPlacement = .center
    ) -> KeyboardKeySpec {
        KeyboardKeySpec(
            id: "\(label)-\(x)-\(y)", label: label, x: x, y: y,
            width: width, height: height, modifier: modifier, symbol: symbol,
            labelPlacement: placement)
    }
}

enum WindowLayoutCommandColors {
    static func token(
        for command: MagnetShortcutCommand,
        among commands: [MagnetShortcutCommand]
    ) -> Int {
        commands.firstIndex(where: { $0.id == command.id }) ?? 0
    }

    static func color(
        for command: MagnetShortcutCommand,
        among commands: [MagnetShortcutCommand]
    ) -> Color {
        color(forToken: token(for: command, among: commands))
    }

    static func colors(for commands: [MagnetShortcutCommand]) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: commands.enumerated().map { index, command in
            (command.id, color(forToken: index))
        })
    }

    private static func color(forToken token: Int) -> Color {
        let hue = (Double(token) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        let brightness = 0.88 + Double(token % 3) * 0.05
        return Color(hue: hue, saturation: 0.72, brightness: brightness)
    }

    static func keyboardHighlights(for commands: [MagnetShortcutCommand]) -> [String: Color] {
        let colors = colors(for: commands)
        return keyboardHighlights(for: commands.compactMap { command in
            colors[command.id].map { (command.destinationKey, $0) }
        })
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
