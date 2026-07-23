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
        screen: NSScreen
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
            commandColumnCount: metrics.commandColumnCount)
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

    private var sections: [String] {
        Array(Set(visibleCommands.map(\.section))).sorted()
    }

    private var commandColors: [String: Color] {
        WindowLayoutCommandColors.colors(for: visibleCommands)
    }

    private var commandColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 210), spacing: 12, alignment: .top),
            count: commandColumnCount)
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

                Text("\(modifierText(activeModifiers))/")
                    .font(.system(.body, design: .rounded, weight: .semibold))

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

                    VStack(spacing: 4) {
                        ForEach(modifierRows) { row in
                            let isActive = row.combinations.contains(activeModifiers)
                            HStack(spacing: 8) {
                                Text(row.group.title)
                                    .frame(width: 72, alignment: .leading)
                                Text(row.combinations.map { "\(modifierText($0))/" }.joined(separator: "   "))
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(isActive ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                isActive
                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.55)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(sections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                LazyVGrid(columns: commandColumns, alignment: .leading, spacing: 7) {
                                    ForEach(visibleCommands.filter { $0.section == section }) { command in
                                        commandRow(command)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: max(340, CGFloat(commandColumnCount) * 245))

                Divider()

                MacKeyboardView(
                    highlightedModifiers: activeModifiers,
                    highlightedKeys: WindowLayoutCommandColors.keyboardHighlights(for: visibleCommands)
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
            Text(command.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(command.shortcutText)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(commandColors[command.id] ?? .accentColor)
        }
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
        let fixedHeight = 145 + CGFloat(modifierRowCount) * 31

        var selectedColumns = 1
        var requiredHeight = maximumHeight
        for columns in 1...4 {
            let commandRows = sections.values.reduce(0) {
                $0 + Int(ceil(Double($1.count) / Double(columns)))
            }
            let candidateHeight = fixedHeight + CGFloat(sections.count) * 27 + CGFloat(commandRows) * 31
            selectedColumns = columns
            requiredHeight = candidateHeight
            if candidateHeight <= maximumHeight { break }
        }

        commandColumnCount = selectedColumns
        let desiredWidth = max(1040, 700 + CGFloat(selectedColumns) * 245)
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
