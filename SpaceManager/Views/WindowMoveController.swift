//
//  WindowMoveController.swift
//  SpaceManager
//
//  Presents a global Space chooser and moves the focused window.
//

import Carbon
import Cocoa

@MainActor
final class WindowMoveController: NSObject {
    static weak var shared: WindowMoveController?

    private var spaces: [Space] = []
    private var hotKey: EventHotKeyRef?
    private var pendingWindowID: CGWindowID?
    private var popupMenu: NSMenu?
    private var menuHostPanel: NSPanel?
    private var activationObserver: NSObjectProtocol?
    private weak var lastExternalApplication: NSRunningApplication?

    override init() {
        super.init()
        Self.shared = self
        WindowMoveLog.write(
            "WindowMoveController initialized pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundlePath)")
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor in
                self?.rememberExternalApplication(application)
            }
        }
        registerKeyboardMonitor()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func updateSpaces(_ spaces: [Space]) {
        self.spaces = spaces
    }

    func showMoveMenu() {
        WindowMoveLog.write("showMoveMenu invoked")
        let menu = NSMenu()
        popupMenu = menu

        guard let focusedWindow = focusedWindow() else {
            WindowMoveLog.write("No focused window found")
            let item = NSMenuItem(title: "No Focused Window", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            show(menu)
            return
        }

        pendingWindowID = focusedWindow.id
        let sourceSpaceID = spaceID(containing: focusedWindow.id)
        WindowMoveLog.write(
            "Focused window id=\(focusedWindow.id) title=\(focusedWindow.title) sourceSpace=\(sourceSpaceID ?? "unknown")")

        let header = NSMenuItem(title: focusedWindow.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let desktopSpaces = spaces.filter { !$0.isFullScreen }
        let shortcutCounts = Dictionary(
            grouping: desktopSpaces,
            by: \.spaceByDesktopID)
            .mapValues(\.count)
        let displayCount = Set(desktopSpaces.map(\.displayID)).count
        var previousDisplayID: String?

        for space in desktopSpaces {
            if displayCount > 1, space.displayID != previousDisplayID {
                if previousDisplayID != nil { menu.addItem(.separator()) }
                previousDisplayID = space.displayID

                let displayItem = NSMenuItem(
                    title: DisplayGeometryUtilities.displayName(for: space.displayID),
                    action: nil,
                    keyEquivalent: "")
                displayItem.isEnabled = false
                menu.addItem(displayItem)
            }

            let label = SpaceLabelStore.shared.label(for: space.spaceID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = label.isEmpty ? space.spaceName : label
            let indicator = label.isEmpty ? "" : "• "
            let item = NSMenuItem(
                title: "\(space.spaceByDesktopID). \(indicator)\(name)",
                action: space.spaceID == sourceSpaceID ? nil : #selector(moveFocusedWindow(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = space.spaceID
            if space.spaceID != sourceSpaceID,
               shortcutCounts[space.spaceByDesktopID] == 1,
               let shortcutNumber = Int(space.spaceByDesktopID),
               (1...9).contains(shortcutNumber)
            {
                item.keyEquivalent = space.spaceByDesktopID
                item.keyEquivalentModifierMask = []
            }
            if space.spaceID == sourceSpaceID {
                item.state = .on
                item.isEnabled = false
            }
            menu.addItem(item)
        }

        let loggedSpaces = desktopSpaces.map { space in
            let label = SpaceLabelStore.shared.label(for: space.spaceID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = label.isEmpty ? space.spaceName : label
            return "\(space.spaceByDesktopID)=\(name)"
        }.joined(separator: ", ")
        WindowMoveLog.write("Move menu spaces: \(loggedSpaces)")
        show(menu)
    }

    private func show(_ menu: NSMenu) {
        WindowMoveLog.write("Presenting menu with \(menu.items.count) items")
        let location = NSEvent.mouseLocation
        let panel = NSPanel(
            contentRect: NSRect(x: location.x, y: location.y, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        menuHostPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        menu.popUp(positioning: nil, at: .zero, in: panel.contentView)
        WindowMoveLog.write("Menu dismissed")
        panel.orderOut(nil)
        menuHostPanel = nil
        popupMenu = nil
    }

    @objc private func moveFocusedWindow(_ sender: NSMenuItem) {
        guard let windowID = pendingWindowID,
              let rawSpaceID = sender.representedObject as? String,
              let targetSpaceID = UInt64(rawSpaceID)
        else { return }

        let windowIDs = [windowID] as CFArray
        let usedModernOperation = SMMoveWindowsToManagedSpaceModern(windowIDs, targetSpaceID) == 1
        if !usedModernOperation {
            CGSMoveWindowsToManagedSpace(
                _CGSDefaultConnection(),
                windowIDs,
                targetSpaceID)
        }
        WindowMoveLog.write(
            "Move submitted window=\(windowID) targetSpace=\(targetSpaceID) modern=\(usedModernOperation)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let actualSpaceID = self.spaceID(containing: windowID)
            let succeeded = actualSpaceID == String(targetSpaceID)
            WindowMoveLog.write(
                "Move verification window=\(windowID) expected=\(targetSpaceID) actual=\(actualSpaceID ?? "unknown") success=\(succeeded)")
            if succeeded {
                NotificationCenter.default.post(
                    name: NSNotification.Name("RequestSpaceRefresh"),
                    object: nil)
            } else {
                NSSound.beep()
            }
        }
        pendingWindowID = nil
    }

    private func focusedWindow() -> (id: CGWindowID, title: String)? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApplication
            : frontmost
        guard let app else {
            WindowMoveLog.write("No frontmost or remembered external application")
            return nil
        }
        WindowMoveLog.write(
            "Checking focused window app=\(app.localizedName ?? "unknown") pid=\(app.processIdentifier)")

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue) == .success,
            let window = windowValue
        else { return nil }

        let windowElement = window as! AXUIElement
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(windowElement, &windowID) == .success,
              windowID != 0
        else { return nil }

        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
        let windowTitle = (titleValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Focused Window"
        return (windowID, title)
    }

    private func spaceID(containing windowID: CGWindowID) -> String? {
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(_CGSDefaultConnection(), 0x7, windowIDs) else {
            return nil
        }
        let result = spaces.takeRetainedValue() as? [NSNumber] ?? []
        return result.first?.stringValue
    }

    private func rememberExternalApplication(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        lastExternalApplication = application
    }

    private func registerKeyboardMonitor() {
        let hotKeyID = EventHotKeyID(signature: spaceManagerHotKeySignature, id: 2)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(controlKey | optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey)
        WindowMoveLog.write(
            "RegisterEventHotKey status=\(status) ref=\(hotKey == nil ? "nil" : "set") shortcut=control-option-command-M")
        if status != noErr {
            NSLog("WindowMoveController: failed to register global shortcut (%d)", status)
        }
    }
}
