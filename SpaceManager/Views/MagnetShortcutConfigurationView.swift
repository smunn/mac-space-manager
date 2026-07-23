//
//  MagnetShortcutConfigurationView.swift
//  SpaceManager
//

import SwiftUI

enum MagnetDisplayOrientation: String, CaseIterable, Identifiable, Codable {
    case portrait = "Portrait"
    case horizontal = "Horizontal"

    var id: String { rawValue }
    var symbolName: String {
        self == .portrait ? "rectangle.portrait" : "rectangle"
    }
}

enum MagnetShortcutGroup: Int, CaseIterable, Identifiable, Codable {
    case basics = 0
    case halves = 2
    case thirds = 3
    case quarters = 4
    case sixths = 6
    case eighths = 8

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .basics: "Basics"
        case .halves: "Halves"
        case .thirds: "Thirds"
        case .quarters: "Quarters"
        case .sixths: "Sixths"
        case .eighths: "Eighths"
        }
    }

    var modifiers: Set<MagnetShortcutModifier> {
        switch self {
        case .basics: [.option, .command]
        case .halves: [.control, .option]
        case .thirds: [.control, .command]
        case .quarters: [.control, .option, .shift]
        case .sixths: [.control, .shift, .command]
        case .eighths: [.control, .option, .shift, .command]
        }
    }
}

enum MagnetShortcutModifier: String, CaseIterable, Identifiable, Codable {
    case control
    case option
    case shift
    case command

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var glyph: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

struct MagnetShortcutCommand: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var orientation: MagnetDisplayOrientation
    var group: MagnetShortcutGroup
    var section: String
    var destinationKey: String
    var modifiers: Set<MagnetShortcutModifier>
    var isEnabled: Bool
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var shortcutText: String {
        MagnetShortcutModifier.allCases
            .filter(modifiers.contains)
            .map(\.glyph)
            .joined() + destinationKey.uppercased()
    }

    var displayName: String {
        name == "Restore" ? "Restore Original" : name
    }
}

@MainActor
final class MagnetShortcutConfigurationModel: ObservableObject {
    @Published var commands: [MagnetShortcutCommand]
    @Published var selection: MagnetShortcutCommand.ID?
    @Published var orientation: MagnetDisplayOrientation = .portrait
    @Published var group: MagnetShortcutGroup = .halves
    @Published var searchText = ""
    @Published var isApplying = false

    let onSave: ([MagnetShortcutCommand]) throws -> Void
    let onApply: ([MagnetShortcutCommand]) async throws -> Void

    init(
        commands: [MagnetShortcutCommand] = MagnetShortcutCommand.standardSet,
        onSave: @escaping ([MagnetShortcutCommand]) throws -> Void = { _ in },
        onApply: @escaping ([MagnetShortcutCommand]) async throws -> Void = { _ in }
    ) {
        self.commands = commands
        self.onSave = onSave
        self.onApply = onApply
        self.selection = commands.first?.id
    }

    var selectedCommand: MagnetShortcutCommand? {
        guard let selection else { return nil }
        return commands.first { $0.id == selection }
    }

    var filteredCommands: [MagnetShortcutCommand] {
        commands.filter { command in
            command.orientation == orientation &&
            command.group == group &&
            (searchText.isEmpty ||
             command.displayName.localizedCaseInsensitiveContains(searchText) ||
             command.shortcutText.localizedCaseInsensitiveContains(searchText))
        }
    }

    func update(_ command: MagnetShortcutCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
    }

    func selectFirstVisibleCommand() {
        if !filteredCommands.contains(where: { $0.id == selection }) {
            selection = filteredCommands.first?.id
        }
    }
}

struct MagnetShortcutConfigurationView: View {
    @StateObject private var model: MagnetShortcutConfigurationModel
    @State private var mode: EditorMode = .configure
    @State private var applyError: String?
    @State private var statusText: String?

    init(
        commands: [MagnetShortcutCommand] = MagnetShortcutCommand.standardSet,
        onSave: @escaping ([MagnetShortcutCommand]) throws -> Void = { _ in },
        onApply: @escaping ([MagnetShortcutCommand]) async throws -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: MagnetShortcutConfigurationModel(
            commands: commands,
            onSave: onSave,
            onApply: onApply
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if mode == .configure {
                configurationContent
            } else {
                MagnetShortcutVisualGuide(
                    commands: model.commands,
                    orientation: $model.orientation,
                    group: $model.group,
                    selection: $model.selection
                )
            }
        }
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .onChange(of: model.orientation) { _ in model.selectFirstVisibleCommand() }
        .onChange(of: model.group) { _ in model.selectFirstVisibleCommand() }
        .onAppear { model.selectFirstVisibleCommand() }
        .alert("Shortcut Update Failed", isPresented: Binding(
            get: { applyError != nil },
            set: { if !$0 { applyError = nil } }
        )) {
            Button("OK") { applyError = nil }
        } message: {
            Text(applyError ?? "")
        }
        .debugLabel("magnetShortcutConfigurationView")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Window Shortcuts")
                .font(.headline)

            Picker("Mode", selection: $mode) {
                ForEach(EditorMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Spacer()

            if let statusText {
                Label(statusText, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Save") {
                do {
                    try model.onSave(model.commands)
                    statusText = "Saved"
                } catch {
                    applyError = error.localizedDescription
                }
            }

            Button(model.isApplying ? "Updating…" : "Update Magnet Shortcuts") {
                Task {
                    model.isApplying = true
                    defer { model.isApplying = false }
                    do {
                        try await model.onApply(model.commands)
                        statusText = "Magnet updated"
                    } catch {
                        applyError = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isApplying)
        }
        .padding(12)
    }

    private var configurationContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                commandList
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            if let command = model.selectedCommand {
                MagnetShortcutCommandEditor(
                    command: command,
                    groupCommands: model.commands.filter {
                        $0.orientation == command.orientation &&
                        $0.group == command.group &&
                        $0.isEnabled
                    }
                ) { model.update($0) }
                    .id(command.id)
            } else {
                Text("Select a shortcut")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker("Orientation", selection: $model.orientation) {
                ForEach(MagnetDisplayOrientation.allCases) { orientation in
                    Label(orientation.rawValue, systemImage: orientation.symbolName)
                        .tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Layout", selection: $model.group) {
                ForEach(MagnetShortcutGroup.allCases) { group in
                    Text(group.title).tag(group)
                }
            }
            .labelsHidden()

            TextField("Filter shortcuts", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
    }

    private var commandList: some View {
        let groupCommands = model.commands.filter {
            $0.orientation == model.orientation && $0.group == model.group
        }
        let colors = WindowLayoutCommandColors.colors(for: groupCommands)
        return List(selection: $model.selection) {
            ForEach(Dictionary(grouping: model.filteredCommands, by: \.section).keys.sorted(), id: \.self) { section in
                Section {
                    ForEach(model.filteredCommands.filter { $0.section == section }) { command in
                        MagnetShortcutCommandRow(
                            command: command,
                            color: colors[command.id] ?? .accentColor)
                            .tag(command.id)
                    }
                } header: {
                    Text(section)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private enum EditorMode: String, CaseIterable, Identifiable {
        case configure = "Configure"
        case guide = "Visual Guide"
        var id: String { rawValue }
    }
}

private struct MagnetShortcutCommandRow: View {
    let command: MagnetShortcutCommand
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            WindowLayoutGlyph(command: command, color: color)
                .frame(width: 28, height: 22)
            Text(command.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(command.shortcutText)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(command.isEnabled ? .secondary : .tertiary)
            if !command.isEnabled {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .debugLabel("MagnetShortcutCommandRow")
    }
}

private struct MagnetShortcutCommandEditor: View {
    @State private var command: MagnetShortcutCommand
    let groupCommands: [MagnetShortcutCommand]
    let onChange: (MagnetShortcutCommand) -> Void

    init(
        command: MagnetShortcutCommand,
        groupCommands: [MagnetShortcutCommand],
        onChange: @escaping (MagnetShortcutCommand) -> Void
    ) {
        _command = State(initialValue: command)
        self.groupCommands = groupCommands
        self.onChange = onChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(command.displayName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Toggle("Enabled", isOn: $command.isEnabled)
                        .toggleStyle(.switch)
                }

                HStack(alignment: .top, spacing: 16) {
                    WindowLayoutPreview(
                        command: command,
                        color: WindowLayoutCommandColors.color(for: command, among: groupCommands))
                        .frame(width: 220, height: 280)
                    shortcutControls
                }

                Divider()

                MacKeyboardView(
                    highlightedModifiers: groupCommands.reduce(into: []) { $0.formUnion($1.modifiers) },
                    highlightedKeys: WindowLayoutCommandColors.keyboardHighlights(for: groupCommands)
                )
                .frame(maxWidth: 720)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: command) { value in onChange(value) }
        .debugLabel("MagnetShortcutCommandEditor")
    }

    private var shortcutControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcut")
                .font(.headline)

            HStack(spacing: 4) {
                ForEach(MagnetShortcutModifier.allCases) { modifier in
                    Button {
                        if command.modifiers.contains(modifier) {
                            command.modifiers.remove(modifier)
                        } else {
                            command.modifiers.insert(modifier)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(modifier.glyph).font(.title3)
                            Text(modifier.title).font(.caption2)
                        }
                        .frame(width: 54, height: 42)
                    }
                    .buttonStyle(ShortcutToggleButtonStyle(isSelected: command.modifiers.contains(modifier)))
                }
            }

            HStack(spacing: 8) {
                Text("Key")
                    .frame(width: 36, alignment: .leading)
                Picker("Destination key", selection: $command.destinationKey) {
                    ForEach(Self.destinationKeys, id: \.self) { key in
                        Text(key).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                Text(command.shortcutText)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .frame(minWidth: 88, alignment: .leading)
            }

            Divider()

            LabeledContent("Orientation", value: command.orientation.rawValue)
            LabeledContent("Layout", value: command.group.title)
            LabeledContent("Region", value: command.section)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private static let destinationKeys =
        Array("1234567890QWERTYUIOPASDFGHJKLZXCVBNM").map(String.init) +
        (0...9).map { "KP\($0)" } +
        ["KP=", "KP/", "KP*", "KP-", "KP+", "KP.", "KP Enter", "Clear",
         "F13", "F14", "F15", "F16", "F17", "F18", "F19",
         "←", "→", "↑", "↓", "Return", "Delete", "Space"]
}

struct ShortcutToggleButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let selectedColor = Color(nsColor: .labelColor)
        return configuration.label
            .foregroundStyle(isSelected ? selectedColor : Color.primary)
            .background(isSelected ? selectedColor.opacity(0.12) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? selectedColor : Color.secondary.opacity(0.35), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WindowLayoutGlyph: View {
    let command: MagnetShortcutCommand
    let color: Color

    init(command: MagnetShortcutCommand, color: Color? = nil) {
        self.command = command
        self.color = color ?? .accentColor
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.secondary.opacity(0.45), lineWidth: 1)
                Rectangle()
                    .fill(color.opacity(0.72))
                    .frame(
                        width: proxy.size.width * command.width,
                        height: proxy.size.height * command.height
                    )
                    .offset(
                        x: proxy.size.width * command.x,
                        y: proxy.size.height * command.y
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .debugLabel("WindowLayoutGlyph")
    }
}

struct WindowLayoutPreview: View {
    let command: MagnetShortcutCommand
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let aspect = command.orientation == .portrait ? 0.62 : 1.6
            let width = min(proxy.size.width, proxy.size.height * aspect)
            let height = width / aspect

            WindowLayoutGlyph(command: command, color: color)
                .frame(width: width, height: height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .debugLabel("WindowLayoutPreview")
    }
}

extension MagnetShortcutCommand {
    static var standardSet: [MagnetShortcutCommand] {
        basicCommands(orientation: .portrait) + portraitCommands +
        basicCommands(orientation: .horizontal) + horizontalCommands
    }

    private static var portraitCommands: [MagnetShortcutCommand] {
        MagnetShortcutGroup.allCases.filter { $0.rawValue >= 3 }.flatMap { group -> [MagnetShortcutCommand] in
            let count = group.rawValue
            let full = (0..<count).map { index in
                make(
                    orientation: .portrait, group: group, section: "Full Width",
                    name: "Row \(index + 1) — Full Width", key: String(index + 1),
                    x: 0, y: Double(index) / Double(count),
                    width: 1, height: 1 / Double(count)
                )
            }
            // Portrait split grids always occupy one contiguous keyboard block.
            // Smaller grids use the rightmost columns; larger grids extend left
            // without wrapping, while every row measured from the bottom keeps
            // the same physical key across thirds, quarters, sixths, and eighths.
            let firstKeys = Array(Array("ERTYUIOP").suffix(count)).map(String.init)
            let secondKeys = Array(Array("DFGHJKL;").suffix(count)).map(String.init)
            let left = (0..<count).map { index in
                make(
                    orientation: .portrait, group: group, section: "Split",
                    name: "Row \(index + 1) — Left", key: firstKeys[index],
                    x: 0, y: Double(index) / Double(count),
                    width: 0.5, height: 1 / Double(count)
                )
            }
            let right = (0..<count).map { index in
                make(
                    orientation: .portrait, group: group, section: "Split",
                    name: "Row \(index + 1) — Right", key: secondKeys[index],
                    x: 0.5, y: Double(index) / Double(count),
                    width: 0.5, height: 1 / Double(count)
                )
            }
            return full + left + right
        }
    }

    private static var horizontalCommands: [MagnetShortcutCommand] {
        MagnetShortcutGroup.allCases.filter { $0.rawValue >= 3 }.flatMap { group -> [MagnetShortcutCommand] in
            let columns = group.rawValue > 4 ? group.rawValue / 2 : group.rawValue
            let rows = group.rawValue > 4 ? 2 : 1
            let topKeys = rows == 1
                ? (1...columns).map(String.init)
                : Array("UIOP").prefix(columns).map(String.init)
            let bottomKeys = Array("JKL;").prefix(columns).map(String.init)

            return (0..<rows).flatMap { row in
                (0..<columns).map { column in
                    let position = row * columns + column
                    let key = row == 0 ? topKeys[column] : bottomKeys[column]
                    return make(
                        orientation: .horizontal, group: group,
                        section: rows == 1 ? "Full Height" : "Grid",
                        name: rows == 1
                            ? "Column \(column + 1) — Full Height"
                            : "\(row == 0 ? "Top" : "Bottom") \(columnName(column, count: columns))",
                        key: key,
                        x: Double(column) / Double(columns),
                        y: Double(row) / Double(rows),
                        width: 1 / Double(columns), height: 1 / Double(rows),
                        position: position
                    )
                }
            }
        }
    }

    private static func make(
        orientation: MagnetDisplayOrientation,
        group: MagnetShortcutGroup,
        section: String,
        name: String,
        key: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        position: Int? = nil,
        modifiers: Set<MagnetShortcutModifier>? = nil
    ) -> MagnetShortcutCommand {
        MagnetShortcutCommand(
            id: "\(orientation.rawValue)-\(group.rawValue)-\(position ?? Int(y * 1000))-\(Int(x * 1000))-\(section)",
            name: name,
            orientation: orientation,
            group: group,
            section: section,
            destinationKey: key,
            modifiers: modifiers ?? group.modifiers,
            isEnabled: true,
            x: x, y: y, width: width, height: height
        )
    }

    private static func basicCommands(orientation: MagnetDisplayOrientation) -> [MagnetShortcutCommand] {
        typealias Region = (
            group: MagnetShortcutGroup, section: String, name: String, key: String,
            modifiers: Set<MagnetShortcutModifier>?, x: Double, y: Double, width: Double, height: Double
        )
        let halfModifiers: Set<MagnetShortcutModifier> = [.control, .option]
        let basicModifiers: Set<MagnetShortcutModifier> = [.option, .command]
        let displayModifiers: Set<MagnetShortcutModifier> = [.control, .option, .command]
        let cornerKeys = ["U", "I", "J", "K"]
        let twoThirdKeys = ["U", "I", "O"]
        let twoThirdNames = orientation == .portrait
            ? ["Top Two Thirds", "Center Two Thirds", "Bottom Two Thirds"]
            : ["Left Two Thirds", "Center Two Thirds", "Right Two Thirds"]

        let regions: [Region] = [
            (.halves, "Halves", "Left Half", "←", halfModifiers, 0, 0, 0.5, 1),
            (.halves, "Halves", "Right Half", "→", halfModifiers, 0.5, 0, 0.5, 1),
            (.halves, "Halves", "Top Half", orientation == .portrait ? "1" : "↑", halfModifiers, 0, 0, 1, 0.5),
            (.halves, "Halves", "Bottom Half", orientation == .portrait ? "2" : "↓", halfModifiers, 0, 0.5, 1, 0.5),
            (.halves, "Corners", "Top Left Corner", cornerKeys[0], halfModifiers, 0, 0, 0.5, 0.5),
            (.halves, "Corners", "Top Right Corner", cornerKeys[1], halfModifiers, 0.5, 0, 0.5, 0.5),
            (.halves, "Corners", "Bottom Left Corner", cornerKeys[2], halfModifiers, 0, 0.5, 0.5, 0.5),
            (.halves, "Corners", "Bottom Right Corner", cornerKeys[3], halfModifiers, 0.5, 0.5, 0.5, 0.5),
            (.basics, "Two Thirds", twoThirdNames[0], twoThirdKeys[0], basicModifiers, 0, 0, orientation == .portrait ? 1 : 2.0 / 3.0, orientation == .portrait ? 2.0 / 3.0 : 1),
            (.basics, "Two Thirds", twoThirdNames[1], twoThirdKeys[1], basicModifiers, orientation == .portrait ? 0 : 1.0 / 6.0, orientation == .portrait ? 1.0 / 6.0 : 0, orientation == .portrait ? 1 : 2.0 / 3.0, orientation == .portrait ? 2.0 / 3.0 : 1),
            (.basics, "Two Thirds", twoThirdNames[2], twoThirdKeys[2], basicModifiers, orientation == .portrait ? 0 : 1.0 / 3.0, orientation == .portrait ? 1.0 / 3.0 : 0, orientation == .portrait ? 1 : 2.0 / 3.0, orientation == .portrait ? 2.0 / 3.0 : 1),
            (.basics, "Displays", "Next Display", "→", displayModifiers, 0, 0, 1, 1),
            (.basics, "Displays", "Previous Display", "←", displayModifiers, 0, 0, 1, 1),
            (.basics, "Window", "Maximize", "Return", basicModifiers, 0, 0, 1, 1),
            (.basics, "Window", "Center", "J", basicModifiers, 0, 0, 1, 1),
            (.basics, "Window", "Restore", "Delete", basicModifiers, 0, 0, 1, 1)
        ]

        return regions.enumerated().map { index, region in
            make(
                orientation: orientation,
                group: region.group,
                section: region.section,
                name: region.name,
                key: region.key,
                x: region.x,
                y: region.y,
                width: region.width,
                height: region.height,
                position: index,
                modifiers: region.modifiers
            )
        }
    }

    private static func columnName(_ index: Int, count: Int) -> String {
        if count == 2 { return index == 0 ? "Left" : "Right" }
        if count == 3 { return ["Left", "Middle", "Right"][index] }
        return ["Left", "Center Left", "Center Right", "Right"][index]
    }
}
