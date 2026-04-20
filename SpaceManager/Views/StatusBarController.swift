//
//  StatusBarController.swift
//  SpaceManager
//

import Cocoa
import SwiftUI

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private let spaceSwitcher = SpaceSwitcher()

    private var currentSpaces: [Space] = []

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusMenu.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Spaces")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        statusItem.menu = statusMenu
    }

    func updateSpaces(_ spaces: [Space]) {
        currentSpaces = spaces
        spaceSwitcher.reloadShortcuts()
        updateMenuBarTitle(spaces)
        rebuildMenu(spaces)
    }

    private func updateMenuBarTitle(_ spaces: [Space]) {
        guard let current = spaces.first(where: { $0.isCurrentSpace }) else { return }
        if let button = statusItem.button {
            let number = current.isFullScreen ? "F" : current.spaceByDesktopID
            button.title = " \(number)"
            button.imagePosition = .imageLeading
        }
    }

    // MARK: - Permission Checks

    private func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    private func checkAutomation() -> Bool {
        let script = "tell application \"System Events\" to return name of first process"
        guard let scriptObject = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        scriptObject.executeAndReturnError(&error)
        return error == nil
    }

    private func checkScreenRecording() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in windowList {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Finder" || owner == "Google Chrome" || owner == "Terminal" || owner == "Safari" {
                if w[kCGWindowName as String] as? String != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Menu Construction

    private func rebuildMenu(_ spaces: [Space]) {
        statusMenu.removeAllItems()

        var currentDisplayID: String?

        for space in spaces {
            if space.displayID != currentDisplayID {
                if currentDisplayID != nil {
                    statusMenu.addItem(NSMenuItem.separator())
                }
                currentDisplayID = space.displayID
            }

            let item = makeSpaceMenuItem(space: space)
            statusMenu.addItem(item)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(
            title: "Rename Current Space...",
            action: #selector(renameCurrentSpace),
            keyEquivalent: "")
        renameItem.target = self
        statusMenu.addItem(renameItem)

        let hasOverride: Bool = {
            guard let current = spaces.first(where: { $0.isCurrentSpace }) else { return false }
            let stored = SpaceNameStore.shared.loadAll()
            return stored[current.spaceID]?.isUserOverride ?? false
        }()
        if hasOverride {
            let clearItem = NSMenuItem(
                title: "Clear Name Override",
                action: #selector(clearCurrentSpaceName),
                keyEquivalent: "")
            clearItem.target = self
            statusMenu.addItem(clearItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close", action: nil, keyEquivalent: "")
        closeItem.submenu = buildCloseSubmenu(spaces)
        statusMenu.addItem(closeItem)

        let addSpaceItem = NSMenuItem(title: "Add Space", action: #selector(addSpace), keyEquivalent: "")
        addSpaceItem.target = self
        statusMenu.addItem(addSpaceItem)

        let missionControlItem = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl), keyEquivalent: "m")
        missionControlItem.target = self
        statusMenu.addItem(missionControlItem)

        statusMenu.addItem(NSMenuItem.separator())

        let hasAccessibility = checkAccessibility()
        let hasAutomation = checkAutomation()
        let hasScreenRecording = checkScreenRecording()

        let accItem = NSMenuItem(
            title: "\(hasAccessibility ? "+" : "-") Accessibility (switching)",
            action: hasAccessibility ? nil : #selector(openAccessibilitySettings),
            keyEquivalent: "")
        accItem.target = self
        statusMenu.addItem(accItem)

        let autoItem = NSMenuItem(
            title: "\(hasAutomation ? "+" : "-") Automation (System Events)",
            action: hasAutomation ? nil : #selector(openAutomationSettings),
            keyEquivalent: "")
        autoItem.target = self
        statusMenu.addItem(autoItem)

        let scrItem = NSMenuItem(
            title: "\(hasScreenRecording ? "+" : "-") Screen Recording (window names)",
            action: hasScreenRecording ? nil : #selector(openScreenRecordingSettings),
            keyEquivalent: "")
        scrItem.target = self
        statusMenu.addItem(scrItem)

        statusMenu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshSpaces), keyEquivalent: "r")
        refreshItem.target = self
        statusMenu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Space Manager", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func makeSpaceMenuItem(space: Space) -> NSMenuItem {
        let prefix = space.isFullScreen ? "F" : "\(space.spaceByDesktopID)"

        let item = NSMenuItem(
            title: "\(prefix). \(space.spaceName)",
            action: space.isCurrentSpace ? nil : #selector(switchToSpace(_:)),
            keyEquivalent: "")
        item.target = self
        item.tag = space.spaceNumber
        item.representedObject = space.spaceNumber

        if space.isCurrentSpace {
            item.state = .on
        }

        let attrTitle = NSMutableAttributedString()

        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: space.isCurrentSpace ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        ]
        attrTitle.append(NSAttributedString(string: "\(prefix). ", attributes: numberAttrs))

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 14),
            .foregroundColor: space.isCurrentSpace ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        attrTitle.append(NSAttributedString(string: space.spaceName, attributes: nameAttrs))

        if !space.windows.isEmpty {
            let appNames = uniqueAppNames(space.windows)
            let subtitle = appNames.joined(separator: ", ")
            item.toolTip = subtitle

            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            attrTitle.append(NSAttributedString(string: "\n     \(subtitle)", attributes: subtitleAttrs))
        }

        item.attributedTitle = attrTitle
        return item
    }

    // MARK: - Close Submenu

    private func buildCloseSubmenu(_ spaces: [Space]) -> NSMenu {
        let submenu = NSMenu()

        let desktopSpaces = spaces.filter { !$0.isFullScreen }
        let hasMultipleDesktops = desktopSpaces.count > 1

        for space in desktopSpaces {
            let item = makeCloseMenuItem(space: space, enabled: hasMultipleDesktops)
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        let emptySpaces = desktopSpaces.filter { $0.windows.isEmpty }
        let closeableEmptyCount: Int
        if desktopSpaces.count - emptySpaces.count > 0 {
            closeableEmptyCount = emptySpaces.count
        } else {
            closeableEmptyCount = max(0, emptySpaces.count - 1)
        }

        let emptyItem = NSMenuItem(
            title: "Close Empty Spaces (\(closeableEmptyCount))",
            action: closeableEmptyCount > 0 ? #selector(closeEmptySpaces) : nil,
            keyEquivalent: "")
        emptyItem.target = self
        submenu.addItem(emptyItem)

        let closeAllItem = NSMenuItem(
            title: "Close All Spaces",
            action: hasMultipleDesktops ? #selector(closeAllSpaces) : nil,
            keyEquivalent: "")
        closeAllItem.target = self
        submenu.addItem(closeAllItem)

        return submenu
    }

    private func makeCloseMenuItem(space: Space, enabled: Bool) -> NSMenuItem {
        let prefix = space.spaceByDesktopID
        let appNames = uniqueAppNames(space.windows)

        let item = NSMenuItem(
            title: "\(prefix). \(space.spaceName)",
            action: enabled ? #selector(closeSpace(_:)) : nil,
            keyEquivalent: "")
        item.target = self
        item.representedObject = Int(space.spaceByDesktopID)

        let attrTitle = NSMutableAttributedString()

        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        attrTitle.append(NSAttributedString(string: "\(prefix). ", attributes: numberAttrs))

        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 14),
            .foregroundColor: space.isCurrentSpace ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        attrTitle.append(NSAttributedString(string: space.spaceName, attributes: nameAttrs))

        if !appNames.isEmpty {
            let subtitle = appNames.joined(separator: ", ")
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            attrTitle.append(NSAttributedString(string: "\n     \(subtitle)", attributes: subtitleAttrs))
        }

        item.attributedTitle = attrTitle
        return item
    }

    // MARK: - Actions

    @objc private func switchToSpace(_ sender: NSMenuItem) {
        guard let targetNumber = sender.representedObject as? Int else { return }
        guard let target = currentSpaces.first(where: { $0.spaceNumber == targetNumber }) else { return }
        guard !target.isCurrentSpace else { return }

        if spaceSwitcher.canDirectSwitch(spaceNumber: targetNumber) {
            spaceSwitcher.switchToSpace(spaceNumber: targetNumber) {
                self.showSwitchError()
            }
        } else if !target.isFullScreen, let desktopNum = Int(target.spaceByDesktopID) {
            spaceSwitcher.switchViaMissionControl(desktopNumber: desktopNum)
        }
    }

    private func showSwitchError() {
        let hasAcc = checkAccessibility()
        let hasAuto = checkAutomation()
        var msg = "Space switching failed.\n\n"
        if !hasAcc { msg += "- Accessibility permission NOT granted\n" }
        if !hasAuto { msg += "- Automation (System Events) permission NOT granted\n" }
        if hasAcc && hasAuto { msg += "Both permissions appear granted. Try removing and re-adding Space Manager in System Settings > Privacy & Security > Accessibility, then restart the app." }

        let alert = NSAlert()
        alert.messageText = "Cannot Switch Spaces"
        alert.informativeText = msg
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func renameCurrentSpace() {
        guard let current = currentSpaces.first(where: { $0.isCurrentSpace }) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Space \(current.spaceByDesktopID)"
        alert.informativeText = "Enter a custom name. Leave empty to use auto-detection."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = current.spaceName
        textField.placeholderString = "Auto-detect"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            NotificationCenter.default.post(
                name: NSNotification.Name("RenameSpace"),
                object: nil,
                userInfo: ["spaceID": current.spaceID, "name": newName])
        }
    }

    @objc private func clearCurrentSpaceName() {
        guard let current = currentSpaces.first(where: { $0.isCurrentSpace }) else { return }
        NotificationCenter.default.post(
            name: NSNotification.Name("RenameSpace"),
            object: nil,
            userInfo: ["spaceID": current.spaceID, "name": ""])
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openAutomationSettings() {
        let script = "tell application \"System Events\" to return name of first process"
        if let obj = NSAppleScript(source: script) {
            var error: NSDictionary?
            obj.executeAndReturnError(&error)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func closeSpace(_ sender: NSMenuItem) {
        guard let desktopNumber = sender.representedObject as? Int else { return }
        SpaceCloser.closeSpaces(desktopNumbers: [desktopNumber]) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeEmptySpaces() {
        let freshWindows = WindowDetector.detectWindowsPerSpace()
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }

        var emptyNumbers = desktopSpaces
            .filter { (freshWindows[$0.spaceID] ?? []).isEmpty }
            .compactMap { Int($0.spaceByDesktopID) }

        guard !emptyNumbers.isEmpty else { return }

        let occupiedCount = desktopSpaces.count - emptyNumbers.count
        if occupiedCount == 0 {
            emptyNumbers.sort()
            emptyNumbers.removeFirst()
        }

        guard !emptyNumbers.isEmpty else { return }

        SpaceCloser.closeSpaces(desktopNumbers: emptyNumbers) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeAllSpaces() {
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        guard desktopSpaces.count > 1 else { return }

        let alert = NSAlert()
        alert.messageText = "Close All Spaces?"
        alert.informativeText = "This will close \(desktopSpaces.count - 1) space\(desktopSpaces.count == 2 ? "" : "s") and move all windows to Desktop 1."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let numbersToClose = desktopSpaces.compactMap { Int($0.spaceByDesktopID) }.filter { $0 > 1 }
        SpaceCloser.closeSpaces(desktopNumbers: numbersToClose) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func addSpace() {
        SpaceCloser.addSpace { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func showMissionControl() {
        NSWorkspace.shared.launchApplication("Mission Control")
    }

    private func refreshAfterClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
        }
    }

    @objc private func refreshSpaces() {
        NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func uniqueAppNames(_ windows: [SpaceWindow]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for window in windows {
            if seen.insert(window.ownerName).inserted {
                result.append(window.ownerName)
            }
        }
        return result
    }
}

extension StatusBarController: NSMenuDelegate {
}
