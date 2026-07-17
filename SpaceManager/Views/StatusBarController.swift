//
//  StatusBarController.swift
//  SpaceManager
//

import Cocoa
import SwiftUI

@MainActor
class StatusBarController: NSObject {
    var requestSpaceRefresh: ((@escaping () -> Void) -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private let spaceSwitcher = SpaceSwitcher()
    private var settingsWindow: NSWindow?
    private var workspaceEditorWindow: NSWindow?

    private var currentSpaces: [Space] = []
    private var physicalDisplayOrder: [String] = []
    private var missionControlDisplayOrder: [String] = []
    private var menuContextDisplayID: String?

    private let issueFetcher = GitHubIssueFetcher.shared
    private var issuesMenu: NSMenu?

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
        issueFetcher.startPeriodicRefresh()
    }

    func updateSpaces(_ spaces: [Space], missionControlDisplayOrder mcOrder: [String] = []) {
        currentSpaces = spaces

        var ids: [String] = []
        var seen = Set<String>()
        for space in spaces {
            if seen.insert(space.displayID).inserted {
                ids.append(space.displayID)
            }
        }
        physicalDisplayOrder = ids
        missionControlDisplayOrder = mcOrder.isEmpty ? ids : mcOrder

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

        let orderedDisplayIDs = orderedDisplayIDs(from: spaces)
        let multipleDisplays = orderedDisplayIDs.count > 1
        let activeDisplayUUID = multipleDisplays ? interactionDisplayID(from: orderedDisplayIDs) : nil

        // Reorder so the active display's spaces come first
        let sortedSpaces: [Space]
        if let activeUUID = activeDisplayUUID {
            let activeSpaces = spaces.filter { $0.displayID == activeUUID }
            let otherSpaces = spaces.filter { $0.displayID != activeUUID }
            sortedSpaces = activeSpaces + otherSpaces
        } else {
            sortedSpaces = spaces
        }

        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.submenu = buildNewSubmenu()
        statusMenu.addItem(newItem)

        let closeItem = NSMenuItem(title: "Close", action: nil, keyEquivalent: "")
        closeItem.submenu = buildCloseSubmenu(spaces)
        statusMenu.addItem(closeItem)

        let currentLabelItem = NSMenuItem(
            title: "Current Label...",
            action: #selector(editCurrentSpaceLabel),
            keyEquivalent: "l")
        currentLabelItem.keyEquivalentModifierMask = [.control, .option, .command]
        currentLabelItem.target = self
        statusMenu.addItem(currentLabelItem)

        let moveWindowItem = NSMenuItem(
            title: "Move Frontmost Window...",
            action: #selector(showWindowMoveMenu),
            keyEquivalent: "m")
        moveWindowItem.keyEquivalentModifierMask = [.control, .option, .command]
        moveWindowItem.target = self
        statusMenu.addItem(moveWindowItem)

        let issuesItem = NSMenuItem(title: "Issues", action: nil, keyEquivalent: "")
        let issMenu = NSMenu()
        issMenu.delegate = self
        issuesItem.submenu = issMenu
        issuesMenu = issMenu
        statusMenu.addItem(issuesItem)

        statusMenu.addItem(NSMenuItem.separator())

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

        let currentNameSource: NameSource? = {
            guard let current = currentSpace(in: spaces) else { return nil }
            let stored = SpaceNameStore.shared.loadAll()
            return stored[current.spaceID]?.nameSource
        }()
        if currentNameSource == .manual || currentNameSource == .workspace {
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

        let missionControlItem = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl), keyEquivalent: "m")
        missionControlItem.target = self
        statusMenu.addItem(missionControlItem)

        statusMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu()
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshSpaces), keyEquivalent: "r")
        refreshItem.target = self
        statusMenu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Space Manager", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func orderedDisplayIDs(from spaces: [Space]) -> [String] {
        var orderedDisplayIDs: [String] = []
        var seenDisplays = Set<String>()
        for space in spaces {
            if seenDisplays.insert(space.displayID).inserted {
                orderedDisplayIDs.append(space.displayID)
            }
        }
        return orderedDisplayIDs
    }

    private func interactionDisplayID(from candidates: [String]? = nil) -> String? {
        let displayIDs = candidates ?? physicalDisplayOrder
        guard !displayIDs.isEmpty else { return nil }

        if let menuContextDisplayID, displayIDs.contains(menuContextDisplayID) {
            return menuContextDisplayID
        }

        if let mouseDisplayID = DisplayGeometryUtilities.displayUUID(
            containing: NSEvent.mouseLocation,
            candidates: displayIDs)
        {
            return mouseDisplayID
        }

        return DisplayGeometryUtilities.activeDisplayUUID(from: displayIDs) ?? displayIDs.first
    }

    private func currentSpace(
        in spaces: [Space]? = nil,
        includeFullScreen: Bool = true,
        preferredDisplayID: String? = nil
    ) -> Space? {
        let allSpaces = spaces ?? currentSpaces
        let displayID = preferredDisplayID ?? interactionDisplayID(from: orderedDisplayIDs(from: allSpaces))

        if let displayID,
           let match = allSpaces.first(where: {
               $0.displayID == displayID && $0.isCurrentSpace && (includeFullScreen || !$0.isFullScreen)
           })
        {
            return match
        }

        return allSpaces.first { $0.isCurrentSpace && (includeFullScreen || !$0.isFullScreen) }
    }

    private func currentDesktopSpace(in spaces: [Space]? = nil, preferredDisplayID: String? = nil) -> Space? {
        currentSpace(in: spaces, includeFullScreen: false, preferredDisplayID: preferredDisplayID)
    }

    private func closeAllTargetSpaces(from desktopSpaces: [Space]) -> [Space] {
        let byDisplay = Dictionary(grouping: desktopSpaces, by: { $0.displayID })
        var targetSpaces: [Space] = []

        for (_, spacesOnDisplay) in byDisplay {
            guard spacesOnDisplay.count > 1 else { continue }
            let keepSpace = spacesOnDisplay.first(where: { $0.isCurrentSpace }) ?? spacesOnDisplay[0]
            targetSpaces += spacesOnDisplay.filter { $0.spaceID != keepSpace.spaceID }
        }

        return targetSpaces
    }

    private func closeableEmptyTargetSpaces(
        from desktopSpaces: [Space],
        windowsBySpaceID: [String: [SpaceWindow]]
    ) -> [Space] {
        let emptySpaces = desktopSpaces.filter { (windowsBySpaceID[$0.spaceID] ?? []).isEmpty }
        let byDisplay = Dictionary(grouping: desktopSpaces, by: { $0.displayID })
        let emptyByDisplay = Dictionary(grouping: emptySpaces, by: { $0.displayID })

        var targetSpaces: [Space] = []
        for (displayID, allOnDisplay) in byDisplay {
            guard var emptyOnDisplay = emptyByDisplay[displayID] else { continue }
            let occupiedCount = allOnDisplay.count - emptyOnDisplay.count
            if occupiedCount == 0 {
                let keepSpace = allOnDisplay.first(where: { $0.isCurrentSpace }) ?? allOnDisplay[0]
                emptyOnDisplay.removeAll { $0.spaceID == keepSpace.spaceID }
            }
            targetSpaces += emptyOnDisplay
        }

        return targetSpaces
    }

    private func makeSpaceMenuItem(space: Space) -> NSMenuItem {
        let prefix = space.isFullScreen ? "F" : "\(space.spaceByDesktopID)"
        let label = SpaceLabelStore.shared.label(for: space.spaceID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryName = SpaceDisplayName.title(for: space)

        let item = NSMenuItem(
            title: "\(prefix). \(primaryName)",
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
        let attributedName = NSMutableAttributedString(string: primaryName, attributes: nameAttrs)
        if let repositoryName = SpaceDisplayName.repositoryName(for: space) {
            let repositoryRange = (primaryName as NSString).range(of: "[\(repositoryName)]")
            if repositoryRange.location != NSNotFound {
                attributedName.addAttribute(
                    .foregroundColor,
                    value: RepositoryColor.color(for: repositoryName),
                    range: repositoryRange)
            }
        }
        attrTitle.append(attributedName)

        if label.isEmpty && space.hasDriftedName {
            let driftAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            attrTitle.append(NSAttributedString(string: "  \u{00B7}", attributes: driftAttrs))
        }

        if space.hasDriftedName {
            item.toolTip = "Windows have changed since workspace was created"
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

        submenu.addItem(NSMenuItem.separator())
        addSectionHeader("Workspaces", to: submenu)
        addWorkspaceItems(to: submenu)

        submenu.addItem(NSMenuItem.separator())
        addSectionHeader("Sites", to: submenu)
        addSiteItems(to: submenu)

        return submenu
    }

    private func addWorkspaceItems(to menu: NSMenu) {
        let workspaces = WorkspaceConfig.loadWorkspaces()

        if workspaces.isEmpty {
            let item = NSMenuItem(title: "No workspaces found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for workspace in workspaces {
            let item = NSMenuItem(
                title: workspace.displayName,
                action: #selector(launchWorkspace(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.key
            menu.addItem(item)
        }
    }

    private func addSiteItems(to menu: NSMenu) {
        let sites = WorkspaceConfig.loadSiteFolders()

        if sites.isEmpty {
            let item = NSMenuItem(title: "No sites found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for site in sites {
            let item = NSMenuItem(
                title: site.displayName,
                action: #selector(launchSite(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = ["name": site.displayName, "path": site.path]
            menu.addItem(item)
        }
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        menu.addItem(header)
    }

    // MARK: - Settings Submenu

    private func buildSettingsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        submenu.addItem(prefsItem)

        let workspacesItem = NSMenuItem(title: "Manage Workspaces...", action: #selector(openWorkspaceEditor), keyEquivalent: "")
        workspacesItem.target = self
        submenu.addItem(workspacesItem)

        submenu.addItem(NSMenuItem.separator())

        let devTermItem = NSMenuItem(title: "Open Dev Terminal", action: #selector(openDevTerminal), keyEquivalent: "")
        devTermItem.target = self
        submenu.addItem(devTermItem)

        return submenu
    }

    // MARK: - Transfer Submenu

    private func buildTransferSubmenu(_ spaces: [Space], orderedDisplayIDs: [String]) -> NSMenu {
        let submenu = NSMenu()

        guard let source = currentDesktopSpace(in: spaces), !source.isFullScreen else {
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

    @objc private func launchWorkspace(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        withFreshSpaces { [weak self] in
            guard let self else { return }
            let groupIndex = self.activeDisplayGroupIndex()

            SpaceCloser.addSpaceAndSwitch(
                toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayGroupIndex: groupIndex
            ) { _ in
                WorkspaceLauncher.launch(key)
            }
        }
    }

    @objc private func launchSite(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let path = info["path"]
        else { return }

        withFreshSpaces { [weak self] in
            guard let self else { return }
            let groupIndex = self.activeDisplayGroupIndex()

            SpaceCloser.addSpaceAndSwitch(
                toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayGroupIndex: groupIndex
            ) { [weak self] success in
                guard success else {
                    self?.refreshAfterClose()
                    return
                }

                WorkspaceLauncher.launchSite(name: name, path: path)
                self?.refreshAfterClose()
            }
        }
    }

    // MARK: - Close Submenu

    private func buildCloseSubmenu(_ spaces: [Space]) -> NSMenu {
        let submenu = NSMenu()

        let desktopSpaces = spaces.filter { !$0.isFullScreen }
        let currentDesktop = currentDesktopSpace(in: spaces)
        let currentDisplayDesktopCount = currentDesktop.map { currentDesktop in
            desktopSpaces.filter { space in
                space.displayID == currentDesktop.displayID
            }.count
        } ?? 0
        let canCloseCurrentDesktop = currentDisplayDesktopCount > 1
        let closeableEmptySpaces = closeableEmptyTargetSpaces(
            from: desktopSpaces,
            windowsBySpaceID: Dictionary(uniqueKeysWithValues: spaces.map { ($0.spaceID, $0.windows) }))
        let closeAllTargets = closeAllTargetSpaces(from: desktopSpaces)

        let closeCurrentTitle: String
        if let currentDesktop {
            closeCurrentTitle = "Close Current Space (\(currentDesktop.spaceByDesktopID))"
        } else {
            closeCurrentTitle = "Close Current Space"
        }

        let closeCurrentItem = NSMenuItem(
            title: closeCurrentTitle,
            action: currentDesktop != nil && canCloseCurrentDesktop ? #selector(closeCurrentSpace) : nil,
            keyEquivalent: "")
        closeCurrentItem.target = self
        submenu.addItem(closeCurrentItem)

        let hasWindows = currentDesktop.map { !$0.windows.isEmpty } ?? false
        let closeWithWindowsItem = NSMenuItem(
            title: "Close Current Space and Windows",
            action: currentDesktop != nil && canCloseCurrentDesktop && hasWindows
                ? #selector(closeCurrentSpaceAndWindows) : nil,
            keyEquivalent: "")
        closeWithWindowsItem.target = self
        submenu.addItem(closeWithWindowsItem)

        submenu.addItem(NSMenuItem.separator())

        for space in desktopSpaces {
            let sameDisplayDesktopCount = desktopSpaces.filter { $0.displayID == space.displayID }.count
            let item = makeCloseMenuItem(space: space, enabled: sameDisplayDesktopCount > 1)
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        let emptyItem = NSMenuItem(
            title: "Close Empty Spaces (\(closeableEmptySpaces.count))",
            action: !closeableEmptySpaces.isEmpty ? #selector(closeEmptySpaces) : nil,
            keyEquivalent: "")
        emptyItem.target = self
        submenu.addItem(emptyItem)

        let closeAllItem = NSMenuItem(
            title: "Close All Spaces",
            action: !closeAllTargets.isEmpty ? #selector(closeAllSpaces) : nil,
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

    // MARK: - Issues Submenu

    private func populateIssuesMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let issues = issueFetcher.issues

        if issues.isEmpty {
            let message: String
            if issueFetcher.isFetching {
                message = "Loading..."
            } else if let error = issueFetcher.lastError {
                message = error
            } else if issueFetcher.hasFetched {
                message = "No open issues"
            } else {
                message = "Loading..."
            }
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu()
            buildIssuesList(recentMenu, issues: issues, sortByRecent: true)
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)

            let azItem = NSMenuItem(title: "A to Z", action: nil, keyEquivalent: "")
            let azMenu = NSMenu()
            buildIssuesList(azMenu, issues: issues, sortByRecent: false)
            azItem.submenu = azMenu
            menu.addItem(azItem)
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Issues",
            action: #selector(refreshIssues),
            keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
    }

    private func buildIssuesList(_ menu: NSMenu, issues: [GitHubIssue], sortByRecent: Bool) {
        let grouped = Dictionary(grouping: issues, by: { $0.repoFullName })

        let sortedRepos: [String]
        if sortByRecent {
            sortedRepos = grouped.keys.sorted { a, b in
                let aMax = grouped[a]!.map(\.updatedAt).max() ?? ""
                let bMax = grouped[b]!.map(\.updatedAt).max() ?? ""
                return aMax > bMax
            }
        } else {
            sortedRepos = grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        for (index, repoFullName) in sortedRepos.enumerated() {
            if index > 0 { menu.addItem(NSMenuItem.separator()) }

            let repoName = repoFullName.components(separatedBy: "/").last ?? repoFullName
            addSectionHeader(repoName, to: menu)

            guard let repoIssues = grouped[repoFullName] else { continue }
            let sorted = sortByRecent
                ? repoIssues.sorted { $0.updatedAt > $1.updatedAt }
                : repoIssues

            for issue in sorted {
                addIssueMenuItem(issue, to: menu)
            }
        }
    }

    private func addIssueMenuItem(_ issue: GitHubIssue, to menu: NSMenu) {
        let info: [String: Any] = [
            "repoName": issue.repoName,
            "repoFullName": issue.repoFullName,
            "number": issue.number,
            "title": issue.title,
            "url": issue.url
        ]

        let item = NSMenuItem(
            title: "#\(issue.number) \(issue.title)",
            action: #selector(openIssueProject(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = info

        let attrTitle = NSMutableAttributedString()
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        attrTitle.append(NSAttributedString(string: "#\(issue.number) ", attributes: numAttrs))

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let truncatedTitle = issue.title.count > 60
            ? String(issue.title.prefix(57)) + "..."
            : issue.title
        attrTitle.append(NSAttributedString(string: truncatedTitle, attributes: titleAttrs))

        item.attributedTitle = attrTitle
        menu.addItem(item)

        let altItem = NSMenuItem(
            title: "#\(issue.number) \(issue.title)",
            action: #selector(openIssueInBrowser(_:)),
            keyEquivalent: "")
        altItem.target = self
        altItem.representedObject = info
        altItem.isAlternate = true
        altItem.keyEquivalentModifierMask = .option

        let altAttrTitle = NSMutableAttributedString(attributedString: attrTitle)
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        altAttrTitle.append(NSAttributedString(string: "  \u{2197}", attributes: arrowAttrs))
        altItem.attributedTitle = altAttrTitle
        menu.addItem(altItem)
    }

    @objc private func openIssueProject(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let repoName = info["repoName"] as? String,
              let repoFullName = info["repoFullName"] as? String,
              let number = info["number"] as? Int
        else { return }

        // Check for configured workspace
        if let workspaceKey = WorkspaceConfig.workspaceKey(forRepoName: repoName) {
            withFreshSpaces { [weak self] in
                guard let self else { return }
                let groupIndex = self.activeDisplayGroupIndex()
                let issueNum = number
                SpaceCloser.addSpaceAndSwitch(
                    toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                    displayGroupIndex: groupIndex
                ) { [weak self] _ in
                    WorkspaceLauncher.launch(workspaceKey)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        self?.sendIssueToIdleTerminal(issueNumber: issueNum)
                    }
                }
            }
            return
        }

        // Find local project by name or git remote
        if let localPath = GitHubIssueFetcher.localProjectPath(for: repoName, repoFullName: repoFullName) {
            withFreshSpaces { [weak self] in
                guard let self else { return }
                let groupIndex = self.activeDisplayGroupIndex()
                SpaceCloser.addSpaceAndSwitch(
                    toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                    displayGroupIndex: groupIndex
                ) { [weak self] success in
                    guard success else {
                        self?.refreshAfterClose()
                        return
                    }
                    WorkspaceLauncher.launchSite(name: repoName, path: localPath, issueNumber: number)
                    self?.refreshAfterClose()
                }
            }
            return
        }

        NSSound.beep()
    }

    @objc private func openIssueInBrowser(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let url = info["url"] as? String,
              let issueURL = URL(string: url)
        else { return }
        NSWorkspace.shared.open(issueURL)
    }

    @objc private func refreshIssues() {
        issueFetcher.fetch()
    }

    // Finds an idle Terminal tab (not busy) among the frontmost windows
    // and sends `todo <number>` to it. Retries up to 3 times with 2s gaps
    // to handle workspace startup timing.
    private func sendIssueToIdleTerminal(issueNumber: Int, retryCount: Int = 0) {
        guard retryCount < 3 else { return }

        let script = """
        tell application "Terminal"
            if (count of windows) is 0 then return "none"
            set windowLimit to count of windows
            if windowLimit > 4 then set windowLimit to 4
            repeat with i from 1 to windowLimit
                set w to window i
                repeat with t in tabs of w
                    if busy of t is false then
                        do script "todo \(issueNumber)" in t
                        return "sent"
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error)
            let sent = result?.stringValue == "sent"

            if !sent {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.sendIssueToIdleTerminal(issueNumber: issueNumber, retryCount: retryCount + 1)
                }
            }
        }
    }

    // MARK: - Display Helpers

    private func displayGroupIndex(for displayID: String) -> Int {
        (missionControlDisplayOrder.firstIndex(of: displayID) ?? 0) + 1
    }

    private func activeDisplayGroupIndex() -> Int {
        guard let uuid = interactionDisplayID() else { return 1 }
        return displayGroupIndex(for: uuid)
    }

    private func activeDisplayID() -> String? {
        interactionDisplayID()
    }

    private func nextDesktopNumberOnActiveDisplay() -> Int {
        guard let displayID = activeDisplayID() else {
            return currentSpaces.filter { !$0.isFullScreen }.count + 1
        }

        return currentSpaces.filter {
            $0.displayID == displayID && !$0.isFullScreen
        }.count + 1
    }

    private func desktopIndexOnDisplay(for space: Space) -> Int? {
        guard !space.isFullScreen else { return nil }
        let sameDisplayDesktops = currentSpaces.filter {
            $0.displayID == space.displayID && !$0.isFullScreen
        }
        guard let index = sameDisplayDesktops.firstIndex(where: { $0.spaceID == space.spaceID }) else { return nil }
        return index + 1
    }

    private func closeTarget(for space: Space) -> SpaceCloser.CloseTarget? {
        guard let desktopIndex = desktopIndexOnDisplay(for: space) else { return nil }
        return SpaceCloser.CloseTarget(
            displayGroup: displayGroupIndex(for: space.displayID),
            desktopIndex: desktopIndex)
    }

    private func focusTarget(afterClosing targetSpaces: [Space], preferredClosedSpace: Space) -> SpaceCloser.FocusTarget? {
        let targetIDs = Set(targetSpaces.map { $0.spaceID })
        let displaySpaces = currentSpaces.filter {
            $0.displayID == preferredClosedSpace.displayID && !$0.isFullScreen
        }
        guard let closingIndex = displaySpaces.firstIndex(where: { $0.spaceID == preferredClosedSpace.spaceID }) else {
            return nil
        }

        let remainingSpaces = displaySpaces.filter { !targetIDs.contains($0.spaceID) }
        guard !remainingSpaces.isEmpty else { return nil }

        var focusSpace: Space?
        if closingIndex > 0 {
            for index in stride(from: closingIndex - 1, through: 0, by: -1) {
                let candidate = displaySpaces[index]
                if !targetIDs.contains(candidate.spaceID) {
                    focusSpace = candidate
                    break
                }
            }
        }
        if focusSpace == nil {
            for index in (closingIndex + 1)..<displaySpaces.count {
                let candidate = displaySpaces[index]
                if !targetIDs.contains(candidate.spaceID) {
                    focusSpace = candidate
                    break
                }
            }
        }

        guard let focusSpace,
              let finalIndex = remainingSpaces.firstIndex(where: { $0.spaceID == focusSpace.spaceID })
        else { return nil }

        return SpaceCloser.FocusTarget(
            displayGroup: displayGroupIndex(for: focusSpace.displayID),
            desktopIndex: finalIndex + 1)
    }

    private func withFreshSpaces(_ action: @escaping () -> Void) {
        guard let requestSpaceRefresh else {
            action()
            return
        }

        requestSpaceRefresh {
            DispatchQueue.main.async {
                action()
            }
        }
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
        } else if let current = currentSpace(in: currentSpaces),
                  current.displayID == target.displayID,
                  !current.isFullScreen,
                  !target.isFullScreen,
                  let currentDesktopIndex = desktopIndexOnDisplay(for: current),
                  let targetDesktopIndex = desktopIndexOnDisplay(for: target)
        {
            spaceSwitcher.navigateToSpace(
                from: currentDesktopIndex,
                to: targetDesktopIndex) {
                    self.showSwitchError()
                }
        } else if !target.isFullScreen,
                  let desktopIndex = desktopIndexOnDisplay(for: target) {
            spaceSwitcher.switchViaMissionControl(
                displayGroupIndex: displayGroupIndex(for: target.displayID),
                desktopIndex: desktopIndex)
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
        guard let current = currentSpace() else { return }

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

    @objc private func editCurrentSpaceLabel() {
        SpaceLabelController.shared?.editCurrentSpace()
    }

    @objc private func showWindowMoveMenu() {
        DispatchQueue.main.async {
            WindowMoveController.shared?.showMoveMenu()
        }
    }

    @objc private func clearCurrentSpaceName() {
        guard let current = currentSpace() else { return }
        NotificationCenter.default.post(
            name: NSNotification.Name("RenameSpace"),
            object: nil,
            userInfo: ["spaceID": current.spaceID, "name": ""])
    }

    @objc private func closeSpace(_ sender: NSMenuItem) {
        let spaceID = sender.representedObject as? String
        withFreshSpaces { [weak self] in
            self?.performCloseSpace(spaceID: spaceID)
        }
    }

    private func performCloseSpace(spaceID: String?) {
        guard let spaceID,
              let space = currentSpaces.first(where: { $0.spaceID == spaceID }),
              let target = closeTarget(for: space) else { return }
        let focusTarget = self.focusTarget(afterClosing: [space], preferredClosedSpace: space)
        SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeCurrentSpace() {
        withFreshSpaces { [weak self] in
            self?.performCloseCurrentSpace()
        }
    }

    private func performCloseCurrentSpace() {
        guard let current = currentDesktopSpace(),
              let target = closeTarget(for: current) else { return }

        let sameDisplayDesktops = currentSpaces.filter {
            $0.displayID == current.displayID && !$0.isFullScreen
        }
        guard sameDisplayDesktops.count > 1 else { return }

        let focusTarget = self.focusTarget(afterClosing: [current], preferredClosedSpace: current)
        SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeCurrentSpaceAndWindows() {
        withFreshSpaces { [weak self] in
            self?.performCloseCurrentSpaceAndWindows()
        }
    }

    private func performCloseCurrentSpaceAndWindows() {
        guard let current = currentDesktopSpace(),
              let target = closeTarget(for: current) else { return }

        let sameDisplayDesktops = currentSpaces.filter {
            $0.displayID == current.displayID && !$0.isFullScreen
        }
        guard sameDisplayDesktops.count > 1 else { return }

        closeWindowsViaAccessibility(current.windows)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let focusTarget = self.focusTarget(afterClosing: [current], preferredClosedSpace: current)
            SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] _ in
                self?.refreshAfterClose()
            }
        }
    }

    private func closeWindowsViaAccessibility(_ windows: [SpaceWindow]) {
        for window in windows {
            let appElement = AXUIElementCreateApplication(window.ownerPID)
            var axWindowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
                  let axWindows = axWindowsRef as? [AXUIElement]
            else { continue }

            for axWindow in axWindows {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                var pos = CGPoint.zero
                var size = CGSize.zero
                if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
                if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }

                let axBounds = CGRect(origin: pos, size: size)
                guard abs(axBounds.origin.x - window.bounds.origin.x) < 2,
                      abs(axBounds.origin.y - window.bounds.origin.y) < 2,
                      abs(axBounds.width - window.bounds.width) < 2,
                      abs(axBounds.height - window.bounds.height) < 2
                else { continue }

                var closeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success {
                    AXUIElementPerformAction(closeRef as! AXUIElement, kAXPressAction as CFString)
                }
                break
            }
        }
    }

    @objc private func closeEmptySpaces() {
        withFreshSpaces { [weak self] in
            self?.performCloseEmptySpaces()
        }
    }

    private func performCloseEmptySpaces() {
        let freshWindows = WindowDetector.detectWindowsPerSpace()
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        let targetSpaces = closeableEmptyTargetSpaces(from: desktopSpaces, windowsBySpaceID: freshWindows)

        let targets = targetSpaces.compactMap { closeTarget(for: $0) }
        guard !targets.isEmpty else { return }

        let current = currentDesktopSpace()
        let focusTarget = current.flatMap { current in
            targetSpaces.contains(where: { $0.spaceID == current.spaceID })
                ? self.focusTarget(afterClosing: targetSpaces, preferredClosedSpace: current)
                : nil
        }

        SpaceCloser.closeSpaces(targets: targets, focusTarget: focusTarget) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func closeAllSpaces() {
        withFreshSpaces { [weak self] in
            self?.performCloseAllSpaces()
        }
    }

    private func performCloseAllSpaces() {
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        let targetSpaces = closeAllTargetSpaces(from: desktopSpaces)

        let targets = targetSpaces.compactMap { closeTarget(for: $0) }
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Close All Spaces?"
        alert.informativeText = "This will close \(targets.count) space\(targets.count == 1 ? "" : "s"), keeping one desktop per display."
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let current = currentDesktopSpace()
        let focusTarget = current.flatMap { current in
            targetSpaces.contains(where: { $0.spaceID == current.spaceID })
                ? self.focusTarget(afterClosing: targetSpaces, preferredClosedSpace: current)
                : nil
        }

        SpaceCloser.closeSpaces(targets: targets, focusTarget: focusTarget) { [weak self] _ in
            self?.refreshAfterClose()
        }
    }

    @objc private func addSpace() {
        withFreshSpaces { [weak self] in
            guard let self else { return }
            let groupIndex = self.activeDisplayGroupIndex()
            SpaceCloser.addSpace(displayGroupIndex: groupIndex) { [weak self] _ in
                self?.refreshAfterClose()
            }
        }
    }

    @objc private func addTerminalSpace() {
        withFreshSpaces { [weak self] in
            guard let self, let targetDisplayID = self.activeDisplayID() else { return }
            let groupIndex = self.activeDisplayGroupIndex()

            WorkspaceAutomation.createTerminalSpace(
                targetDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayGroupIndex: groupIndex,
                targetDisplayID: targetDisplayID
            ) { [weak self] _ in
                self?.refreshAfterClose()
            }
        }
    }

    @objc private func openDevTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd ~/Sites/mac-space-manager"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error {
                NSLog("openDevTerminal AppleScript failed: \(error)")
            }
        }
    }

    @objc private func showMissionControl() {
        NSWorkspace.shared.launchApplication("Mission Control")
    }

    func showSettings() {
        openSettings()
    }

    @objc private func openWorkspaceEditor() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = workspaceEditorWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Manage Workspaces"
        window.contentView = NSHostingView(rootView: WorkspaceEditorView())
        window.contentMinSize = NSSize(width: 600, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        workspaceEditorWindow = window
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
    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu {
            menuContextDisplayID = DisplayGeometryUtilities.displayUUID(
                containing: NSEvent.mouseLocation,
                candidates: physicalDisplayOrder)
            issueFetcher.refreshIfNeeded()
            requestSpaceRefresh? {}
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === issuesMenu {
            populateIssuesMenu(menu)
        }
    }
}
