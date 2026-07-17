import AppKit
import Carbon
import Combine
import SwiftUI

let spaceManagerHotKeySignature: OSType = 0x5350534C // SPSL

@MainActor
final class SpaceLabelController: NSObject, NSWindowDelegate {
    static private(set) var shared: SpaceLabelController?

    private let manager = SpaceLabelStore.shared
    private var panels: [String: NSPanel] = [:]
    private var spaceIDsByPanel: [ObjectIdentifier: String] = [:]
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var idleMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var currentSpaces: [Space] = []

    override init() {
        super.init()
        Self.shared = self

        NotificationCenter.default.publisher(for: .spaceLabelCurrentSpaceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.spaceDidChange() }
            .store(in: &cancellables)

        registerHotKey()
        registerIdleMouseMonitor()
        spaceDidChange()
    }

    func editCurrentSpace() {
        guard let space = interactiveCurrentSpace() else { return }
        manager.updateCurrentSpace(space)
        edit(spaceID: space.spaceID)
    }

    func updateSpaces(_ spaces: [Space]) {
        currentSpaces = spaces
        manager.updateCurrentSpace(interactiveCurrentSpace())

        for space in spaces where space.isCurrentSpace && !manager.label(for: space.spaceID).isEmpty {
            let panel = panel(for: space.spaceID)
            restoreFrame(of: panel, for: space.spaceID)
            updateVisibility(of: panel, for: space.spaceID)
        }
    }

    func recentLabelsForCurrentSpace() -> [RecentSpaceLabel] {
        guard let space = interactiveCurrentSpace() else { return [] }
        return manager.recentLabels(for: space.spaceID)
    }

    func loadRecentInCurrentSpace(_ recent: RecentSpaceLabel) {
        guard let space = interactiveCurrentSpace() else { return }
        manager.updateCurrentSpace(space)
        loadRecent(recent, in: space.spaceID)
    }

    func loadRecentInCurrentSpace(id: String) {
        guard let recent = recentLabelsForCurrentSpace().first(where: { $0.id == id }) else { return }
        loadRecentInCurrentSpace(recent)
    }

    func removeCurrentLabel() {
        guard let space = interactiveCurrentSpace() else { return }
        removeLabel(from: space.spaceID)
    }

    func hasCurrentLabel() -> Bool {
        guard let space = interactiveCurrentSpace() else { return false }
        return !manager.label(for: space.spaceID).isEmpty
    }

    func edit(spaceID: String) {
        guard !spaceID.isEmpty else { return }
        manager.beginEditing(spaceID: spaceID)
        let panel = panel(for: spaceID)
        restoreFrame(of: panel, for: spaceID)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .focusSpaceLabel, object: spaceID)
    }

    func finishEditing(spaceID: String) {
        guard manager.editingSpaceID == spaceID else { return }
        manager.endEditing(spaceID: spaceID)
        manager.commitLabel(for: spaceID)
        guard let panel = panels[spaceID] else { return }
        panel.resignKey()
        updateVisibility(of: panel, for: spaceID)
    }

    func cancelEditing(spaceID: String) {
        guard manager.editingSpaceID == spaceID else { return }
        manager.endEditing(spaceID: spaceID)
        guard let panel = panels[spaceID] else { return }
        panel.resignKey()
        updateVisibility(of: panel, for: spaceID)
    }

    func loadRecent(_ recent: RecentSpaceLabel, in spaceID: String) {
        manager.loadRecentLabel(recent, for: spaceID)
        guard let panel = panels[spaceID] else { return }
        restoreFrame(of: panel, for: spaceID)
        panel.orderFrontRegardless()
    }

    func removeLabel(from spaceID: String) {
        manager.removeLabel(from: spaceID)
        panels[spaceID]?.orderOut(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let spaceID = spaceIDsByPanel[ObjectIdentifier(panel)] else { return }
        manager.saveFrame(panel.frame, for: spaceID)
    }

    private func spaceDidChange() {
        if let editingSpaceID = manager.editingSpaceID {
            manager.endEditing(spaceID: editingSpaceID)
        }
        guard let spaceID = manager.currentSpaceID, !spaceID.isEmpty else { return }
        let panel = panel(for: spaceID)
        updateVisibility(of: panel, for: spaceID)
    }

    private func panel(for spaceID: String) -> NSPanel {
        if let existing = panels[spaceID] { return existing }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 48),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SpaceLabelView(spaceID: spaceID, manager: manager))

        panels[spaceID] = panel
        spaceIDsByPanel[ObjectIdentifier(panel)] = spaceID
        restoreFrame(of: panel, for: spaceID)
        return panel
    }

    private func restoreFrame(of panel: NSPanel, for spaceID: String) {
        if let frame = manager.frame(for: spaceID), frame.intersectsVisibleScreen {
            panel.setFrame(frame, display: true)
        } else if let screen = screen(for: spaceID) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            ))
        }
    }

    private func interactiveCurrentSpace() -> Space? {
        let displayIDs = Array(Set(currentSpaces.map(\.displayID)))
        let displayID = DisplayGeometryUtilities.displayUUID(
            containing: NSEvent.mouseLocation,
            candidates: displayIDs)
            ?? DisplayGeometryUtilities.activeDisplayUUID(from: displayIDs)
        if let displayID,
           let space = currentSpaces.first(where: { $0.displayID == displayID && $0.isCurrentSpace }) {
            return space
        }
        return currentSpaces.first(where: \.isCurrentSpace)
    }

    private func screen(for spaceID: String) -> NSScreen? {
        guard let space = currentSpaces.first(where: { $0.spaceID == spaceID }) else { return nil }
        return DisplayGeometryUtilities.screen(for: space.displayID)
    }

    private func updateVisibility(of panel: NSPanel, for spaceID: String) {
        let isEditing = manager.editingSpaceID == spaceID
        if isEditing || !manager.label(for: spaceID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func showCustomizationMenu(spaceID: String, event: NSEvent, from view: NSView) {
        NSMenu.popUpContextMenu(contextMenu(for: spaceID), with: event, for: view)
    }

    private func registerIdleMouseMonitor() {
        idleMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let panel = event.window as? NSPanel,
                  let spaceID = self.spaceIDsByPanel[ObjectIdentifier(panel)],
                  self.manager.editingSpaceID != spaceID,
                  let contentView = panel.contentView else { return event }

            let handleWidth: CGFloat = 40
            let locationX = event.locationInWindow.x
            let handleSide = self.manager.handleSide(for: spaceID)
            let clickedHandle = handleSide == .left
                ? locationX <= handleWidth
                : locationX >= panel.frame.width - handleWidth

            if clickedHandle {
                self.trackHandleInteraction(
                    spaceID: spaceID,
                    panel: panel,
                    initialEvent: event,
                    contentView: contentView
                )
            } else {
                panel.performDrag(with: event)
            }
            return nil
        }
    }

    private func trackHandleInteraction(
        spaceID: String,
        panel: NSPanel,
        initialEvent: NSEvent,
        contentView: NSView
    ) {
        let initialMouseLocation = NSEvent.mouseLocation
        let initialWindowOrigin = panel.frame.origin
        var didDrag = false

        while let event = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let mouseLocation = NSEvent.mouseLocation
            let deltaX = mouseLocation.x - initialMouseLocation.x
            let deltaY = mouseLocation.y - initialMouseLocation.y

            if event.type == .leftMouseDragged {
                if !didDrag, hypot(deltaX, deltaY) >= 3 {
                    didDrag = true
                }
                if didDrag {
                    panel.setFrameOrigin(NSPoint(
                        x: initialWindowOrigin.x + deltaX,
                        y: initialWindowOrigin.y + deltaY
                    ))
                }
            }

            if event.type == .leftMouseUp {
                break
            }
        }

        if !didDrag {
            showCustomizationMenu(spaceID: spaceID, event: initialEvent, from: contentView)
        }
    }

    private func contextMenu(for spaceID: String) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(title: "Edit", action: #selector(editFromContextMenu(_:)), spaceID: spaceID))

        let recentMenu = NSMenu()
        let recents = manager.recentLabels(for: spaceID)
        if recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Labels", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for recent in recents {
                let item = NSMenuItem(title: recent.label, action: #selector(loadRecentFromContextMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SpaceMenuSelection(spaceID: spaceID, value: recent.id)
                recentMenu.addItem(item)
            }
        }
        let recentItem = NSMenuItem(title: "Load Recent Label", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let themeMenu = NSMenu()
        for theme in SpaceLabelTheme.allCases {
            let item = NSMenuItem(title: theme.name, action: #selector(setThemeFromContextMenu(_:)), keyEquivalent: "")
            item.target = self
            item.state = manager.theme(for: spaceID) == theme ? .on : .off
            item.representedObject = SpaceMenuSelection(spaceID: spaceID, value: theme.rawValue)
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let handleMenu = NSMenu()
        for side in SpaceLabelHandleSide.allCases {
            let item = NSMenuItem(title: side.name, action: #selector(setHandleSideFromContextMenu(_:)), keyEquivalent: "")
            item.target = self
            item.state = manager.handleSide(for: spaceID) == side ? .on : .off
            item.representedObject = SpaceMenuSelection(spaceID: spaceID, value: side.rawValue)
            handleMenu.addItem(item)
        }
        let handleItem = NSMenuItem(title: "Handle Position", action: nil, keyEquivalent: "")
        handleItem.submenu = handleMenu
        menu.addItem(handleItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Remove from Space", action: #selector(removeFromContextMenu(_:)), spaceID: spaceID))
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Space Manager", action: #selector(quitFromContextMenu), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func menuItem(title: String, action: Selector, spaceID: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = spaceID
        return item
    }

    @objc private func editFromContextMenu(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? String else { return }
        edit(spaceID: spaceID)
    }

    @objc private func loadRecentFromContextMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SpaceMenuSelection,
              let recent = manager.recentLabels(for: selection.spaceID).first(where: { $0.id == selection.value }) else { return }
        loadRecent(recent, in: selection.spaceID)
    }

    @objc private func setThemeFromContextMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SpaceMenuSelection,
              let theme = SpaceLabelTheme(rawValue: selection.value) else { return }
        manager.setTheme(theme, for: selection.spaceID)
    }

    @objc private func setHandleSideFromContextMenu(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? SpaceMenuSelection,
              let side = SpaceLabelHandleSide(rawValue: selection.value) else { return }
        manager.setHandleSide(side, for: selection.spaceID)
    }

    @objc private func removeFromContextMenu(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? String else { return }
        removeLabel(from: spaceID)
    }

    @objc private func quitFromContextMenu() {
        NSApp.terminate(nil)
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                guard let event,
                      GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                      ) == noErr else {
                    return OSStatus(eventNotHandledErr)
                }

                guard hotKeyID.signature == spaceManagerHotKeySignature else {
                    WindowMoveLog.write(
                        "Ignored hotkey signature=\(String(format: "%08X", hotKeyID.signature)) id=\(hotKeyID.id)")
                    return OSStatus(eventNotHandledErr)
                }

                WindowMoveLog.write("Received hotkey id=\(hotKeyID.id)")

                switch hotKeyID.id {
                case 1:
                    Task { @MainActor in
                        SpaceLabelController.shared?.editCurrentSpace()
                    }
                    return noErr
                case 2:
                    WindowMoveLog.write("Dispatching move-window shortcut")
                    Task { @MainActor in
                        WindowMoveController.shared?.showMoveMenu()
                    }
                    return noErr
                default:
                    return OSStatus(eventNotHandledErr)
                }
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: spaceManagerHotKeySignature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}

private struct SpaceLabelView: View {
    let spaceID: String
    @ObservedObject var manager: SpaceLabelStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if manager.handleSide(for: spaceID) == .left {
                handle
            }

            if manager.editingSpaceID == spaceID {
                TextField(
                    "",
                    text: Binding(
                        get: { manager.label(for: spaceID) },
                        set: { manager.updateLabel($0, for: spaceID) }
                    ),
                    prompt: Text(manager.currentSpaceID == spaceID ? manager.suggestedLabel : "")
                )
                .textFieldStyle(.plain)
                .focused($isFocused)
            } else {
                Text(manager.label(for: spaceID))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if manager.handleSide(for: spaceID) == .right {
                handle
            }
        }
        .font(.system(size: 15, weight: .medium))
        .lineLimit(1)
        .padding(manager.handleSide(for: spaceID) == .left ? .trailing : .leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            if let tint = tintColor {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(manager.theme(for: spaceID) == .yellow ? 0.34 : 0.24))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .preferredColorScheme(preferredColorScheme)
        .onSubmit {
            SpaceLabelController.shared?.finishEditing(spaceID: spaceID)
        }
        .onExitCommand {
            SpaceLabelController.shared?.cancelEditing(spaceID: spaceID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSpaceLabel)) { notification in
            guard (notification.object as? String) == spaceID else { return }
            isFocused = true
        }
        .debugLabel("spaceLabelView")
    }

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
    }

    private var preferredColorScheme: ColorScheme? {
        switch manager.theme(for: spaceID) {
        case .light, .yellow: return .light
        case .dark: return .dark
        case .system, .blue: return nil
        }
    }

    private var tintColor: Color? {
        switch manager.theme(for: spaceID) {
        case .blue: return .blue
        case .yellow: return .yellow
        case .system, .light, .dark: return nil
        }
    }
}

private final class SpaceMenuSelection: NSObject {
    let spaceID: String
    let value: String

    init(spaceID: String, value: String) {
        self.spaceID = spaceID
        self.value = value
    }
}

private extension NSRect {
    var intersectsVisibleScreen: Bool {
        NSScreen.screens.contains { intersects($0.visibleFrame) }
    }
}

extension Notification.Name {
    static let focusSpaceLabel = Notification.Name("focusSpaceLabel")
}
