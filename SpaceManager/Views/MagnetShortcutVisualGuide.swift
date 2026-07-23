//
//  MagnetShortcutVisualGuide.swift
//  SpaceManager
//

import SwiftUI

struct MagnetShortcutVisualGuide: View {
    let commands: [MagnetShortcutCommand]
    @Binding var orientation: MagnetDisplayOrientation
    @Binding var group: MagnetShortcutGroup
    @Binding var selection: MagnetShortcutCommand.ID?
    @State private var section = ""

    private var groupCommands: [MagnetShortcutCommand] {
        commands.filter {
            $0.orientation == orientation && $0.group == group && $0.isEnabled
        }
    }

    private var sections: [String] {
        Array(Set(groupCommands.map(\.section))).sorted()
    }

    private var visibleCommands: [MagnetShortcutCommand] {
        groupCommands.filter { $0.section == section }
    }

    private var selectedCommand: MagnetShortcutCommand? {
        visibleCommands.first { $0.id == selection } ?? visibleCommands.first
    }

    private var highlightedModifiers: Set<MagnetShortcutModifier> {
        groupCommands.reduce(into: []) { $0.formUnion($1.modifiers) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    guideGrid

                    if let command = selectedCommand {
                        HStack {
                            Text(command.name)
                                .font(.headline)
                            Spacer()
                            Text(command.shortcutText)
                                .font(.system(.title2, design: .rounded, weight: .semibold))
                        }
                        .frame(maxWidth: 760)

                        MacKeyboardView(
                            highlightedModifiers: highlightedModifiers,
                            highlightedKeys: WindowLayoutSectionColors.keyboardHighlights(for: groupCommands)
                        )
                        .frame(maxWidth: 760)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { ensureSelection() }
        .onChange(of: orientation) { _ in ensureSelection() }
        .onChange(of: group) { _ in ensureSelection() }
        .debugLabel("magnetShortcutVisualGuide")
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Orientation", selection: $orientation) {
                ForEach(MagnetDisplayOrientation.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbolName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Picker("Layout", selection: $group) {
                ForEach(MagnetShortcutGroup.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            if sections.count > 1 {
                Picker("Variation", selection: $section) {
                    ForEach(sections, id: \.self) { item in
                        Text(item).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            Spacer()

            if let command = selectedCommand {
                Text(command.shortcutText)
                    .font(.system(.body, design: .rounded, weight: .semibold))
            }
        }
        .padding(12)
    }

    private var guideGrid: some View {
        let aspect: CGFloat = orientation == .portrait ? 0.62 : 1.6
        let width: CGFloat = orientation == .portrait ? 300 : 680
        let height = width / aspect

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.45), lineWidth: 1)

            ForEach(visibleCommands) { command in
                let color = WindowLayoutSectionColors.color(for: command.section)
                Button {
                    selection = command.id
                } label: {
                    GeometryReader { proxy in
                        let isSelected = selection == command.id
                        ZStack {
                            Rectangle()
                                .fill(color.opacity(isSelected ? 0.3 : 0.12))
                            Rectangle()
                                .stroke(color.opacity(isSelected ? 1 : 0.55), lineWidth: isSelected ? 2 : 1)
                            VStack(spacing: 2) {
                                Text(command.shortcutText)
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                if proxy.size.width > 100 && proxy.size.height > 50 {
                                    Text(command.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: width * command.width, height: height * command.height)
                .offset(x: width * command.x, y: height * command.y)
            }
        }
        .frame(width: width, height: height)
    }

    private func ensureSelection() {
        if !sections.contains(section) {
            section = sections.first ?? ""
        }
        if !visibleCommands.contains(where: { $0.id == selection }) {
            selection = visibleCommands.first?.id
        }
    }
}
