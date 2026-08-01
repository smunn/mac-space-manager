//
//  WindowLayoutCheatsheet.swift
//  Space Manager
//

import AppKit
import SwiftUI

@MainActor
final class WindowLayoutCheatsheetController: NSObject, NSWindowDelegate {
    enum Presentation {
        case transient
        case window
    }

    private let presentation: Presentation
    private var window: NSWindow?

    init(presentation: Presentation = .transient) {
        self.presentation = presentation
        super.init()
    }

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
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let content = WindowLayoutCheatsheetView(
            commands: commands,
            orientation: orientation,
            activeModifiers: activeModifiers,
            isPinned: isPinned,
            allowsModifierSelection: isPinned || presentation == .window,
            keyboardStyle: keyboardStyle,
            displayName: screen.localizedName,
            displayAspectRatio: screen.frame.width / max(1, screen.frame.height),
            isBuiltInDisplay: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
            onSelectModifiers: onSelectModifiers)
        let isNewWindow = window == nil
        if let window {
            window.contentViewController = NSHostingController(rootView: content)
        } else {
            let styleMask: NSWindow.StyleMask = presentation == .window
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.titled, .nonactivatingPanel, .utilityWindow]
            let contentSize: NSSize
            let initialFrameSize: NSSize?
            if presentation == .window {
                let frameSize = optimalWindowFrameSize(for: screen)
                initialFrameSize = frameSize
                contentSize = NSWindow.contentRect(
                    forFrameRect: NSRect(origin: .zero, size: frameSize),
                    styleMask: styleMask).size
            } else {
                initialFrameSize = nil
                contentSize = metrics.windowSize
            }
            let createdWindow: NSWindow
            if presentation == .transient {
                createdWindow = NSPanel(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false)
            } else {
                createdWindow = NSWindow(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false)
            }
            createdWindow.title = "Window Layout Cheatsheet"
            createdWindow.isReleasedWhenClosed = false
            createdWindow.minSize = NSSize(width: 720, height: 500)
            createdWindow.contentViewController = NSHostingController(rootView: content)
            createdWindow.delegate = self
            if let initialFrameSize {
                createdWindow.setFrame(
                    NSRect(origin: .zero, size: initialFrameSize),
                    display: false)
            }

            if let panel = createdWindow as? NSPanel {
                panel.isFloatingPanel = true
                panel.becomesKeyOnlyIfNeeded = true
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            }
            self.window = createdWindow
        }

        if isNewWindow, let window {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2))
        }
        if presentation == .window {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func optimalWindowFrameSize(for screen: NSScreen) -> NSSize {
        let available = screen.visibleFrame.size
        let preferredAspectRatio = CGFloat(1_360.0 / 777.0)
        var width = min(1_480, max(1, available.width * 0.9))
        var height = width / preferredAspectRatio
        let maximumHeight = max(1, available.height - 32)

        if height > maximumHeight {
            height = maximumHeight
            width = height * preferredAspectRatio
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }
}

struct WindowLayoutCheatsheetView: View {
    let commands: [MagnetShortcutCommand]
    let orientation: MagnetDisplayOrientation
    let activeModifiers: Set<MagnetShortcutModifier>
    let isPinned: Bool
    let allowsModifierSelection: Bool
    let keyboardStyle: MacKeyboardStyle?
    let displayName: String
    let displayAspectRatio: CGFloat
    let isBuiltInDisplay: Bool
    let onSelectModifiers: (Set<MagnetShortcutModifier>) -> Void
    @State private var localModifiers: Set<MagnetShortcutModifier>

    init(
        commands: [MagnetShortcutCommand],
        orientation: MagnetDisplayOrientation,
        activeModifiers: Set<MagnetShortcutModifier>,
        isPinned: Bool,
        allowsModifierSelection: Bool,
        keyboardStyle: MacKeyboardStyle?,
        displayName: String,
        displayAspectRatio: CGFloat,
        isBuiltInDisplay: Bool,
        onSelectModifiers: @escaping (Set<MagnetShortcutModifier>) -> Void
    ) {
        self.commands = commands
        self.orientation = orientation
        self.activeModifiers = activeModifiers
        self.isPinned = isPinned
        self.allowsModifierSelection = allowsModifierSelection
        self.keyboardStyle = keyboardStyle
        self.displayName = displayName
        self.displayAspectRatio = displayAspectRatio
        self.isBuiltInDisplay = isBuiltInDisplay
        self.onSelectModifiers = onSelectModifiers
        _localModifiers = State(initialValue: activeModifiers)
    }

    private var selectedModifiers: Set<MagnetShortcutModifier> {
        allowsModifierSelection ? localModifiers : activeModifiers
    }

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
            $0.modifiers == selectedModifiers &&
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

    private let commandColumns = [
        GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)
    ]

    private let modifierColumns = [
        GridItem(.adaptive(minimum: 210), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        commandList
                            .padding(16)
                    }
                    .frame(width: min(660, max(340, proxy.size.width * 0.44)))

                    Divider()

                    visualGuide
                        .padding(18)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .debugLabel("windowLayoutCheatsheetView")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                headerTitle
                Spacer()
                headerDetails
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    headerTitle
                    Spacer()
                    pinnedBadge
                }
                HStack(spacing: 12) {
                    shortcutSettingsText
                    triggerText
                }
            }
        }
        .padding(14)
        .debugLabel("windowLayoutCheatsheetHeader")
    }

    private var headerTitle: some View {
        Text("Window Layouts — \(orientation.rawValue)")
            .font(.headline)
    }

    private var headerDetails: some View {
        HStack(spacing: 12) {
            shortcutSettingsText
            triggerText
            pinnedBadge
        }
    }

    private var shortcutSettingsText: some View {
        Text("Edit Shortcuts  \(WindowLayoutManager.settingsShortcutText)")
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var triggerText: some View {
        Text("Hold \(modifierText(selectedModifiers)) for 0.7 seconds; press / to show immediately or twice to pin.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var pinnedBadge: some View {
        if isPinned {
            Text("Pinned")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.18), in: Capsule())
        }
    }

    private var commandList: some View {
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
                                    let isActive = modifiers == selectedModifiers
                                    Button {
                                        localModifiers = modifiers
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
                                    .disabled(!allowsModifierSelection)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .debugLabel("windowLayoutCommandList")
    }

    private var visualGuide: some View {
        GeometryReader { proxy in
            let halfHeight = max(250, (proxy.size.height - 18) / 2)

            ScrollView {
                VStack(spacing: 18) {
                    MacDisplayLayoutGuide(
                        commands: visibleCommands,
                        colors: commandColors,
                        displayName: displayName,
                        displayAspectRatio: displayAspectRatio,
                        isBuiltInDisplay: isBuiltInDisplay)
                        .frame(height: halfHeight)

                    MacKeyboardView(
                        highlightedModifiers: selectedModifiers,
                        highlightedKeys: WindowLayoutCommandColors.keyboardHighlights(for: visibleCommands),
                        keyboardStyleOverride: keyboardStyle)
                        .frame(height: halfHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .debugLabel("windowLayoutVisualGuide")
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
