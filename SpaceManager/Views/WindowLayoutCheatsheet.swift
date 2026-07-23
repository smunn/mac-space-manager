//
//  WindowLayoutCheatsheet.swift
//  Space Manager
//

import AppKit
import SwiftUI

@MainActor
final class WindowLayoutCheatsheetController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func show(commands: [MagnetShortcutCommand], orientation: MagnetDisplayOrientation) {
        let content = WindowLayoutCheatsheetView(commands: commands, orientation: orientation)
        if let window {
            window.contentViewController = NSHostingController(rootView: content)
        } else {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false)
            panel.title = "Window Layout Cheatsheet"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(rootView: content)
            panel.delegate = self
            panel.center()
            self.window = panel
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WindowLayoutCheatsheetView: View {
    let commands: [MagnetShortcutCommand]
    let orientation: MagnetDisplayOrientation
    @State private var group: MagnetShortcutGroup = .halves

    private var availableGroups: [MagnetShortcutGroup] {
        MagnetShortcutGroup.allCases.filter { candidate in
            commands.contains { $0.orientation == orientation && $0.group == candidate }
        }
    }

    private var visibleCommands: [MagnetShortcutCommand] {
        commands.filter { $0.orientation == orientation && $0.group == group && $0.isEnabled }
    }

    private var sections: [String] {
        Array(Set(visibleCommands.map(\.section))).sorted()
    }

    private var modifiers: Set<MagnetShortcutModifier> {
        visibleCommands.reduce(into: []) { $0.formUnion($1.modifiers) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Window Layouts — \(orientation.rawValue)")
                    .font(.headline)

                Picker("Layout", selection: $group) {
                    ForEach(availableGroups) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Spacer()

                Text("⌃⌥/")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections, id: \.self) { section in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(section)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(WindowLayoutSectionColors.color(for: section))

                                ForEach(visibleCommands.filter { $0.section == section }) { command in
                                    HStack(spacing: 8) {
                                        WindowLayoutGlyph(command: command)
                                            .frame(width: 28, height: 20)
                                        Text(command.name)
                                            .lineLimit(1)
                                        Spacer(minLength: 12)
                                        Text(command.shortcutText)
                                            .font(.system(.caption, design: .rounded, weight: .semibold))
                                            .foregroundStyle(WindowLayoutSectionColors.color(for: section))
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(width: 300)

                Divider()

                MacKeyboardView(
                    highlightedModifiers: modifiers,
                    highlightedKeys: WindowLayoutSectionColors.keyboardHighlights(for: visibleCommands)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.trailing, 18)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            if !availableGroups.contains(group) {
                group = availableGroups.first ?? .halves
            }
        }
        .debugLabel("windowLayoutCheatsheetView")
    }
}
