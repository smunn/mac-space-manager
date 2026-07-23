//
//  MacKeyboardView.swift
//  SpaceManager
//

import IOKit
import SwiftUI

struct MacKeyboardView: View {
    @AppStorage("windowLayoutKeyboardStyle") private var keyboardStyleRaw = MacKeyboardStyle.standard.rawValue
    let highlightedModifiers: Set<MagnetShortcutModifier>
    let highlightedKeys: [String: Color]
    let modifierColor: Color

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKey: String,
        highlightColor: Color = .accentColor,
        modifierColor: Color = Color(nsColor: .labelColor)
    ) {
        _keyboardStyleRaw = AppStorage(
            wrappedValue: KeyboardHardwareDetector.detectedStyle.rawValue,
            "windowLayoutKeyboardStyle")
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = WindowLayoutCommandColors.keyboardHighlights(
            for: [(highlightedKey, highlightColor)])
        self.modifierColor = modifierColor
    }

    init(
        highlightedModifiers: Set<MagnetShortcutModifier>,
        highlightedKeys: [String: Color],
        modifierColor: Color = Color(nsColor: .labelColor)
    ) {
        _keyboardStyleRaw = AppStorage(
            wrappedValue: KeyboardHardwareDetector.detectedStyle.rawValue,
            "windowLayoutKeyboardStyle")
        self.highlightedModifiers = highlightedModifiers
        self.highlightedKeys = highlightedKeys
        self.modifierColor = modifierColor
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
                let unit = min(
                    (proxy.size.width - gap * layout.width) / layout.width,
                    (proxy.size.height - gap * layout.height) / layout.height)
                let keyboardWidth = layout.width * (unit + gap) - gap
                let keyboardHeight = layout.height * (unit + gap) - gap

                ZStack(alignment: .topLeading) {
                    ForEach(layout.keys) { item in
                        KeyboardKeyView(item: item, highlightColor: highlightColor(for: item))
                            .frame(
                                width: item.width * (unit + gap) - gap,
                                height: item.height * (unit + gap) - gap)
                            .offset(
                                x: item.x * (unit + gap),
                                y: item.y * (unit + gap))
                    }
                }
                .frame(width: keyboardWidth, height: keyboardHeight)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .frame(minHeight: 245, idealHeight: 270)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.3), lineWidth: 1)
        }
        .debugLabel("MacKeyboardView")
    }

    private var keyboardStyle: MacKeyboardStyle {
        MacKeyboardStyle(rawValue: keyboardStyleRaw) ?? KeyboardHardwareDetector.detectedStyle
    }

    private var keyboardStyleBinding: Binding<MacKeyboardStyle> {
        Binding(
            get: { keyboardStyle },
            set: { keyboardStyleRaw = $0.rawValue })
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

enum MacKeyboardStyle: String, CaseIterable, Identifiable {
    case standard
    case numericKeypad

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Numeric Keypad" }
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
}

private struct KeyboardKeyView: View {
    let item: KeyboardKeySpec
    let highlightColor: Color?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(highlightColor?.opacity(0.2) ?? Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 4)
                .stroke(highlightColor ?? Color.secondary.opacity(0.35), lineWidth: highlightColor == nil ? 1 : 2)

            VStack(spacing: 1) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(displayLabel)
                    .font(.system(size: item.label.count > 5 ? 7 : 10, weight: highlightColor == nil ? .regular : .semibold, design: .rounded))
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
            .foregroundStyle(highlightColor ?? Color.primary)
            .padding(.horizontal, 2)
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

private struct KeyboardLayout {
    let width: CGFloat
    let height: CGFloat
    let keys: [KeyboardKeySpec]

    static func layout(for style: MacKeyboardStyle) -> KeyboardLayout {
        style == .standard ? standard : extended
    }

    private static var standard: KeyboardLayout {
        KeyboardLayout(width: 15, height: 6, keys: mainKeys(includeStandardArrows: true))
    }

    private static var extended: KeyboardLayout {
        var keys = mainKeys(includeStandardArrows: false)
        keys += functionKeys(range: 13...19, startX: 16)
        keys += [
            key("help", 16, 1), key("home", 17, 1), key("pg up", 18, 1),
            key("forward delete", 16, 2), key("end", 17, 2), key("pg dn", 18, 2),
            key("↑", 17, 4.5, height: 0.5),
            key("←", 16, 5.5, height: 0.5), key("↓", 17, 5.5, height: 0.5),
            key("→", 18, 5.5, height: 0.5),
            key("Clear", 19.5, 1), key("KP=", 20.5, 1), key("KP/", 21.5, 1), key("KP*", 22.5, 1),
            key("KP7", 19.5, 2), key("KP8", 20.5, 2), key("KP9", 21.5, 2), key("KP-", 22.5, 2),
            key("KP4", 19.5, 3), key("KP5", 20.5, 3), key("KP6", 21.5, 3), key("KP+", 22.5, 3, height: 2),
            key("KP1", 19.5, 4), key("KP2", 20.5, 4), key("KP3", 21.5, 4),
            key("KP0", 19.5, 5, width: 2), key("KP.", 21.5, 5), key("KP Enter", 22.5, 4, height: 2)
        ]
        return KeyboardLayout(width: 23.5, height: 6, keys: keys)
    }

    private static func mainKeys(includeStandardArrows: Bool) -> [KeyboardKeySpec] {
        var keys = [key("esc", 0, 0, width: 1.25)]
        keys += functionKeys(range: 1...12, startX: 2)
        keys += row(["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], y: 1)
        keys.append(key("delete", 13, 1, width: 2))
        keys += row(Array("QWERTYUIOP").map(String.init) + ["[", "]"], y: 2, startX: 1.5)
        keys.append(key("tab", 0, 2, width: 1.5))
        keys.append(key("\\", 13.5, 2, width: 1.5))
        keys += row(Array("ASDFGHJKL").map(String.init) + [";", "'"], y: 3, startX: 1.75)
        keys.append(key("caps lock", 0, 3, width: 1.75))
        keys.append(key("return", 12.75, 3, width: 2.25))
        keys += row(Array("ZXCVBNM").map(String.init) + [",", ".", "/"], y: 4, startX: 2.25)
        keys.append(key("shift", 0, 4, width: 2.25, modifier: .shift))
        keys.append(key("shift", 12.25, 4, width: 2.75, modifier: .shift))
        keys += [
            key("fn", 0, 5),
            key("control", 1, 5, modifier: .control),
            key("option", 2, 5, width: 1.25, modifier: .option),
            key("command", 3.25, 5, width: 1.5, modifier: .command),
            key("space", 4.75, 5, width: includeStandardArrows ? 4.5 : 5.5),
            key("command", includeStandardArrows ? 9.25 : 10.25, 5, width: 1.5, modifier: .command),
            key("option", includeStandardArrows ? 10.75 : 11.75, 5, width: 1.25, modifier: .option)
        ]
        if includeStandardArrows {
            keys += [
                key("←", 12, 5.5, height: 0.5), key("↑", 13, 5, height: 0.5),
                key("↓", 13, 5.5, height: 0.5), key("→", 14, 5.5, height: 0.5)
            ]
        }
        return keys
    }

    private static func functionKeys(range: ClosedRange<Int>, startX: CGFloat) -> [KeyboardKeySpec] {
        range.enumerated().map { offset, number in
            key("F\(number)", startX + CGFloat(offset), 0, symbol: functionSymbol(number))
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
        symbol: String? = nil
    ) -> KeyboardKeySpec {
        KeyboardKeySpec(
            id: "\(label)-\(x)-\(y)", label: label, x: x, y: y,
            width: width, height: height, modifier: modifier, symbol: symbol)
    }
}

private enum KeyboardHardwareDetector {
    static let detectedStyle: MacKeyboardStyle = {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOHIDDevice"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return .standard }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let values = properties?.takeRetainedValue() as? [String: Any],
                  (values["PrimaryUsagePage"] as? NSNumber)?.intValue == 1,
                  (values["PrimaryUsage"] as? NSNumber)?.intValue == 6
            else { continue }

            let product = (values["Product"] as? String ?? "").lowercased()
            if product.contains("virtual") || product.contains("karabiner") { continue }
            let vendor = (values["VendorID"] as? NSNumber)?.intValue
            let productID = (values["ProductID"] as? NSNumber)?.intValue
            if (vendor == 0x004C || vendor == 0x05AC), productID == 0x026C {
                return .numericKeypad
            }
            if product.contains("numeric keypad") || product.contains("extended keyboard") {
                return .numericKeypad
            }
        }
        return .standard
    }()
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
