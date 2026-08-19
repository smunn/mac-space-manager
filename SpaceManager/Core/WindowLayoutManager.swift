//
//  WindowLayoutManager.swift
//  Space Manager
//
//  Runs the user's saved Magnet-compatible shortcut map natively. Magnet's
//  private plist is only an import source; window movement uses Accessibility.
//

import ApplicationServices
import Carbon
import Cocoa

struct WindowLayoutShortcutConflict: Equatable, Identifiable {
    let shortcutText: String
    let commandIDs: Set<String>
    let commandNames: [String]
    let ownerName: String?

    var id: String {
        ([shortcutText] + commandIDs.sorted()).joined(separator: "|")
    }

    var description: String {
        let names = commandNames.joined(separator: ", ")
        let commandDescription = names.isEmpty ? shortcutText : "\(shortcutText) — \(names)"
        guard let ownerName else { return commandDescription }
        return "\(commandDescription) (used by \(ownerName))"
    }
}

@MainActor
final class WindowLayoutManager: NSObject, ObservableObject {
    static let shared = WindowLayoutManager()
    static let enabledDefaultsKey = "windowLayoutsEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isMagnetRunning: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var shortcutConflicts: [WindowLayoutShortcutConflict] = []

    private static let hotKeySignature: OSType = 0x53574C59 // SWLY
    private static let settingsHotKeyID: UInt32 = 990
    private static let cheatsheetDoubleTapInterval: TimeInterval = 0.45
    private static let cheatsheetModifierHoldInterval: TimeInterval = 0.7
    static let settingsShortcutText = "⌃⌥⌘,"
    private static let settingsShortcut = MagnetShortcut(
        carbonKeyCode: 43,
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
    private var commands: [MagnetShortcutCommand] = []
    private var commandsByHotKeyID: [UInt32: [MagnetDisplayOrientation: MagnetShortcutCommand]] = [:]
    private var cheatsheetModifierSets: Set<Set<MagnetShortcutModifier>> = []
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var cheatsheetEventTap: CFMachPort?
    private var cheatsheetEventTapSource: CFRunLoopSource?
    private var cheatsheetEventTapContext: CheatsheetEventTapContext?
    private var observers: [NSObjectProtocol] = []
    private var magnetMonitor: Timer?
    private weak var lastExternalApplication: NSRunningApplication?
    private var restoreSequences: [WindowIdentity: WindowLayoutRestoreSequence] = [:]
    private var appWindowRestoreFrames: [Int: CGRect] = [:]
    private var cheatsheetController: WindowLayoutCheatsheetController?
    private var manualCheatsheetController: WindowLayoutCheatsheetController?
    private var manualCheatsheetModifiers: Set<MagnetShortcutModifier>?
    private let keyboardInputDeviceMonitor = KeyboardInputDeviceMonitor()
    private var activeCheatsheetKeyboardStyle: MacKeyboardStyle?
    private var cheatsheetShortcutIsDown = false
    private var activeCheatsheetModifiers: Set<MagnetShortcutModifier>?
    private var cheatsheetIsPinned = false
    private var lastCheatsheetPress: (modifiers: Set<MagnetShortcutModifier>, timestamp: TimeInterval)?
    private var currentCheatsheetModifiers: Set<MagnetShortcutModifier> = []
    private var pendingCheatsheetHoldModifiers: Set<MagnetShortcutModifier>?
    private var activeCheatsheetHoldModifiers: Set<MagnetShortcutModifier>?
    private var cheatsheetHoldIsBlocked = false
    private var cheatsheetHoldTask: Task<Void, Never>?
    private var interactionMonitors: [Any] = []
    private var lastMouseInteraction: InteractionTarget?
    private var lastKeyboardInteraction: InteractionTarget?

    private override init() {
        let requested = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        isEnabled = false
        isMagnetRunning = false
        super.init()

        keyboardInputDeviceMonitor.onSlashStyle = { [weak self] style in
            Task { @MainActor in
                self?.updateCheatsheetKeyboardStyle(style)
            }
        }
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        observeApplications()
        observeUserInteraction()
        observeConfigurationChanges()
        magnetMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMagnetStatus() }
        }
        refreshMagnetStatus()
        commands = (try? loadCommands()) ?? MagnetShortcutCommand.standardSet

        if requested {
            if magnetIsRunning() {
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                lastError = "Quit Magnet before enabling Window Layouts."
            } else {
                do {
                    try enable()
                } catch {
                    UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                    lastError = error.localizedDescription
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        if enabled {
            if isMagnetRunning {
                lastError = "Conflict: Magnet is running."
                return
            }
            do {
                try enable()
            } catch {
                disable()
                lastError = error.localizedDescription
            }
        } else {
            disable()
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: "Enable Window Layouts",
            action: #selector(toggleFromMenu(_:)),
            keyEquivalent: "")
        toggle.target = self
        toggle.state = isEnabled ? .on : .off
        menu.addItem(toggle)

        let cheatsheet = NSMenuItem(
            title: "Open Cheatsheet…",
            action: #selector(openCheatsheetFromMenu),
            keyEquivalent: "")
        cheatsheet.target = self
        menu.addItem(cheatsheet)

        let settings = NSMenuItem(title: "Edit Shortcuts — \(Self.settingsShortcutText)", action: nil, keyEquivalent: "")
        settings.isEnabled = false
        menu.addItem(settings)

        if !shortcutConflicts.isEmpty {
            menu.addItem(.separator())
            addHeader("Shortcut Conflicts", to: menu)
            for conflict in shortcutConflicts {
                let item = NSMenuItem(title: conflict.description, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let orientation: MagnetDisplayOrientation = focusedWindow().map {
            self.orientation(for: screen(containing: $0.frame))
        } ?? MagnetDisplayOrientation.horizontal
        let available = commands.filter { $0.orientation == orientation }
        let sectionOrder = ["Halves", "Corners", "Thirds", "Two Thirds", "Full Width", "Full Height", "Grid", "Displays", "Window"]
        let grouped = Dictionary(grouping: available, by: \.section)

        for section in sectionOrder where grouped[section] != nil {
            menu.addItem(.separator())
            addHeader(section, to: menu)
            for command in grouped[section, default: []] {
                let item = NSMenuItem(
                    title: command.displayName,
                    action: #selector(applyMenuCommand(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = command.id
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }

        let remainingSections = grouped.keys.filter { !sectionOrder.contains($0) }.sorted()
        for section in remainingSections {
            menu.addItem(.separator())
            addHeader(section, to: menu)
            for command in grouped[section, default: []] {
                let item = NSMenuItem(title: command.displayName, action: #selector(applyMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.id
                item.isEnabled = isEnabled
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        setEnabled(!isEnabled)
        sender.state = isEnabled ? .on : .off
        if let lastError {
            let alert = NSAlert()
            alert.messageText = "Window Layouts Could Not Be Enabled"
            alert.informativeText = lastError
            alert.alertStyle = .warning
            alert.runModal()
        } else if isEnabled && !shortcutConflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Window Layouts Enabled with Conflicts"
            alert.informativeText = shortcutConflicts.map(\.description).joined(separator: "\n")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func openCheatsheetFromMenu() {
        let targetScreen = cheatsheetTargetScreen()
        let orientation = self.orientation(for: targetScreen)
        let availableCommands = commands.filter {
            $0.orientation == orientation && $0.isEnabled
        }
        let availableModifiers = Set(availableCommands.map(\.modifiers))
        guard !availableModifiers.isEmpty else { return }

        let modifiers: Set<MagnetShortcutModifier>
        if let manualCheatsheetModifiers,
           availableModifiers.contains(manualCheatsheetModifiers) {
            modifiers = manualCheatsheetModifiers
        } else if availableModifiers.contains(MagnetShortcutGroup.halves.modifiers) {
            modifiers = MagnetShortcutGroup.halves.modifiers
        } else {
            modifiers = availableModifiers.sorted {
                Self.carbonModifiers(for: $0) < Self.carbonModifiers(for: $1)
            }[0]
        }

        manualCheatsheetModifiers = modifiers
        if manualCheatsheetController == nil {
            manualCheatsheetController = WindowLayoutCheatsheetController(presentation: .window)
        }
        manualCheatsheetController?.show(
            commands: commands,
            orientation: orientation,
            activeModifiers: modifiers,
            isPinned: false,
            screen: targetScreen,
            keyboardStyle: nil,
            onSelectModifiers: { [weak self] selectedModifiers in
                self?.manualCheatsheetModifiers = selectedModifiers
            })
    }

    @objc private func applyMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let window = focusedWindow(),
              let command = commands.first(where: { $0.id == id && $0.orientation == orientation(for: screen(containing: window.frame)) })
        else { return }
        apply(command, to: window)
    }

    private func enable() throws {
        guard AppPermissions.check(.accessibility) else {
            throw WindowLayoutError.permissionRequired(.accessibility)
        }
        guard !magnetIsRunning() else { throw WindowLayoutError.magnetRunning }
        commands = try loadCommands()
        guard commands.contains(where: \.isEnabled) else { throw WindowLayoutError.noCommands }
        try registerHotKeys()
        guard !magnetIsRunning() else {
            unregisterHotKeys()
            throw WindowLayoutError.magnetRunning
        }
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
    }

    private func disable() {
        unregisterHotKeys()
        shortcutConflicts = []
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
    }

    private func loadCommands() throws -> [MagnetShortcutCommand] {
        if let commands = try WindowLayoutShortcutStore.shared.load() {
            return commands
        }
        if let configuration = try MagnetShortcutManager.shared.loadDraft() {
            let commands = MagnetShortcutEditorAdapter().editorCommands(from: configuration)
            try WindowLayoutShortcutStore.shared.save(commands)
            return commands
        }
        if let configuration = try? MagnetShortcutManager.shared.loadMagnetConfiguration() {
            _ = try? MagnetShortcutManager.shared.saveDraft(configuration)
            let commands = MagnetShortcutEditorAdapter().editorCommands(from: configuration)
            try WindowLayoutShortcutStore.shared.save(commands)
            return commands
        }
        let commands = MagnetShortcutCommand.standardSet
        try WindowLayoutShortcutStore.shared.save(commands)
        return commands
    }

    private func registerHotKeys() throws {
        unregisterHotKeys()
        shortcutConflicts = []
        var routes: [MagnetShortcut: [MagnetDisplayOrientation: MagnetShortcutCommand]] = [:]
        for command in commands where command.isEnabled {
            for shortcut in shortcuts(for: command) {
                if shortcut.carbonKeyCode == 44 {
                    throw WindowLayoutError.reservedShortcutConflict("modifier + /")
                }
                if shortcut == Self.settingsShortcut {
                    throw WindowLayoutError.reservedShortcutConflict(Self.settingsShortcutText)
                }
                if routes[shortcut]?[command.orientation] != nil {
                    throw WindowLayoutError.duplicateShortcut(command.shortcutText)
                }
                routes[shortcut, default: [:]][command.orientation] = command
            }
        }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = eventTypes.withUnsafeMutableBufferPointer { types in
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
                            &hotKeyID) == noErr,
                          hotKeyID.signature == WindowLayoutManager.hotKeySignature
                    else { return OSStatus(eventNotHandledErr) }
                    let kind = GetEventKind(event)
                    Task { @MainActor in
                        WindowLayoutManager.shared.handleHotKey(
                            hotKeyID.id,
                            isPressed: kind == UInt32(kEventHotKeyPressed))
                    }
                    return noErr
                },
                types.count,
                types.baseAddress,
                nil,
                &eventHandler)
        }
        guard status == noErr else { throw WindowLayoutError.eventHandlerRegistration(status) }

        let modifierSets = Set(commands.lazy.filter(\.isEnabled).map(\.modifiers))
            .filter { $0.count >= 2 }
            .sorted { Self.carbonModifiers(for: $0) < Self.carbonModifiers(for: $1) }
        cheatsheetModifierSets = Set(modifierSets)
        installCheatsheetEventTap(for: cheatsheetModifierSets)
        keyboardInputDeviceMonitor.start()

        var settingsReference: EventHotKeyRef?
        let settingsRegistration = RegisterEventHotKey(
            Self.settingsShortcut.carbonKeyCode,
            Self.settingsShortcut.carbonModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.settingsHotKeyID),
            GetApplicationEventTarget(),
            0,
            &settingsReference)
        if settingsRegistration == noErr, let settingsReference {
            hotKeys.append(settingsReference)
        } else if settingsRegistration == eventHotKeyExistsErr {
            shortcutConflicts.append(WindowLayoutShortcutConflict(
                shortcutText: Self.settingsShortcutText,
                commandIDs: [],
                commandNames: ["Edit Shortcuts"],
                ownerName: nil))
        } else {
            unregisterHotKeys()
            throw WindowLayoutError.hotKeyRegistration(Self.settingsShortcutText, settingsRegistration)
        }

        for (index, entry) in routes.sorted(by: { lhs, rhs in
            lhs.key.carbonModifiers == rhs.key.carbonModifiers
                ? lhs.key.carbonKeyCode < rhs.key.carbonKeyCode
                : lhs.key.carbonModifiers < rhs.key.carbonModifiers
        }).enumerated() {
            let id = UInt32(index + 1000)
            var reference: EventHotKeyRef?
            let registration = RegisterEventHotKey(
                entry.key.carbonKeyCode,
                entry.key.carbonModifiers,
                EventHotKeyID(signature: Self.hotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference)
            if registration == eventHotKeyExistsErr {
                let routeCommands = Array(entry.value.values)
                shortcutConflicts.append(WindowLayoutShortcutConflict(
                    shortcutText: routeCommands.first?.shortcutText ?? "Unknown",
                    commandIDs: Set(routeCommands.map(\.id)),
                    commandNames: Array(Set(routeCommands.map(\.displayName))).sorted(),
                    ownerName: Self.internalShortcutOwner(for: entry.key)))
                continue
            }
            guard registration == noErr, let reference else {
                unregisterHotKeys()
                throw WindowLayoutError.hotKeyRegistration(entry.value.values.first?.shortcutText ?? "Unknown", registration)
            }
            hotKeys.append(reference)
            commandsByHotKeyID[id] = entry.value
        }
    }

    private func unregisterHotKeys() {
        hideCheatsheet()
        removeCheatsheetEventTap()
        keyboardInputDeviceMonitor.stop()
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        commandsByHotKeyID.removeAll()
        cheatsheetModifierSets.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleHotKey(_ id: UInt32, isPressed: Bool) {
        if id == Self.settingsHotKeyID {
            guard isPressed else { return }
            hideCheatsheet()
            if let url = URL(string: "spacemanager://window-layout-shortcuts") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard isPressed else { return }
        guard isEnabled else { return }

        // Space Manager owns these global shortcuts, so macOS never gets a
        // second chance to apply its standard Move & Resize command. Route the
        // command to our own key window instead of falling back to the last
        // external application when Create Issue or Settings is active.
        if let appWindow = NSApp.keyWindow,
           appWindow.isVisible,
           appWindow.styleMask.contains(.resizable),
           let screen = appWindow.screen {
            let orientation = orientation(for: screen)
            guard let command = commandsByHotKeyID[id]?[orientation] else { return }
            apply(command, to: appWindow, on: screen)
            return
        }

        guard let window = focusedWindow() else { return }
        let orientation = orientation(for: screen(containing: window.frame))
        guard let command = commandsByHotKeyID[id]?[orientation] else { return }
        apply(command, to: window)
    }

    fileprivate func handleCheatsheetKey(
        modifiers: Set<MagnetShortcutModifier>,
        isPressed: Bool
    ) {
        if isPressed {
            guard !cheatsheetShortcutIsDown else { return }
            cheatsheetShortcutIsDown = true
            cancelPendingCheatsheetHold(blockCurrentHold: true)
            let now = ProcessInfo.processInfo.systemUptime

            if cheatsheetIsPinned {
                lastCheatsheetPress = nil
                hideCheatsheet()
                return
            }

            let isDoubleTap = lastCheatsheetPress.map {
                $0.modifiers == modifiers && now - $0.timestamp <= Self.cheatsheetDoubleTapInterval
            } ?? false
            lastCheatsheetPress = (modifiers, now)
            activeCheatsheetModifiers = modifiers
            if isDoubleTap {
                cheatsheetIsPinned = true
                activeCheatsheetHoldModifiers = nil
            }
            showCheatsheet(modifiers: modifiers)
        } else {
            cheatsheetShortcutIsDown = false
            if !cheatsheetIsPinned && activeCheatsheetHoldModifiers == nil {
                dismissCheatsheetWindow()
            }
        }
    }

    fileprivate func handleCheatsheetModifiersChanged(
        _ modifiers: Set<MagnetShortcutModifier>
    ) {
        guard modifiers != currentCheatsheetModifiers else { return }
        currentCheatsheetModifiers = modifiers
        cheatsheetHoldIsBlocked = false
        cancelPendingCheatsheetHold()

        if activeCheatsheetHoldModifiers != nil {
            activeCheatsheetHoldModifiers = nil
            if !cheatsheetShortcutIsDown && !cheatsheetIsPinned {
                dismissCheatsheetWindow()
            }
        }

        guard isEnabled,
              !cheatsheetIsPinned,
              !cheatsheetShortcutIsDown,
              cheatsheetModifierSets.contains(modifiers)
        else { return }
        scheduleCheatsheetHold(for: modifiers)
    }

    fileprivate func handleCheatsheetNonModifierKeyDown() {
        guard activeCheatsheetHoldModifiers == nil else { return }
        cancelPendingCheatsheetHold(blockCurrentHold: true)
    }

    private func scheduleCheatsheetHold(
        for modifiers: Set<MagnetShortcutModifier>
    ) {
        guard !cheatsheetHoldIsBlocked else { return }
        pendingCheatsheetHoldModifiers = modifiers
        cheatsheetHoldTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.cheatsheetModifierHoldInterval * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  self.isEnabled,
                  !self.cheatsheetHoldIsBlocked,
                  !self.cheatsheetIsPinned,
                  !self.cheatsheetShortcutIsDown,
                  self.currentCheatsheetModifiers == modifiers,
                  self.pendingCheatsheetHoldModifiers == modifiers
            else { return }
            self.pendingCheatsheetHoldModifiers = nil
            self.cheatsheetHoldTask = nil
            self.activeCheatsheetHoldModifiers = modifiers
            self.activeCheatsheetModifiers = modifiers
            self.showCheatsheet(modifiers: modifiers)
        }
    }

    private func cancelPendingCheatsheetHold(blockCurrentHold: Bool = false) {
        cheatsheetHoldTask?.cancel()
        cheatsheetHoldTask = nil
        pendingCheatsheetHoldModifiers = nil
        if blockCurrentHold {
            cheatsheetHoldIsBlocked = true
        }
    }

    private func installCheatsheetEventTap(
        for modifierSets: Set<Set<MagnetShortcutModifier>>
    ) {
        removeCheatsheetEventTap()
        guard !modifierSets.isEmpty else { return }

        let context = CheatsheetEventTapContext(modifierSets: modifierSets)
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: cheatsheetEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque())
        else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        cheatsheetEventTapContext = context
        cheatsheetEventTap = tap
        cheatsheetEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeCheatsheetEventTap() {
        if let source = cheatsheetEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = cheatsheetEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        cheatsheetEventTapSource = nil
        cheatsheetEventTap = nil
        cheatsheetEventTapContext = nil
    }

    fileprivate func reenableCheatsheetEventTap() {
        if let tap = cheatsheetEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func apply(_ command: MagnetShortcutCommand, to window: FocusedWindow) {
        let operation = Self.operation(for: command.name)
        if operation == .restore {
            guard let sequence = restoreSequences[window.identity],
                  set(frame: sequence.originalFrame, for: window.element, attemptsRemaining: 3)
            else { return }
            restoreSequences.removeValue(forKey: window.identity)
            return
        }

        let sourceScreen = screen(containing: window.frame)
        let target: CGRect
        if operation == .nextDisplay || operation == .previousDisplay {
            guard let destination = adjacentScreen(from: sourceScreen, next: operation == .nextDisplay) else { return }
            target = translatedFrame(window.frame, from: sourceScreen, to: destination)
        } else if operation == .center {
            let visible = accessibilityVisibleFrame(for: sourceScreen)
            let size = CGSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
            target = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        } else if operation == .maximize {
            target = accessibilityVisibleFrame(for: sourceScreen)
        } else {
            let visible = accessibilityVisibleFrame(for: sourceScreen)
            target = CGRect(
                x: visible.minX + visible.width * command.x,
                y: visible.minY + visible.height * command.y,
                width: visible.width * command.width,
                height: visible.height * command.height).integral
        }
        guard set(frame: target, for: window.element, attemptsRemaining: 3) else { return }

        if var sequence = restoreSequences[window.identity] {
            sequence.recordAppliedMove(from: window.frame, to: target)
            restoreSequences[window.identity] = sequence
        } else {
            restoreSequences[window.identity] = WindowLayoutRestoreSequence(
                originalFrame: window.frame,
                lastAppliedFrame: target)
        }
    }

    private func apply(_ command: MagnetShortcutCommand, to window: NSWindow, on sourceScreen: NSScreen) {
        let operation = Self.operation(for: command.name)
        let windowNumber = window.windowNumber

        if operation == .restore {
            guard let originalFrame = appWindowRestoreFrames.removeValue(forKey: windowNumber) else { return }
            window.setFrame(originalFrame, display: true, animate: true)
            return
        }

        let visible = sourceScreen.visibleFrame
        let target: CGRect
        if operation == .nextDisplay || operation == .previousDisplay {
            guard let destination = adjacentScreen(
                from: sourceScreen,
                next: operation == .nextDisplay)
            else { return }
            let destinationFrame = destination.visibleFrame
            let x = visible.width > 0 ? (window.frame.minX - visible.minX) / visible.width : 0
            let y = visible.height > 0 ? (window.frame.minY - visible.minY) / visible.height : 0
            let width = min(
                destinationFrame.width,
                window.frame.width / max(visible.width, 1) * destinationFrame.width)
            let height = min(
                destinationFrame.height,
                window.frame.height / max(visible.height, 1) * destinationFrame.height)
            target = CGRect(
                x: min(destinationFrame.maxX - width, max(destinationFrame.minX, destinationFrame.minX + x * destinationFrame.width)),
                y: min(destinationFrame.maxY - height, max(destinationFrame.minY, destinationFrame.minY + y * destinationFrame.height)),
                width: width,
                height: height).integral
        } else if operation == .center {
            let size = CGSize(
                width: min(window.frame.width, visible.width),
                height: min(window.frame.height, visible.height))
            target = CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height).integral
        } else if operation == .maximize {
            target = visible
        } else {
            // Magnet target coordinates are top-origin; AppKit window frames
            // are bottom-origin.
            target = CGRect(
                x: visible.minX + visible.width * command.x,
                y: visible.maxY - visible.height * (command.y + command.height),
                width: visible.width * command.width,
                height: visible.height * command.height).integral
        }

        if appWindowRestoreFrames[windowNumber] == nil {
            appWindowRestoreFrames[windowNumber] = window.frame
        }
        window.setFrame(target, display: true, animate: true)
    }

    static func operation(for name: String) -> WindowLayoutOperation {
        switch name.lowercased() {
        case "restore", "restore original": return .restore
        case "next display": return .nextDisplay
        case "previous display": return .previousDisplay
        case "center": return .center
        case "maximize": return .maximize
        default: return .frame
        }
    }

    @discardableResult
    private func set(frame: CGRect, for element: AXUIElement, attemptsRemaining: Int) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        let visibleFrame = accessibilityVisibleFrame(for: screen(containing: frame))
        if var stagingPosition = Self.bottomAlignedResizeStagingOrigin(
            targetFrame: frame,
            visibleFrame: visibleFrame
        ), let stagingValue = AXValueCreate(.cgPoint, &stagingPosition) {
            // AX position and size updates are not atomic. Resizing a window while
            // it is already against the Dock can make some apps preserve the old
            // bottom edge and extend the new frame underneath the Dock. Stage the
            // window at the top of the work area before sizing, which is equivalent
            // to the reliable top-corner-then-bottom-corner manual workaround.
            _ = AXUIElementSetAttributeValue(
                element,
                kAXPositionAttribute as CFString,
                stagingValue)
        }

        let sizeStatus = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            sizeValue)
        let positionStatus = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue)
        // Some apps adjust their window constraints during either setter. Repeat
        // both values so the final operation always restores the requested edge.
        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        guard positionStatus == .success, sizeStatus == .success else {
            NSLog("WindowLayoutManager: AX frame update failed position=%d size=%d", positionStatus.rawValue, sizeStatus.rawValue)
            NSSound.beep()
            return false
        }

        guard attemptsRemaining > 1 else { return true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let actual = self.frame(of: element), !self.framesMatch(actual, frame) else { return }
            self.set(frame: frame, for: element, attemptsRemaining: attemptsRemaining - 1)
        }
        return true
    }

    static func bottomAlignedResizeStagingOrigin(
        targetFrame: CGRect,
        visibleFrame: CGRect,
        tolerance: CGFloat = 2
    ) -> CGPoint? {
        guard targetFrame.minY > visibleFrame.minY + tolerance,
              abs(targetFrame.maxY - visibleFrame.maxY) <= tolerance
        else { return nil }
        return CGPoint(x: targetFrame.minX, y: visibleFrame.minY)
    }

    private func focusedWindow() -> FocusedWindow? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let application = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplication
            : frontmost
        guard let application,
              application.bundleIdentifier != MagnetShortcutManager.magnetBundleIdentifier
        else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)

        var fullScreenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullScreenValue) == .success,
           (fullScreenValue as? Bool) == true { return nil }

        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &windowID) == .success,
              windowID != 0,
              let frame = frame(of: element)
        else { return nil }
        return FocusedWindow(
            identity: WindowIdentity(pid: application.processIdentifier, windowID: windowID),
            element: element,
            frame: frame)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func screen(containing accessibilityFrame: CGRect) -> NSScreen {
        let appKitFrame = CGRect(
            x: accessibilityFrame.minX,
            y: primaryScreenTop - accessibilityFrame.maxY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        return screens[Self.bestScreenIndex(for: appKitFrame, screenFrames: screens.map(\.frame))]
    }

    static func bestScreenIndex(for windowFrame: CGRect, screenFrames: [CGRect]) -> Int {
        precondition(!screenFrames.isEmpty)
        let intersections = screenFrames.map { $0.intersection(windowFrame).area }
        if let index = intersections.indices.max(by: { intersections[$0] < intersections[$1] }),
           intersections[index] > 0 {
            return index
        }

        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let index = screenFrames.firstIndex(where: { $0.contains(center) }) { return index }
        return screenFrames.indices.min { lhs, rhs in
            screenFrames[lhs].centerDistanceSquared(to: center) < screenFrames[rhs].centerDistanceSquared(to: center)
        } ?? 0
    }

    private func orientation(for screen: NSScreen) -> MagnetDisplayOrientation {
        screen.frame.height > screen.frame.width ? .portrait : .horizontal
    }

    private var primaryScreenTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    private func accessibilityVisibleFrame(for screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        return CGRect(x: visible.minX, y: primaryScreenTop - visible.maxY, width: visible.width, height: visible.height)
    }

    private func adjacentScreen(from source: NSScreen, next: Bool) -> NSScreen? {
        let screens = NSScreen.screens.sorted {
            if $0.frame.minX == $1.frame.minX { return $0.frame.maxY > $1.frame.maxY }
            return $0.frame.minX < $1.frame.minX
        }
        guard screens.count > 1, let index = screens.firstIndex(of: source) else { return nil }
        return screens[(index + (next ? 1 : screens.count - 1)) % screens.count]
    }

    private func translatedFrame(_ frame: CGRect, from source: NSScreen, to destination: NSScreen) -> CGRect {
        let sourceFrame = accessibilityVisibleFrame(for: source)
        let destinationFrame = accessibilityVisibleFrame(for: destination)
        let x = sourceFrame.width > 0 ? (frame.minX - sourceFrame.minX) / sourceFrame.width : 0
        let y = sourceFrame.height > 0 ? (frame.minY - sourceFrame.minY) / sourceFrame.height : 0
        let width = min(destinationFrame.width, frame.width / max(sourceFrame.width, 1) * destinationFrame.width)
        let height = min(destinationFrame.height, frame.height / max(sourceFrame.height, 1) * destinationFrame.height)
        return CGRect(
            x: min(destinationFrame.maxX - width, max(destinationFrame.minX, destinationFrame.minX + x * destinationFrame.width)),
            y: min(destinationFrame.maxY - height, max(destinationFrame.minY, destinationFrame.minY + y * destinationFrame.height)),
            width: width,
            height: height).integral
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private func shortcuts(for command: MagnetShortcutCommand) -> [MagnetShortcut] {
        guard command.modifiers.count >= 2 else { return [] }
        let modifiers = Self.carbonModifiers(for: command.modifiers)
        return MagnetKeyCodes.codes(for: command.destinationKey).map {
            MagnetShortcut(carbonKeyCode: $0, carbonModifiers: modifiers)
        }
    }

    private static func carbonModifiers(for modifiers: Set<MagnetShortcutModifier>) -> UInt32 {
        modifiers.reduce(UInt32(0)) { result, modifier in
            switch modifier {
            case .control: return result | UInt32(controlKey)
            case .option: return result | UInt32(optionKey)
            case .shift: return result | UInt32(shiftKey)
            case .command: return result | UInt32(cmdKey)
            }
        }
    }

    static func internalShortcutOwner(for shortcut: MagnetShortcut) -> String? {
        let terminalWindowsShortcut = MagnetShortcut(
            carbonKeyCode: UInt32(kVK_ANSI_Period),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        return shortcut == terminalWindowsShortcut
            ? "Space Manager: Organize Terminal Windows"
            : nil
    }

    private func showCheatsheet(modifiers: Set<MagnetShortcutModifier>) {
        let targetScreen = cheatsheetTargetScreen()
        let orientation = self.orientation(for: targetScreen)
        if activeCheatsheetKeyboardStyle == nil {
            activeCheatsheetKeyboardStyle =
                keyboardInputDeviceMonitor.recentSlashStyle() ?? .standard
            // Karabiner writes the physical source immediately before it
            // forwards Slash. Its shell action can finish just after the event
            // tap, so check once more after that very short handoff.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self,
                      let style = self.keyboardInputDeviceMonitor.recentSlashStyle(maxAge: 0.5)
                else { return }
                self.updateCheatsheetKeyboardStyle(style)
            }
        }
        if cheatsheetController == nil {
            cheatsheetController = WindowLayoutCheatsheetController()
        }
        cheatsheetController?.show(
            commands: commands.filter(\.isEnabled),
            orientation: orientation,
            activeModifiers: modifiers,
            isPinned: cheatsheetIsPinned,
            screen: targetScreen,
            keyboardStyle: activeCheatsheetKeyboardStyle,
            onSelectModifiers: { [weak self] selectedModifiers in
                self?.selectPinnedCheatsheetModifiers(selectedModifiers)
            })
    }

    private func updateCheatsheetKeyboardStyle(_ style: MacKeyboardStyle) {
        guard cheatsheetShortcutIsDown || cheatsheetIsPinned || activeCheatsheetHoldModifiers != nil,
              activeCheatsheetKeyboardStyle != style,
              let modifiers = activeCheatsheetModifiers
        else { return }
        activeCheatsheetKeyboardStyle = style
        showCheatsheet(modifiers: modifiers)
    }

    private func selectPinnedCheatsheetModifiers(
        _ modifiers: Set<MagnetShortcutModifier>
    ) {
        guard cheatsheetIsPinned, cheatsheetModifierSets.contains(modifiers) else { return }
        activeCheatsheetModifiers = modifiers
    }

    private func hideCheatsheet() {
        cancelPendingCheatsheetHold(blockCurrentHold: true)
        cheatsheetShortcutIsDown = false
        cheatsheetIsPinned = false
        activeCheatsheetHoldModifiers = nil
        dismissCheatsheetWindow()
    }

    private func dismissCheatsheetWindow() {
        activeCheatsheetKeyboardStyle = nil
        activeCheatsheetModifiers = nil
        cheatsheetController?.hide()
    }

    private func observeUserInteraction() {
        if let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            let timestamp = event.timestamp
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let screen = self.screen(at: location) else { return }
                self.lastMouseInteraction = InteractionTarget(
                    timestamp: timestamp,
                    displayID: self.displayID(for: screen))
            }
        }) {
            interactionMonitors.append(mouseMonitor)
        }

        if let keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // The slash that opens the cheatsheet is a control gesture, not a
            // change of focus. Excluding it preserves whichever real mouse or
            // keyboard interaction happened immediately beforehand.
            guard event.keyCode != 44 else { return }
            let timestamp = event.timestamp
            Task { @MainActor in
                guard let self, let window = self.focusedWindow() else { return }
                let screen = self.screen(containing: window.frame)
                self.lastKeyboardInteraction = InteractionTarget(
                    timestamp: timestamp,
                    displayID: self.displayID(for: screen))
            }
        }) {
            interactionMonitors.append(keyboardMonitor)
        }
    }

    private func cheatsheetTargetScreen() -> NSScreen {
        let latest = [lastMouseInteraction, lastKeyboardInteraction]
            .compactMap { $0 }
            .max { $0.timestamp < $1.timestamp }
        if let latest, let screen = screen(withDisplayID: latest.displayID) {
            return screen
        }
        if let window = focusedWindow() {
            return screen(containing: window.frame)
        }
        return screen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    private func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(for: $0) == displayID }
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != MagnetShortcutManager.magnetBundleIdentifier
        else { return }
        lastExternalApplication = application
    }

    private func observeApplications() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.rememberExternalApplication(application) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == MagnetShortcutManager.magnetBundleIdentifier else { return }
            Task { @MainActor in
                self?.refreshMagnetStatus()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let application else { return }
            Task { @MainActor in
                guard let self else { return }
                self.restoreSequences = self.restoreSequences.filter { $0.key.pid != application.processIdentifier }
                if self.lastExternalApplication?.processIdentifier == application.processIdentifier {
                    self.lastExternalApplication = nil
                }
                if application.bundleIdentifier == MagnetShortcutManager.magnetBundleIdentifier {
                    self.refreshMagnetStatus()
                }
            }
        })
    }

    private func observeConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                do {
                    let updated = try self.loadCommands()
                    guard updated.contains(where: \.isEnabled) || !self.isEnabled else {
                        throw WindowLayoutError.noCommands
                    }
                    self.commands = updated
                    if self.isEnabled { try self.registerHotKeys() }
                    self.lastError = nil
                } catch {
                    if self.isEnabled { self.disable() }
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func magnetIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: MagnetShortcutManager.magnetBundleIdentifier).isEmpty
    }

    private func refreshMagnetStatus() {
        isMagnetRunning = magnetIsRunning()
    }

    func quitMagnet() {
        lastError = nil
        do {
            try terminateMagnet()
            refreshMagnetStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func terminateMagnet() throws {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: MagnetShortcutManager.magnetBundleIdentifier)
        applications.forEach { $0.terminate() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if applications.allSatisfy(\.isTerminated) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        throw WindowLayoutError.magnetDidNotQuit
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor])
        menu.addItem(item)
    }

}

enum WindowLayoutOperation: Equatable {
    case frame
    case restore
    case nextDisplay
    case previousDisplay
    case center
    case maximize
}

struct WindowLayoutRestoreSequence: Equatable {
    private(set) var originalFrame: CGRect
    private(set) var lastAppliedFrame: CGRect

    mutating func recordAppliedMove(from currentFrame: CGRect, to targetFrame: CGRect) {
        if !Self.framesMatch(currentFrame, lastAppliedFrame) {
            originalFrame = currentFrame
        }
        lastAppliedFrame = targetFrame
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }
}

private struct WindowIdentity: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
}

private struct InteractionTarget {
    let timestamp: TimeInterval
    let displayID: CGDirectDisplayID
}

private struct FocusedWindow {
    let identity: WindowIdentity
    let element: AXUIElement
    let frame: CGRect
}

struct CheatsheetSlashEventRouting {
    static let slashKeyCode: Int64 = 44

    static func modifiers(from flags: CGEventFlags) -> Set<MagnetShortcutModifier> {
        var modifiers: Set<MagnetShortcutModifier> = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }

    static func matchedModifiers(
        keyCode: Int64,
        flags: CGEventFlags,
        registered: Set<Set<MagnetShortcutModifier>>
    ) -> Set<MagnetShortcutModifier>? {
        guard keyCode == slashKeyCode else { return nil }
        let modifiers = modifiers(from: flags)
        return registered.contains(modifiers) ? modifiers : nil
    }
}

private final class CheatsheetEventTapContext {
    let modifierSets: Set<Set<MagnetShortcutModifier>>
    var activeModifiers: Set<MagnetShortcutModifier>?

    init(modifierSets: Set<Set<MagnetShortcutModifier>>) {
        self.modifierSets = modifierSets
    }
}

private let cheatsheetEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            WindowLayoutManager.shared.reenableCheatsheetEventTap()
        }
        return Unmanaged.passUnretained(event)
    }

    guard (type == .keyDown || type == .keyUp || type == .flagsChanged), let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let context = Unmanaged<CheatsheetEventTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .flagsChanged {
        let modifiers = CheatsheetSlashEventRouting.modifiers(from: event.flags)
        Task { @MainActor in
            WindowLayoutManager.shared.handleCheatsheetModifiersChanged(modifiers)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let modifiers: Set<MagnetShortcutModifier>?
    if type == .keyDown {
        modifiers = CheatsheetSlashEventRouting.matchedModifiers(
            keyCode: keyCode,
            flags: event.flags,
            registered: context.modifierSets)
        if let modifiers { context.activeModifiers = modifiers }
        else {
            Task { @MainActor in
                WindowLayoutManager.shared.handleCheatsheetNonModifierKeyDown()
            }
        }
    } else if keyCode == CheatsheetSlashEventRouting.slashKeyCode {
        // A user can release a modifier before releasing Slash. The key-up
        // event then no longer carries the same modifier flags, so retain the
        // combination that matched key-down instead of leaving the pinned
        // state machine stuck in its pressed state.
        modifiers = context.activeModifiers ?? CheatsheetSlashEventRouting.matchedModifiers(
            keyCode: keyCode,
            flags: event.flags,
            registered: context.modifierSets)
        context.activeModifiers = nil
    } else {
        modifiers = nil
    }
    guard let modifiers else { return Unmanaged.passUnretained(event) }

    Task { @MainActor in
        WindowLayoutManager.shared.handleCheatsheetKey(
            modifiers: modifiers,
            isPressed: type == .keyDown)
    }
    // Prevent macOS's Command-Shift-/ Help shortcut (and any other system
    // handling) only when this is one of our exact cheatsheet combinations.
    return nil
}

private enum WindowLayoutError: LocalizedError {
    case permissionRequired(AppPermission)
    case magnetRunning
    case magnetDidNotQuit
    case noCommands
    case duplicateShortcut(String)
    case reservedShortcutConflict(String)
    case eventHandlerRegistration(OSStatus)
    case hotKeyRegistration(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionRequired(let permission):
            return "Grant \(permission.title) before enabling Window Layouts."
        case .magnetRunning: return "Quit Magnet before enabling Window Layouts."
        case .magnetDidNotQuit: return "Magnet did not quit."
        case .noCommands: return "No window layout shortcuts are configured."
        case .duplicateShortcut(let shortcut): return "The shortcut \(shortcut) is assigned more than once for the same display orientation."
        case .reservedShortcutConflict(let shortcut): return "The shortcut \(shortcut) is reserved by Window Layouts."
        case .eventHandlerRegistration(let status):
            return "Window Layouts could not start (\(status))."
        case .hotKeyRegistration(let shortcut, let status):
            if status == eventHotKeyExistsErr {
                return "The shortcut \(shortcut) is already in use by another app."
            }
            return "The shortcut \(shortcut) could not be registered (\(status))."
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func centerDistanceSquared(to point: CGPoint) -> CGFloat {
        let dx = midX - point.x
        let dy = midY - point.y
        return dx * dx + dy * dy
    }
}
