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

@MainActor
final class WindowLayoutManager: NSObject, ObservableObject {
    static let shared = WindowLayoutManager()
    static let enabledDefaultsKey = "windowLayoutsEnabled"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isMagnetRunning: Bool
    @Published private(set) var lastError: String?

    private static let hotKeySignature: OSType = 0x53574C59 // SWLY
    private static let cheatsheetHotKeyIDBase: UInt32 = 900
    private static let settingsHotKeyID: UInt32 = 990
    static let settingsShortcutText = "⌃⌥⌘,"
    private static let settingsShortcut = MagnetShortcut(
        carbonKeyCode: 43,
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey))
    private var commands: [MagnetShortcutCommand] = []
    private var commandsByHotKeyID: [UInt32: [MagnetDisplayOrientation: MagnetShortcutCommand]] = [:]
    private var cheatsheetModifiersByHotKeyID: [UInt32: Set<MagnetShortcutModifier>] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var magnetMonitor: Timer?
    private weak var lastExternalApplication: NSRunningApplication?
    private var restoreFrames: [WindowIdentity: CGRect] = [:]
    private var cheatsheetController: WindowLayoutCheatsheetController?
    private var cheatsheetShortcutIsDown = false
    private var cheatsheetKeyMonitor: Timer?
    private var activeCheatsheetModifiers: Set<MagnetShortcutModifier>?
    private var interactionMonitors: [Any] = []
    private var lastMouseInteraction: InteractionTarget?
    private var lastKeyboardInteraction: InteractionTarget?

    private override init() {
        let requested = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        isEnabled = false
        isMagnetRunning = false
        super.init()

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

        let cheatsheet = NSMenuItem(title: "Cheatsheet — Hold modifiers + /", action: nil, keyEquivalent: "")
        cheatsheet.isEnabled = false
        menu.addItem(cheatsheet)

        let settings = NSMenuItem(title: "Edit Shortcuts — \(Self.settingsShortcutText)", action: nil, keyEquivalent: "")
        settings.isEnabled = false
        menu.addItem(settings)

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
                    title: command.name,
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
                let item = NSMenuItem(title: command.name, action: #selector(applyMenuCommand(_:)), keyEquivalent: "")
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
        }
    }

    @objc private func applyMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let window = focusedWindow(),
              let command = commands.first(where: { $0.id == id && $0.orientation == orientation(for: screen(containing: window.frame)) })
        else { return }
        apply(command, to: window)
    }

    private func enable() throws {
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
        guard status == noErr else { throw WindowLayoutError.hotKeyRegistration(status) }

        let modifierSets = Set(commands.lazy.filter(\.isEnabled).map(\.modifiers))
            .filter { $0.count >= 2 }
            .sorted { Self.carbonModifiers(for: $0) < Self.carbonModifiers(for: $1) }
        for (index, modifiers) in modifierSets.enumerated() {
            let id = Self.cheatsheetHotKeyIDBase + UInt32(index)
            var reference: EventHotKeyRef?
            let registration = RegisterEventHotKey(
                44,
                Self.carbonModifiers(for: modifiers),
                EventHotKeyID(signature: Self.hotKeySignature, id: id),
                GetApplicationEventTarget(),
                0,
                &reference)
            guard registration == noErr, let reference else {
                unregisterHotKeys()
                throw WindowLayoutError.hotKeyRegistration(registration)
            }
            hotKeys.append(reference)
            cheatsheetModifiersByHotKeyID[id] = modifiers
        }

        var settingsReference: EventHotKeyRef?
        let settingsRegistration = RegisterEventHotKey(
            Self.settingsShortcut.carbonKeyCode,
            Self.settingsShortcut.carbonModifiers,
            EventHotKeyID(signature: Self.hotKeySignature, id: Self.settingsHotKeyID),
            GetApplicationEventTarget(),
            0,
            &settingsReference)
        guard settingsRegistration == noErr, let settingsReference else {
            unregisterHotKeys()
            throw WindowLayoutError.hotKeyRegistration(settingsRegistration)
        }
        hotKeys.append(settingsReference)

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
            guard registration == noErr, let reference else {
                unregisterHotKeys()
                throw WindowLayoutError.hotKeyRegistration(registration)
            }
            hotKeys.append(reference)
            commandsByHotKeyID[id] = entry.value
        }
    }

    private func unregisterHotKeys() {
        hideCheatsheet()
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        commandsByHotKeyID.removeAll()
        cheatsheetModifiersByHotKeyID.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleHotKey(_ id: UInt32, isPressed: Bool) {
        if let modifiers = cheatsheetModifiersByHotKeyID[id] {
            if isPressed {
                guard !cheatsheetShortcutIsDown else { return }
                cheatsheetShortcutIsDown = true
                activeCheatsheetModifiers = modifiers
                showCheatsheet(modifiers: modifiers)
                startCheatsheetKeyMonitor()
            } else {
                hideCheatsheet()
            }
            return
        }
        if id == Self.settingsHotKeyID {
            guard isPressed else { return }
            hideCheatsheet()
            if let url = URL(string: "spacemanager://window-layout-shortcuts") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard isPressed else { return }
        guard isEnabled, let window = focusedWindow() else { return }
        let orientation = orientation(for: screen(containing: window.frame))
        guard let command = commandsByHotKeyID[id]?[orientation] else { return }
        apply(command, to: window)
    }

    private func apply(_ command: MagnetShortcutCommand, to window: FocusedWindow) {
        let operation = Self.operation(for: command.name)
        if operation == .restore {
            guard let frame = restoreFrames.removeValue(forKey: window.identity) else { return }
            set(frame: frame, for: window.element, attemptsRemaining: 3)
            return
        }

        restoreFrames[window.identity] = restoreFrames[window.identity] ?? window.frame
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
        set(frame: target, for: window.element, attemptsRemaining: 3)
    }

    static func operation(for name: String) -> WindowLayoutOperation {
        switch name.lowercased() {
        case "restore": return .restore
        case "next display": return .nextDisplay
        case "previous display": return .previousDisplay
        case "center": return .center
        case "maximize": return .maximize
        default: return .frame
        }
    }

    private func set(frame: CGRect, for element: AXUIElement, attemptsRemaining: Int) {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return }

        let positionStatus = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let sizeStatus = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        guard positionStatus == .success, sizeStatus == .success else {
            NSLog("WindowLayoutManager: AX frame update failed position=%d size=%d", positionStatus.rawValue, sizeStatus.rawValue)
            NSSound.beep()
            return
        }

        guard attemptsRemaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let actual = self.frame(of: element), !self.framesMatch(actual, frame) else { return }
            self.set(frame: frame, for: element, attemptsRemaining: attemptsRemaining - 1)
        }
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

    private func showCheatsheet(modifiers: Set<MagnetShortcutModifier>) {
        let targetScreen = cheatsheetTargetScreen()
        let orientation = self.orientation(for: targetScreen)
        if cheatsheetController == nil {
            cheatsheetController = WindowLayoutCheatsheetController()
        }
        cheatsheetController?.show(
            commands: commands.filter(\.isEnabled),
            orientation: orientation,
            activeModifiers: modifiers,
            screen: targetScreen)
    }

    private func startCheatsheetKeyMonitor() {
        cheatsheetKeyMonitor?.invalidate()
        cheatsheetKeyMonitor = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                let slashIsDown = CGEventSource.keyState(.combinedSessionState, key: 44)
                guard slashIsDown else {
                    self.hideCheatsheet()
                    return
                }
                let modifiers = Self.modifiers(from: flags)
                guard self.cheatsheetModifiersByHotKeyID.values.contains(modifiers) else {
                    self.hideCheatsheet()
                    return
                }
                if modifiers != self.activeCheatsheetModifiers {
                    self.activeCheatsheetModifiers = modifiers
                    self.showCheatsheet(modifiers: modifiers)
                }
            }
        }
    }

    private func hideCheatsheet() {
        cheatsheetShortcutIsDown = false
        cheatsheetKeyMonitor?.invalidate()
        cheatsheetKeyMonitor = nil
        activeCheatsheetModifiers = nil
        cheatsheetController?.hide()
    }

    private static func modifiers(from flags: CGEventFlags) -> Set<MagnetShortcutModifier> {
        var modifiers: Set<MagnetShortcutModifier> = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
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
                self.restoreFrames = self.restoreFrames.filter { $0.key.pid != application.processIdentifier }
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

private enum WindowLayoutError: LocalizedError {
    case magnetRunning
    case magnetDidNotQuit
    case noCommands
    case duplicateShortcut(String)
    case reservedShortcutConflict(String)
    case hotKeyRegistration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .magnetRunning: return "Quit Magnet before enabling Window Layouts."
        case .magnetDidNotQuit: return "Magnet did not quit."
        case .noCommands: return "No window layout shortcuts are configured."
        case .duplicateShortcut(let shortcut): return "The shortcut \(shortcut) is assigned more than once for the same display orientation."
        case .reservedShortcutConflict(let shortcut): return "The shortcut \(shortcut) is reserved by Window Layouts."
        case .hotKeyRegistration(let status): return "A window layout shortcut could not be registered (\(status))."
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
