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
    private var commands: [MagnetShortcutCommand] = []
    private var commandsByHotKeyID: [UInt32: [MagnetDisplayOrientation: MagnetShortcutCommand]] = [:]
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []
    private var magnetMonitor: Timer?
    private weak var lastExternalApplication: NSRunningApplication?
    private var restoreFrames: [WindowIdentity: CGRect] = [:]

    private override init() {
        let requested = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        isEnabled = false
        isMagnetRunning = false
        super.init()

        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        observeApplications()
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
        commands = try loadCommands().filter(\.isEnabled)
        guard !commands.isEmpty else { throw WindowLayoutError.noCommands }
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
        if let configuration = try MagnetShortcutManager.shared.loadDraft() {
            return MagnetShortcutEditorAdapter().editorCommands(from: configuration)
        }
        if let configuration = try? MagnetShortcutManager.shared.loadMagnetConfiguration() {
            _ = try? MagnetShortcutManager.shared.saveDraft(configuration)
            return MagnetShortcutEditorAdapter().editorCommands(from: configuration)
        }
        return MagnetShortcutCommand.standardSet
    }

    private func registerHotKeys() throws {
        unregisterHotKeys()
        var routes: [MagnetShortcut: [MagnetDisplayOrientation: MagnetShortcutCommand]] = [:]
        for command in commands {
            guard let shortcut = shortcut(for: command) else { continue }
            routes[shortcut, default: [:]][command.orientation] = command
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
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
                Task { @MainActor in WindowLayoutManager.shared.handleHotKey(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler)
        guard status == noErr else { throw WindowLayoutError.hotKeyRegistration(status) }

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
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        commandsByHotKeyID.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handleHotKey(_ id: UInt32) {
        guard isEnabled, let window = focusedWindow() else { return }
        let orientation = orientation(for: screen(containing: window.frame))
        guard let command = commandsByHotKeyID[id]?[orientation] else { return }
        apply(command, to: window)
    }

    private func apply(_ command: MagnetShortcutCommand, to window: FocusedWindow) {
        let lowerName = command.name.lowercased()
        if lowerName == "restore" {
            guard let frame = restoreFrames.removeValue(forKey: window.identity) else { return }
            set(frame: frame, for: window.element, attemptsRemaining: 3)
            return
        }

        restoreFrames[window.identity] = restoreFrames[window.identity] ?? window.frame
        let sourceScreen = screen(containing: window.frame)
        let target: CGRect
        if lowerName.contains("next display") || lowerName.contains("previous display") {
            guard let destination = adjacentScreen(from: sourceScreen, next: lowerName.contains("next")) else { return }
            target = translatedFrame(window.frame, from: sourceScreen, to: destination)
        } else if lowerName == "center" {
            let visible = accessibilityVisibleFrame(for: sourceScreen)
            let size = CGSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
            target = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        } else if lowerName == "maximize" {
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
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(appKitFrame).area < rhs.frame.intersection(appKitFrame).area
        } ?? NSScreen.main ?? NSScreen.screens[0]
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

    private func shortcut(for command: MagnetShortcutCommand) -> MagnetShortcut? {
        guard let keyCode = keyCodes[command.destinationKey], command.modifiers.count >= 2 else { return nil }
        let modifiers = command.modifiers.reduce(UInt32(0)) { result, modifier in
            switch modifier {
            case .control: return result | UInt32(controlKey)
            case .option: return result | UInt32(optionKey)
            case .shift: return result | UInt32(shiftKey)
            case .command: return result | UInt32(cmdKey)
            }
        }
        return MagnetShortcut(carbonKeyCode: keyCode, carbonModifiers: modifiers)
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
            guard application?.bundleIdentifier == MagnetShortcutManager.magnetBundleIdentifier else { return }
            Task { @MainActor in self?.refreshMagnetStatus() }
        })
    }

    private func observeConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.disable()
                self.setEnabled(true)
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

    private let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "Return": 36,
        "L": 37, "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "N": 45, "M": 46, ".": 47, "Space": 49, "Delete": 51,
        "KP.": 65, "KP*": 67, "KP+": 69, "Clear": 71, "KP/": 75, "KP Enter": 76,
        "KP-": 78, "KP=": 81, "KP0": 82, "KP1": 83, "KP2": 84, "KP3": 85,
        "KP4": 86, "KP5": 87, "KP6": 88, "KP7": 89, "KP8": 91, "KP9": 92,
        "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101,
        "F11": 103, "F13": 105, "F16": 106, "F14": 107, "F10": 109, "F12": 111,
        "F15": 113, "F4": 118, "F2": 120, "F1": 122, "←": 123, "→": 124,
        "↓": 125, "↑": 126
    ]
}

private struct WindowIdentity: Hashable {
    let pid: pid_t
    let windowID: CGWindowID
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
    case hotKeyRegistration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .magnetRunning: return "Quit Magnet before enabling Window Layouts."
        case .magnetDidNotQuit: return "Magnet did not quit."
        case .noCommands: return "No window layout shortcuts are configured."
        case .hotKeyRegistration(let status): return "A window layout shortcut could not be registered (\(status))."
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
