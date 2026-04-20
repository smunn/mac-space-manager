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
    private var settingsWindow: NSWindow?

    private var currentSpaces: [Space] = []
    private var physicalDisplayOrder: [String] = []

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

        var ids: [String] = []
        var seen = Set<String>()
        for space in spaces {
            if seen.insert(space.displayID).inserted {
                ids.append(space.displayID)
            }
        }
        physicalDisplayOrder = ids

        spaceSwitcher.reloadShortcuts()
        updateMenuBarTitle(spaces)
        rebuildMenu(spaces)
    }

    private func updateMenuBarTitle(_ spaces: [Space]) {
        guard let current = spaces.first(where: { $0.isCurrentSpace }) else { return }
        if let button = statusItem.button {
            let desktopCount = spaces.filter { !$0.isFullScreen }.count
            let number = current.isFullScreen ? "F" : "\(current.spaceByDesktopID)/\(desktopCount)"
            button.title = " \(number)"
            button.imagePosition = .imageLeading
        }
    }

    // MARK: - Menu Construction

    private func rebuildMenu(_ spaces: [Space]) {
        statusMenu.removeAllItems()

        var orderedDisplayIDs: [String] = []
        var seenDisplays = Set<String>()
        for space in spaces {
            if seenDisplays.insert(space.displayID).inserted {
                orderedDisplayIDs.append(space.displayID)
            }
        }
        let multipleDisplays = orderedDisplayIDs.count > 1
        let activeDisplayUUID = multipleDisplays ? DisplayGeometryUtilities.activeDisplayUUID(from: orderedDisplayIDs) : nil

        // Reorder so the active display's spaces come first
        let sortedSpaces: [Space]
        if let activeUUID = activeDisplayUUID {
            let activeSpaces = spaces.filter { $0.displayID == activeUUID }
            let otherSpaces = spaces.filter { $0.displayID != activeUUID }
            sortedSpaces = activeSpaces + otherSpaces
        } else {
            sortedSpaces = spaces
        }

        var currentDisplayID: String?

        for space in sortedSpaces {
            if space.displayID != currentDisplayID {
                if currentDisplayID != nil {
                    statusMenu.addItem(NSMenuItem.separator())
                }
                currentDisplayID = space.displayID

                if multipleDisplays {
                    let displayName = DisplayGeometryUtilities.displayName(for: space.displayID)
                    let isActive = space.displayID == activeDisplayUUID
                    let label = isActive ? "\(displayName)  ◆" : displayName
                    let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: isActive ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
                    ]
                    header.attributedTitle = NSAttributedString(string: label, attributes: attrs)
                    statusMenu.addItem(header)
                }
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

        if multipleDisplays {
            let transferItem = NSMenuItem(title: "Transfer", action: nil, keyEquivalent: "")
            transferItem.submenu = buildTransferSubmenu(spaces, orderedDisplayIDs: orderedDisplayIDs)
            statusMenu.addItem(transferItem)
        }

        statusMenu.addItem(NSMenuItem.separator())

        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.submenu = buildNewSubmenu()
        statusMenu.addItem(newItem)

        let closeItem = NSMenuItem(title: "Close", action: nil, keyEquivalent: "")
        closeItem.submenu = buildCloseSubmenu(spaces)
        statusMenu.addItem(closeItem)

        let missionControlItem = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl), keyEquivalent: "m")
        missionControlItem.target = self
        statusMenu.addItem(missionControlItem)

        statusMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

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

    // MARK: - New Submenu

    private func buildNewSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let emptyItem = NSMenuItem(title: "Empty Space", action: #selector(addSpace), keyEquivalent: "")
        emptyItem.target = self
        submenu.addItem(emptyItem)

        let terminalItem = NSMenuItem(title: "Terminal Space", action: #selector(addTerminalSpace), keyEquivalent: "")
        terminalItem.target = self
        submenu.addItem(terminalItem)

        return submenu
    }

    // MARK: - Transfer Submenu

    private func buildTransferSubmenu(_ spaces: [Space], orderedDisplayIDs: [String]) -> NSMenu {
        let submenu = NSMenu()

        // Identify the active display's current space as the transfer source
        let activeUUID = DisplayGeometryUtilities.activeDisplayUUID(from: orderedDisplayIDs)
        let currentSpace: Space? = {
            if let uuid = activeUUID {
                return spaces.first { $0.isCurrentSpace && $0.displayID == uuid }
            }
            return spaces.first { $0.isCurrentSpace }
        }()

        guard let source = currentSpace, !source.isFullScreen else {
            let disabled = NSMenuItem(title: "No transferable space", action: nil, keyEquivalent: "")
            disabled.isEnabled = false
            submenu.addItem(disabled)
            return submenu
        }

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "Move \"\(source.spaceName)\" to:",
            attributes: headerAttrs)
        submenu.addItem(header)
        submenu.addItem(NSMenuItem.separator())

        let targetDisplayIDs = orderedDisplayIDs.filter { $0 != source.displayID }
        for displayID in targetDisplayIDs {
            let displayName = DisplayGeometryUtilities.displayName(for: displayID)
            let item = NSMenuItem(title: displayName, action: #selector(transferToDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [
                "sourceSpaceID": source.spaceID,
                "sourceDisplayID": source.displayID,
                "targetDisplayID": displayID
            ] as [String: String]
            submenu.addItem(item)
        }

        return submenu
    }

    // MARK: - Close Submenu

    private func buildCloseSubmenu(_ spaces: [Space]) -> NSMenu {
        let submenu = NSMenu()

        let desktopSpaces = spaces.filter { !$0.isFullScreen }
        let hasMultipleDesktops = desktopSpaces.count > 1
        let currentDesktop = spaces.first { $0.isCurrentSpace && !$0.isFullScreen }

        let closeCurrentTitle: String
        if let currentDesktop {
            closeCurrentTitle = "Close Current Space (\(currentDesktop.spaceByDesktopID))"
        } else {
            closeCurrentTitle = "Close Current Space"
        }

        let closeCurrentItem = NSMenuItem(
            title: closeCurrentTitle,
            action: currentDesktop != nil && hasMultipleDesktops ? #selector(closeCurrentSpace) : nil,
            keyEquivalent: "")
        closeCurrentItem.target = self
        submenu.addItem(closeCurrentItem)

        submenu.addItem(NSMenuItem.separator())

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
        item.representedObject = space.spaceID

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

    // MARK: - Display Helpers

    private func displayGroupIndex(for displayID: String) -> Int {
        (physicalDisplayOrder.firstIndex(of: displayID) ?? 0) + 1
    }

    private func activeDisplayGroupIndex() -> Int {
        guard let uuid = DisplayGeometryUtilities.activeDisplayUUID(from: physicalDisplayOrder) else { return 1 }
        return displayGroupIndex(for: uuid)
    }

    private func perDisplayDesktopNumber(for space: Space) -> Int? {
        guard !space.isFullScreen else { return nil }
        let sameDisplayDesktops = currentSpaces.filter {
            $0.displayID == space.displayID && !$0.isFullScreen
        }
        guard let index = sameDisplayDesktops.firstIndex(where: { $0.spaceID == space.spaceID }) else { return nil }
        return index + 1
    }

    private func closeTarget(for space: Space) -> SpaceCloser.CloseTarget? {
        guard let desktopNum = perDisplayDesktopNumber(for: space) else { return nil }
        return SpaceCloser.CloseTarget(
            displayGroup: displayGroupIndex(for: space.displayID),
            desktopNumber: desktopNum)
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
        let hasAcc = AppPermissions.check(.accessibility)
        let hasAuto = AppPermissions.check(.automation)
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
            AppPermissions.openSettings(for: .accessibility)
        }
    }

    @objc private func transferToDisplay(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let sourceSpaceID = info["sourceSpaceID"],
              let sourceDisplayID = info["sourceDisplayID"],
              let targetDisplayID = info["targetDisplayID"] else { return }

        NotificationCenter.default.post(
            name: NSNotification.Name("TransferSpace"),
            object: nil,
            userInfo: [
                "sourceSpaceID": sourceSpaceID,
                "sourceDisplayID": sourceDisplayID,
                "targetDisplayID": targetDisplayID
            ])
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

    @objc private func closeSpace(_ sender: NSMenuItem) {
        guard let spaceID = sender.representedObject as? String,
              let space = currentSpaces.first(where: { $0.spaceID == spaceID }),
              let target = closeTarget(for: space) else { return }
        SpaceCloser.closeSpaces(targets: [target]) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeCurrentSpace() {
        guard let current = currentSpaces.first(where: { $0.isCurrentSpace && !$0.isFullScreen }),
              let target = closeTarget(for: current) else { return }

        let sameDisplayDesktops = currentSpaces.filter {
            $0.displayID == current.displayID && !$0.isFullScreen
        }
        guard sameDisplayDesktops.count > 1 else { return }

        SpaceCloser.closeSpaces(targets: [target]) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeEmptySpaces() {
        let freshWindows = WindowDetector.detectWindowsPerSpace()
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }

        let emptySpaces = desktopSpaces.filter { (freshWindows[$0.spaceID] ?? []).isEmpty }
        guard !emptySpaces.isEmpty else { return }

        // Keep at least one desktop per display
        let byDisplay = Dictionary(grouping: desktopSpaces, by: { $0.displayID })
        let emptyByDisplay = Dictionary(grouping: emptySpaces, by: { $0.displayID })

        var targets: [SpaceCloser.CloseTarget] = []
        for (displayID, allOnDisplay) in byDisplay {
            guard var emptyOnDisplay = emptyByDisplay[displayID] else { continue }
            let occupiedCount = allOnDisplay.count - emptyOnDisplay.count
            if occupiedCount == 0 {
                emptyOnDisplay.removeFirst()
            }
            targets += emptyOnDisplay.compactMap { closeTarget(for: $0) }
        }

        guard !targets.isEmpty else { return }

        SpaceCloser.closeSpaces(targets: targets) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeAllSpaces() {
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        guard desktopSpaces.count > 1 else { return }

        // Keep at least one desktop per display
        let byDisplay = Dictionary(grouping: desktopSpaces, by: { $0.displayID })
        var targets: [SpaceCloser.CloseTarget] = []
        for (_, spacesOnDisplay) in byDisplay {
            guard spacesOnDisplay.count > 1 else { continue }
            for space in spacesOnDisplay.dropFirst() {
                if let target = closeTarget(for: space) {
                    targets.append(target)
                }
            }
        }

        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Close All Spaces?"
        alert.informativeText = "This will close \(targets.count) space\(targets.count == 1 ? "" : "s"), keeping one desktop per display."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SpaceCloser.closeSpaces(targets: targets) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func addSpace() {
        let groupIndex = activeDisplayGroupIndex()
        SpaceCloser.addSpace(displayGroupIndex: groupIndex) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func addTerminalSpace() {
        let groupIndex = activeDisplayGroupIndex()
        let activeUUID = DisplayGeometryUtilities.activeDisplayUUID(from: physicalDisplayOrder)
        let desktopsOnDisplay = currentSpaces.filter {
            $0.displayID == (activeUUID ?? "") && !$0.isFullScreen
        }
        let targetDesktopNumber = desktopsOnDisplay.count + 1

        WorkspaceAutomation.createTerminalSpace(
            targetDesktopNumber: targetDesktopNumber,
            displayGroupIndex: groupIndex
        ) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func showMissionControl() {
        NSWorkspace.shared.launchApplication("Mission Control")
    }

    func showSettings() {
        openSettings()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Space Manager Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
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
