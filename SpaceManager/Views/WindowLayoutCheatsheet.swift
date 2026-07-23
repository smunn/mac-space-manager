//
//  WindowLayoutCheatsheet.swift
//  Space Manager
//

import AppKit
import SwiftUI

@MainActor
final class WindowLayoutCheatsheetController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func show(
        commands: [MagnetShortcutCommand],
        orientation: MagnetDisplayOrientation,
        activeModifiers: Set<MagnetShortcutModifier>,
        isPinned: Bool,
        screen: NSScreen,
        keyboardStyle: MacKeyboardStyle?,
        onSelectModifiers: @escaping (Set<MagnetShortcutModifier>) -> Void
    ) {
        let orientedCommands = commands.filter {
            $0.orientation == orientation && $0.isEnabled
        }
        let visibleCommands = orientedCommands.filter { $0.modifiers == activeModifiers }
        let modifierRowCount = Set(orientedCommands.map(\.group)).count
        let metrics = WindowLayoutCheatsheetMetrics(
            commands: visibleCommands,
            modifierRowCount: modifierRowCount,
            availableSize: screen.visibleFrame.size)
        let content = WindowLayoutCheatsheetView(
            commands: commands,
            orientation: orientation,
            activeModifiers: activeModifiers,
            isPinned: isPinned,
            commandColumnCount: metrics.commandColumnCount,
            keyboardStyle: keyboardStyle,
            onSelectModifiers: onSelectModifiers)
        if let window {
            window.contentViewController = NSHostingController(rootView: content)
            window.setContentSize(metrics.windowSize)
        } else {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: metrics.windowSize),
                styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false)
            panel.title = "Window Layout Cheatsheet"
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(rootView: content)
            panel.delegate = self
            self.window = panel
        }

        if let window {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2))
        }
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct WindowLayoutCheatsheetView: View {
    let commands: [MagnetShortcutCommand]
    let orientation: MagnetDisplayOrientation
    let activeModifiers: Set<MagnetShortcutModifier>
    let isPinned: Bool
    let commandColumnCount: Int
    let keyboardStyle: MacKeyboardStyle?
    let onSelectModifiers: (Set<MagnetShortcutModifier>) -> Void

    private var modifierRows: [ModifierGroupRow] {
        MagnetShortcutGroup.allCases.compactMap { group in
            let combinations = Array(Set(commands.lazy.filter {
                $0.orientation == orientation && $0.group == group && $0.isEnabled
            }.map(\.modifiers)))
                .sorted { modifierText($0) < modifierText($1) }
            return combinations.isEmpty
                ? nil
                : ModifierGroupRow(group: group, combinations: combinations)
        }
    }

    private func modifierText(_ modifiers: Set<MagnetShortcutModifier>) -> String {
        MagnetShortcutModifier.allCases
            .filter(modifiers.contains)
            .map(\.glyph)
            .joined()
    }

    private var visibleCommands: [MagnetShortcutCommand] {
        commands.filter {
            $0.orientation == orientation &&
            $0.modifiers == activeModifiers &&
            $0.isEnabled
        }
    }

    private var visibleGroups: [MagnetShortcutGroup] {
        MagnetShortcutGroup.allCases.filter { group in
            visibleCommands.contains { $0.group == group }
        }
    }

    private func sections(in group: MagnetShortcutGroup) -> [String] {
        Array(Set(visibleCommands.lazy.filter { $0.group == group }.map(\.section))).sorted()
    }

    private var commandColors: [String: Color] {
        WindowLayoutCommandColors.colors(for: visibleCommands)
    }

    private var commandColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 280), spacing: 12, alignment: .top),
            count: commandColumnCount)
    }

    private var modifierColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 220), spacing: 10, alignment: .top),
            count: 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Window Layouts — \(orientation.rawValue)")
                    .font(.headline)

                Spacer()

                Text("Edit Shortcuts  \(WindowLayoutManager.settingsShortcutText)")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Hold \(modifierText(activeModifiers))/ to show; press twice to pin; press any combination again to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isPinned {
                    Text("Pinned")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.18), in: Capsule())
                }
            }
            .padding(14)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Modifier Combinations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: modifierColumns, alignment: .leading, spacing: 8) {
                        ForEach(modifierRows) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.group.title)
                                    .font(.subheadline.weight(.semibold))

                                ForEach(row.combinations, id: \.self) { modifiers in
                                    let isActive = modifiers == activeModifiers
                                    Button {
                                        onSelectModifiers(modifiers)
                                    } label: {
                                        HStack {
                                            KeyboardShortcutView(
                                                modifiers: modifiers,
                                                key: "/",
                                                color: isActive
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : .secondary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 5)
                                        .background(
                                            isActive
                                                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!isPinned)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(visibleGroups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .font(.headline)

                                ForEach(sections(in: group), id: \.self) { section in
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(section)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        LazyVGrid(columns: commandColumns, alignment: .leading, spacing: 7) {
                                            ForEach(visibleCommands.filter {
                                                $0.group == group && $0.section == section
                                            }) { command in
                                                commandRow(command)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: max(500, CGFloat(commandColumnCount) * 315))

                Divider()

                MacKeyboardView(
                    highlightedModifiers: activeModifiers,
                    highlightedKeys: WindowLayoutCommandColors.keyboardHighlights(for: visibleCommands),
                    keyboardStyleOverride: keyboardStyle
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.trailing, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .debugLabel("windowLayoutCheatsheetView")
    }

    private func commandRow(_ command: MagnetShortcutCommand) -> some View {
        HStack(spacing: 8) {
            WindowLayoutGlyph(
                command: command,
                color: commandColors[command.id] ?? .accentColor)
                .frame(width: 28, height: 20)
            Text(command.displayName)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            KeyboardShortcutView(
                modifiers: command.modifiers,
                key: command.destinationKey,
                color: commandColors[command.id] ?? .accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .debugLabel("windowLayoutCommandRow")
    }
}

private struct WindowLayoutCheatsheetMetrics {
    let commandColumnCount: Int
    let windowSize: NSSize

    init(
        commands: [MagnetShortcutCommand],
        modifierRowCount: Int,
        availableSize: NSSize
    ) {
        let sections = Dictionary(grouping: commands, by: \.section)
        let maximumHeight = max(500, availableSize.height - 32)
        let groupCount = Set(commands.map(\.group)).count
        let modifierGridRowCount = Int(ceil(Double(modifierRowCount) / 2))
        let fixedHeight = 194 + CGFloat(modifierGridRowCount) * 58 + CGFloat(groupCount) * 28

        var selectedColumns = 1
        var requiredHeight = maximumHeight
        let widthBasedColumnCount = max(
            1,
            min(4, Int((availableSize.width - 700) / 315)))
        for columns in 1...widthBasedColumnCount {
            let commandRows = sections.values.reduce(0) {
                $0 + Int(ceil(Double($1.count) / Double(columns)))
            }
            let candidateHeight = fixedHeight + CGFloat(sections.count) * 27 + CGFloat(commandRows) * 31
            selectedColumns = columns
            requiredHeight = candidateHeight
            if candidateHeight <= maximumHeight { break }
        }

        commandColumnCount = selectedColumns
        let desiredWidth = max(1120, 700 + CGFloat(selectedColumns) * 315)
        windowSize = NSSize(
            width: min(desiredWidth, max(900, availableSize.width - 32)),
            height: min(max(520, requiredHeight), maximumHeight))
    }
}

private struct ModifierGroupRow: Identifiable {
    let group: MagnetShortcutGroup
    let combinations: [Set<MagnetShortcutModifier>]

    var id: MagnetShortcutGroup { group }
}
