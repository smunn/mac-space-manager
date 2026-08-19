//
//  StatusBarController.swift
//  SpaceManager
//

import Cocoa
import SwiftUI
@preconcurrency import UserNotifications

private let issueCreatedNotificationCategory = "ISSUE_CREATED"
private let openCreatedIssueNotificationAction = "OPEN_CREATED_ISSUE"
private let createdIssueURLNotificationKey = "issueURL"

@MainActor
class StatusBarController: NSObject {
    var requestSpaceRefresh: ((@escaping (Bool) -> Void) -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private let spaceSwitcher = SpaceSwitcher()
    private var settingsWindow: NSWindow?
    private var settingsWindowModel: SettingsWindowModel?
    private var permissionsMenuItem: NSMenuItem?
    private var permissionsMenuSeparator: NSMenuItem?
    private var workspaceEditorWindow: NSWindow?
    private var createIssueWindow: NSWindow?
    private var createIssueHasPendingChanges = false
    private var allowCreateIssueClose = false
    private var createIssueCloseConfirmationVisible = false
    private var windowLayoutShortcutCoordinator: MagnetShortcutEditorCoordinator?

    private var currentSpaces: [Space] = []
    private var physicalDisplayOrder: [String] = []
    private var missionControlDisplayOrder: [String] = []
    private var menuContextDisplayID: String?

    private let issueFetcher = GitHubIssueFetcher.shared
    private var issuesMenu: NSMenu?
    private var chromeProfilesMenu: NSMenu?
    private let performanceMonitor = SystemPerformanceMonitor()
    private let processHealthMonitor = ProcessHealthMonitor()
    private let aiLimitsReader = AILimitsSnapshotReader.shared
    private var performanceTimer: Timer?
    private var performanceSnapshot: SystemPerformanceSnapshot?
    private let aiLimitsViewModel = AILimitsMenuViewModel()
    private let performanceViewModel = PerformanceMenuViewModel()
    private weak var performanceHostingView: NSView?
    private var statusMenuIsOpen = false
    private var pendingProcessHealthSnapshot: ProcessHealthSnapshot?
    private var aiLimitsCloudRefreshInFlight = false
    private var aiSessionInspectorController: AISessionInspectorController?

    override init() {
        super.init()

        UNUserNotificationCenter.current().delegate = self
        configureIssueNotificationCategory()
        configureProcessHealthActions()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetCurrentSpace),
            name: NSNotification.Name("ResetCurrentSpace"),
            object: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = NSMenu()
        statusMenu.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Spaces")
            button.image?.size = NSSize(width: 16, height: 16)
        }

        statusItem.menu = statusMenu
        issueFetcher.startPeriodicRefresh()
        refreshProcessHealth(force: true)
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
        if let button = statusItem.button {
            let number: String
            if physicalDisplayOrder.count > 1 {
                number = "\(physicalDisplayOrder.count)"
            } else {
                guard let current = spaces.first(where: \.isCurrentSpace) else { return }
                let desktopCount = spaces.filter { !$0.isFullScreen }.count
                number = current.isFullScreen ? "F" : "\(current.spaceByDesktopID)/\(desktopCount)"
            }
            button.title = " \(number)"
            button.imagePosition = .imageLeading
        }
    }

    // MARK: - Menu Construction

    private func rebuildMenu(_ spaces: [Space]) {
        statusMenu.removeAllItems()

        let permissionsItem = NSMenuItem(
            title: "Window Management Permissions Needed…",
            action: #selector(openWindowManagementPermissions),
            keyEquivalent: "")
        permissionsItem.target = self
        statusMenu.addItem(permissionsItem)
        permissionsMenuItem = permissionsItem

        let permissionsSeparator = NSMenuItem.separator()
        statusMenu.addItem(permissionsSeparator)
        permissionsMenuSeparator = permissionsSeparator
        refreshPermissionsMenuItem()

        addAILimitsSection(to: statusMenu)
        statusMenu.addItem(NSMenuItem.separator())

        addPerformanceSection(to: statusMenu)
        statusMenu.addItem(NSMenuItem.separator())

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

        let desktopSpaces = spaces.filter { !$0.isFullScreen }
        let closeAllTargets = closeAllTargetSpaces(from: desktopSpaces)
        let closeAllItem = NSMenuItem(
            title: "Close All Spaces",
            action: !closeAllTargets.isEmpty ? #selector(closeAllSpaces) : nil,
            keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.control, .option, .shift, .command]
        closeAllItem.target = self
        statusMenu.addItem(closeAllItem)

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

        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        newItem.submenu = buildNewSubmenu()
        statusMenu.addItem(newItem)

        let currentSpaceItem = NSMenuItem(title: "Current Space", action: nil, keyEquivalent: "")
        currentSpaceItem.submenu = buildCurrentSpaceSubmenu(
            spaces,
            orderedDisplayIDs: orderedDisplayIDs)
        statusMenu.addItem(currentSpaceItem)

        let closeItem = NSMenuItem(title: "Close", action: nil, keyEquivalent: "")
        closeItem.submenu = buildCloseSubmenu(spaces)
        statusMenu.addItem(closeItem)

        let moveWindowItem = NSMenuItem(
            title: "Move Frontmost Window...",
            action: #selector(showWindowMoveMenu),
            keyEquivalent: "m")
        moveWindowItem.keyEquivalentModifierMask = [.control, .option, .command]
        moveWindowItem.target = self
        statusMenu.addItem(moveWindowItem)

        let windowLayoutsItem = NSMenuItem(title: "Window Layouts", action: nil, keyEquivalent: "")
        windowLayoutsItem.submenu = WindowLayoutManager.shared.makeMenu()
        statusMenu.addItem(windowLayoutsItem)

        let openChromeItem = NSMenuItem(title: "Open Chrome…", action: nil, keyEquivalent: "")
        let chromeMenu = NSMenu()
        chromeMenu.delegate = self
        openChromeItem.submenu = chromeMenu
        chromeProfilesMenu = chromeMenu
        statusMenu.addItem(openChromeItem)

        let issuesItem = NSMenuItem(title: "Issues", action: nil, keyEquivalent: "")
        let issMenu = NSMenu()
        issMenu.delegate = self
        issuesItem.submenu = issMenu
        issuesMenu = issMenu
        statusMenu.addItem(issuesItem)

        statusMenu.addItem(NSMenuItem.separator())

        let missionControlItem = NSMenuItem(title: "Mission Control", action: #selector(showMissionControl), keyEquivalent: "m")
        missionControlItem.target = self
        statusMenu.addItem(missionControlItem)

        statusMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = buildSettingsSubmenu()
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Space Manager", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    // MARK: - Performance

    private func addAILimitsSection(to menu: NSMenu) {
        refreshAILimits()
        let item = NSMenuItem(title: "AI Limits", action: nil, keyEquivalent: "")
        let view = NSHostingView(rootView: AILimitsMenuView(model: aiLimitsViewModel))
        view.frame = NSRect(x: 0, y: 0, width: 456, height: 70)
        item.view = view
        menu.addItem(item)
    }

    private func refreshAILimits() {
        if let result = aiLimitsReader.readResult() {
            aiLimitsViewModel.snapshot = result.snapshot
            aiLimitsViewModel.source = result.source
        }
        aiLimitsViewModel.displayedAt = Date()

        guard aiLimitsReader.needsCloudFallback,
              !aiLimitsCloudRefreshInFlight
        else { return }

        aiLimitsCloudRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.aiLimitsReader.fetchCloudSnapshot()
            self.aiLimitsCloudRefreshInFlight = false
            guard let snapshot else { return }
            self.aiLimitsViewModel.snapshot = snapshot
            self.aiLimitsViewModel.source = .supabase
            self.aiLimitsViewModel.displayedAt = Date()
        }
    }

    private func addPerformanceSection(to menu: NSMenu) {
        performanceViewModel.snapshot = performanceSnapshot
        let item = NSMenuItem(title: "Performance", action: nil, keyEquivalent: "")
        let view = NSHostingView(rootView: PerformanceMenuView(model: performanceViewModel))
        view.frame = NSRect(x: 0, y: 0, width: 456, height: 1)
        sizePerformanceHostingView(view)
        performanceHostingView = view
        item.view = view
        menu.addItem(item)
    }

    private func updatePerformanceMenuHeight() {
        guard !statusMenuIsOpen, let view = performanceHostingView else { return }
        sizePerformanceHostingView(view)
        statusMenu.update()
    }

    private func sizePerformanceHostingView(_ view: NSView) {
        // NSMenu determines its window height before presenting custom item views.
        // Measure synchronously so a later SwiftUI resize cannot leave the top of
        // the card clipped while the menu keeps the old height as blank space.
        view.layoutSubtreeIfNeeded()
        let height = ceil(view.fittingSize.height)
        guard height > 0 else { return }
        view.setFrameSize(NSSize(width: view.frame.width, height: height))
    }

    private func configureProcessHealthActions() {
        performanceViewModel.openActivityMonitor = {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.ActivityMonitor")
            else { return }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        performanceViewModel.reviewSimulator = { [weak self] item in
            self?.processHealthMonitor.review(item)
        }
        performanceViewModel.shutDownSimulator = { [weak self] item in
            self?.processHealthMonitor.shutDown(item) { [weak self] _ in
                Task { @MainActor in self?.refreshProcessHealth(force: true) }
            }
        }
        performanceViewModel.inspectAISession = { [weak self] item in
            self?.inspectAISession(item)
        }
        performanceViewModel.cleanUpAISession = { [weak self] item in
            guard let self,
                  self.performanceViewModel.terminatingAISessionIDs.insert(item.id).inserted
            else { return }

            self.performanceViewModel.processActionStatus = ProcessActionStatus(
                message: "Terminating \(item.service.rawValue) PID \(item.processID)…",
                succeeded: nil)
            self.updatePerformanceMenuHeight()
            self.sendProcessNotification(
                title: "Terminating \(item.service.rawValue) Process",
                body: "PID \(item.processID) · \(item.detail ?? "Unknown working directory")")

            self.processHealthMonitor.cleanUp(item) { [weak self] success in
                Task { @MainActor in
                    guard let self else { return }
                    self.performanceViewModel.terminatingAISessionIDs.remove(item.id)
                    let cpu = item.cpuUsagePercent.formatted(.number.precision(.fractionLength(0)))
                    if success {
                        self.performanceViewModel.processActionStatus = ProcessActionStatus(
                            message: "Terminated \(item.service.rawValue) PID \(item.processID) · CPU time \(compactElapsed(item.cpuTime)) · CPU \(cpu)%",
                            succeeded: true)
                        self.sendProcessNotification(
                            title: "\(item.service.rawValue) Process Terminated",
                            body: "PID \(item.processID) · CPU time \(compactElapsed(item.cpuTime)) · CPU \(cpu)%")
                    } else {
                        self.performanceViewModel.processActionStatus = ProcessActionStatus(
                            message: "Could not terminate \(item.service.rawValue) PID \(item.processID)",
                            succeeded: false)
                        self.sendProcessNotification(
                            title: "Process Termination Failed",
                            body: "\(item.service.rawValue) PID \(item.processID)")
                    }
                    self.refreshProcessHealth(force: true)
                }
            }
        }
        performanceViewModel.cleanUpRecommendedAISessions = { [weak self] items in
            guard let self else { return }
            let recommended = items.filter {
                $0.canCleanUp && !self.performanceViewModel.terminatingAISessionIDs.contains($0.id)
            }
            guard !recommended.isEmpty else { return }

            self.performanceViewModel.terminatingAISessionIDs.formUnion(recommended.map(\.id))
            let service = recommended[0].service.rawValue
            self.performanceViewModel.processActionStatus = ProcessActionStatus(
                message: "Terminating \(recommended.count) recommended \(service) processes…",
                succeeded: nil)
            self.updatePerformanceMenuHeight()
            self.sendProcessNotification(
                title: "Terminating Recommended \(service) Processes",
                body: "\(recommended.count) processes")

            self.processHealthMonitor.cleanUp(recommended) { [weak self] successCount in
                Task { @MainActor in
                    guard let self else { return }
                    self.performanceViewModel.terminatingAISessionIDs.subtract(recommended.map(\.id))
                    let success = successCount == recommended.count
                    let message = "Terminated \(successCount) of \(recommended.count) recommended \(service) processes"
                    self.performanceViewModel.processActionStatus = ProcessActionStatus(
                        message: message,
                        succeeded: success)
                    self.sendProcessNotification(
                        title: success ? "Recommended Processes Terminated" : "Process Termination Incomplete",
                        body: message)
                    self.refreshProcessHealth(force: true)
                }
            }
        }
    }

    private func inspectAISession(_ item: AISessionHealthItem) {
        let controller = AISessionInspectorController(item: item) { [weak self] in
            self?.confirmAndResumeAISession(item)
        }
        aiSessionInspectorController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func confirmAndResumeAISession(_ item: AISessionHealthItem) {
        guard let sessionID = item.sessionID,
              !sessionID.isEmpty
        else { return }

        let alert = NSAlert()
        alert.messageText = "Resume \(item.service.rawValue) Session?"
        alert.informativeText = "This terminates PID \(item.processID), then opens the saved session in Terminal."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard performanceViewModel.terminatingAISessionIDs.insert(item.id).inserted else { return }
        performanceViewModel.processActionStatus = ProcessActionStatus(
            message: "Preparing \(item.service.rawValue) PID \(item.processID) to resume…",
            succeeded: nil)

        processHealthMonitor.cleanUp(item) { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                guard terminated else {
                    self.performanceViewModel.terminatingAISessionIDs.remove(item.id)
                    self.performanceViewModel.processActionStatus = ProcessActionStatus(
                        message: "Could not terminate \(item.service.rawValue) PID \(item.processID)",
                        succeeded: false)
                    self.refreshProcessHealth(force: true)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    let launched = AISessionLauncher.resume(
                        service: item.service,
                        sessionID: sessionID,
                        projectPath: item.projectPath)
                    DispatchQueue.main.async {
                        self.performanceViewModel.terminatingAISessionIDs.remove(item.id)
                        self.performanceViewModel.processActionStatus = ProcessActionStatus(
                            message: launched
                                ? "Resumed \(item.service.rawValue) session \(sessionID) in Terminal"
                                : "Could not resume \(item.service.rawValue) session \(sessionID)",
                            succeeded: launched)
                        self.refreshProcessHealth(force: true)
                    }
                }
            }
        }
    }

    private func sendProcessNotification(title: String, body: String) {
        sendNotification(
            title: title,
            body: body,
            sound: .default,
            identifierPrefix: "process-health")
    }

    private func sendSpaceNotification(title: String) {
        sendNotification(
            title: title,
            body: nil,
            sound: nil,
            identifierPrefix: "space-operation")
    }

    private func configureIssueNotificationCategory() {
        let center = UNUserNotificationCenter.current()
        let openAction = UNNotificationAction(
            identifier: openCreatedIssueNotificationAction,
            title: "Open Issue",
            options: [.foreground])
        let category = UNNotificationCategory(
            identifier: issueCreatedNotificationCategory,
            actions: [openAction],
            intentIdentifiers: [],
            options: [])

        center.getNotificationCategories { categories in
            var updatedCategories = categories
            updatedCategories.update(with: category)
            center.setNotificationCategories(updatedCategories)
        }
    }

    private func sendIssueCreatedNotification(
        issue: CreatedGitHubIssue,
        repository: String
    ) {
        sendNotification(
            title: "Issue Created",
            body: "\(repository) #\(issue.number)",
            sound: .default,
            identifierPrefix: "issue-created",
            categoryIdentifier: issueCreatedNotificationCategory,
            userInfo: [createdIssueURLNotificationKey: issue.htmlURL.absoluteString])
    }

    private func sendNotification(
        title: String,
        body: String?,
        sound: UNNotificationSound?,
        identifierPrefix: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            if let body {
                content.body = body
            }
            content.sound = sound
            if let categoryIdentifier {
                content.categoryIdentifier = categoryIdentifier
            }
            content.userInfo = userInfo
            center.add(UNNotificationRequest(
                identifier: "\(identifierPrefix)-\(UUID().uuidString)",
                content: content,
                trigger: nil))
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { deliver() }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func refreshProcessHealth(force: Bool = false) {
        performanceViewModel.isRefreshingProcessHealth = true
        processHealthMonitor.refreshIfNeeded(force: force) { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                if self.statusMenuIsOpen {
                    self.pendingProcessHealthSnapshot = snapshot
                } else {
                    self.performanceViewModel.processHealthSnapshot = snapshot
                }
                self.performanceViewModel.isRefreshingProcessHealth = false
                self.updatePerformanceMenuHeight()
            }
        }
    }

    private func startPerformanceMonitoring() {
        performanceTimer?.invalidate()
        performanceSnapshot = nil
        performanceViewModel.snapshot = nil

        // The first collection establishes delta counters while immediately
        // publishing memory, battery, and thermal values. Take a short follow-up
        // sample so CPU/network/disk appear without waiting for the regular cycle.
        performanceMonitor.start { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.performanceTimer != nil else { return }
                self.performanceSnapshot = snapshot
                self.performanceViewModel.snapshot = snapshot
            }
        }

        let warmupTimer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.performanceMonitor.sample { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self, self.performanceTimer != nil else { return }
                    self.performanceSnapshot = snapshot
                    self.performanceViewModel.snapshot = snapshot
                    self.startRegularPerformanceTimer()
                }
            }
        }
        performanceTimer = warmupTimer
        RunLoop.main.add(warmupTimer, forMode: .common)
    }

    private func startRegularPerformanceTimer() {
        performanceTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.performanceMonitor.sample { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self, self.performanceTimer != nil else { return }
                    self.performanceSnapshot = snapshot
                    self.performanceViewModel.snapshot = snapshot
                }
            }
        }
        performanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPerformanceMonitoring() {
        performanceTimer?.invalidate()
        performanceTimer = nil
        performanceMonitor.stop()
    }

    // MARK: - Current Space Submenu

    private func buildCurrentSpaceSubmenu(
        _ spaces: [Space],
        orderedDisplayIDs: [String]
    ) -> NSMenu {
        let submenu = NSMenu()
        let current = currentSpace(in: spaces)

        let renameItem = NSMenuItem(
            title: "Rename...",
            action: current != nil ? #selector(renameCurrentSpace) : nil,
            keyEquivalent: "")
        renameItem.target = self
        submenu.addItem(renameItem)

        if let current {
            let currentNameSource = SpaceNameStore.shared.loadAll()[current.spaceID]?.nameSource
            if currentNameSource == .manual || currentNameSource == .workspace {
                let clearItem = NSMenuItem(
                    title: "Clear Name Override",
                    action: #selector(clearCurrentSpaceName),
                    keyEquivalent: "")
                clearItem.target = self
                submenu.addItem(clearItem)
            }
        }

        let resetItem = NSMenuItem(
            title: "Reset Current Space",
            action: current != nil ? #selector(resetCurrentSpace) : nil,
            keyEquivalent: "")
        resetItem.target = self
        submenu.addItem(resetItem)

        submenu.addItem(NSMenuItem.separator())

        let labelItem = NSMenuItem(
            title: "Label...",
            action: current != nil ? #selector(editCurrentSpaceLabel) : nil,
            keyEquivalent: "l")
        labelItem.keyEquivalentModifierMask = [.control, .option, .command]
        labelItem.target = self
        submenu.addItem(labelItem)

        if orderedDisplayIDs.count > 1 {
            let transferItem = NSMenuItem(title: "Transfer", action: nil, keyEquivalent: "")
            transferItem.submenu = buildTransferSubmenu(
                spaces,
                orderedDisplayIDs: orderedDisplayIDs)
            submenu.addItem(transferItem)
        }

        return submenu
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

        if let mouseDisplayID = displayIDAtPointer(from: displayIDs) {
            return mouseDisplayID
        }

        return DisplayGeometryUtilities.activeDisplayUUID(from: displayIDs) ?? displayIDs.first
    }

    private func displayIDAtPointer(from candidates: [String]) -> String? {
        DisplayGeometryUtilities.displayUUID(
            containing: NSEvent.mouseLocation,
            candidates: candidates)
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

        let terminalItem = NSMenuItem(title: "Terminal Space", action: #selector(addTerminalSpace), keyEquivalent: "t")
        terminalItem.keyEquivalentModifierMask = [.control, .option, .command]
        terminalItem.target = self
        submenu.addItem(terminalItem)

        let terminalWindowCount = terminalWindowsForOrganization().count
        let organizeTerminalItem = NSMenuItem(
            title: "Create Spaces for Terminal Windows (\(terminalWindowCount))",
            action: terminalWindowCount > 0 ? #selector(createSpacesForTerminalWindows) : nil,
            keyEquivalent: ".")
        organizeTerminalItem.keyEquivalentModifierMask = [.control, .option, .shift, .command]
        organizeTerminalItem.target = self
        submenu.addItem(organizeTerminalItem)

        let fillTerminalItem = NSMenuItem(
            title: "Fill Terminal Windows",
            action: terminalWindowCount > 0 ? #selector(fillTerminalWindows) : nil,
            keyEquivalent: "")
        fillTerminalItem.target = self
        submenu.addItem(fillTerminalItem)

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

    private func addSectionHeader(
        _ title: String,
        to menu: NSMenu,
        foregroundColor: NSColor = .tertiaryLabelColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: foregroundColor
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

        let windowShortcutsItem = NSMenuItem(
            title: "Manage Window Layout Shortcuts...",
            action: #selector(openWindowLayoutShortcutEditor),
            keyEquivalent: "")
        windowShortcutsItem.target = self
        submenu.addItem(windowShortcutsItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshSpaces), keyEquivalent: "r")
        refreshItem.target = self
        submenu.addItem(refreshItem)

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
            guard let self, let displayID = self.activeDisplayID() else { return }
            let groupIndex = self.activeDisplayGroupIndex()

            SpaceCloser.addSpaceAndSwitch(
                toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayID: displayID,
                displayGroupIndex: groupIndex
            ) { [weak self] success in
                guard success else {
                    self?.refreshAfterClose()
                    return
                }
                WorkspaceLauncher.launch(key)
                self?.refreshAfterClose()
            }
        }
    }

    @objc private func launchSite(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let name = info["name"],
              let path = info["path"]
        else { return }

        withFreshSpaces { [weak self] in
            guard let self, let displayID = self.activeDisplayID() else { return }
            let groupIndex = self.activeDisplayGroupIndex()

            SpaceCloser.addSpaceAndSwitch(
                toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayID: displayID,
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

        let closeAllItem = NSMenuItem(
            title: "Close All Spaces",
            action: !closeAllTargets.isEmpty ? #selector(closeAllSpaces) : nil,
            keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.control, .option, .shift, .command]
        closeAllItem.target = self
        submenu.addItem(closeAllItem)

        submenu.addItem(NSMenuItem.separator())

        let closeCurrentTitle: String
        if let currentDesktop {
            closeCurrentTitle = "Close Current Space (\(currentDesktop.spaceByDesktopID))"
        } else {
            closeCurrentTitle = "Close Current Space"
        }

        let closeCurrentItem = NSMenuItem(
            title: closeCurrentTitle,
            action: currentDesktop != nil && canCloseCurrentDesktop ? #selector(closeCurrentSpace) : nil,
            keyEquivalent: "w")
        closeCurrentItem.keyEquivalentModifierMask = [.control, .option, .command]
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
            keyEquivalent: "e")
        emptyItem.keyEquivalentModifierMask = [.control, .option, .command]
        emptyItem.target = self
        submenu.addItem(emptyItem)

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

        let createItem = NSMenuItem(
            title: "New Issue…",
            action: #selector(showCreateIssueWindowFromMenu),
            keyEquivalent: "i")
        createItem.keyEquivalentModifierMask = [.control, .option, .command]
        createItem.target = self
        menu.addItem(createItem)
        menu.addItem(NSMenuItem.separator())

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
            buildFlatIssuesList(recentMenu, issues: issues, sortByRecent: true)
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)

            let azItem = NSMenuItem(title: "A to Z", action: nil, keyEquivalent: "")
            let azMenu = NSMenu()
            buildFlatIssuesList(azMenu, issues: issues, sortByRecent: false)
            azItem.submenu = azMenu
            menu.addItem(azItem)

            let recentGroupedItem = NSMenuItem(
                title: "Recent, Grouped by Repo",
                action: nil,
                keyEquivalent: "")
            let recentGroupedMenu = NSMenu()
            buildGroupedIssuesList(recentGroupedMenu, issues: issues, sortByRecent: true)
            recentGroupedItem.submenu = recentGroupedMenu
            menu.addItem(recentGroupedItem)

            let azGroupedItem = NSMenuItem(
                title: "A to Z, Grouped by Repo",
                action: nil,
                keyEquivalent: "")
            let azGroupedMenu = NSMenu()
            buildGroupedIssuesList(azGroupedMenu, issues: issues, sortByRecent: false)
            azGroupedItem.submenu = azGroupedMenu
            menu.addItem(azGroupedItem)
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(
            title: "Refresh Issues",
            action: #selector(refreshIssues),
            keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
    }

    private func buildFlatIssuesList(
        _ menu: NSMenu,
        issues: [GitHubIssue],
        sortByRecent: Bool
    ) {
        let sorted = issues.sorted { first, second in
            if sortByRecent {
                if first.updatedAt != second.updatedAt { return first.updatedAt > second.updatedAt }
            } else {
                let comparison = first.title.localizedCaseInsensitiveCompare(second.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if first.repoFullName != second.repoFullName {
                return first.repoFullName.localizedCaseInsensitiveCompare(second.repoFullName)
                    == .orderedAscending
            }
            return first.number < second.number
        }

        for issue in sorted {
            addIssueMenuItem(issue, to: menu, includesRepository: true)
        }
    }

    private func buildGroupedIssuesList(
        _ menu: NSMenu,
        issues: [GitHubIssue],
        sortByRecent: Bool
    ) {
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
            addSectionHeader(
                repoName,
                to: menu,
                foregroundColor: RepositoryColor.color(for: repoName))

            guard let repoIssues = grouped[repoFullName] else { continue }
            let sorted = sortByRecent
                ? repoIssues.sorted { $0.updatedAt > $1.updatedAt }
                : repoIssues.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }

            for issue in sorted {
                addIssueMenuItem(issue, to: menu, includesRepository: false)
            }
        }
    }

    private func addIssueMenuItem(
        _ issue: GitHubIssue,
        to menu: NSMenu,
        includesRepository: Bool
    ) {
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
        if includesRepository {
            let repositoryAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 12),
                .foregroundColor: RepositoryColor.color(for: issue.repoName)
            ]
            attrTitle.append(NSAttributedString(
                string: "\(issue.repoName)  ",
                attributes: repositoryAttrs))
        }
        attrTitle.append(NSAttributedString(
            string: "#\(issue.number) ",
            attributes: numAttrs))

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

    @objc private func showCreateIssueWindowFromMenu() {
        showCreateIssueWindow()
    }

    func showCreateIssueWindow() {
        // LSUIElement apps use the accessory policy by default. Temporarily
        // becoming a regular app lets macOS treat this as a fully managed
        // document window, including system Move & Resize keyboard commands.
        NSApp.setActivationPolicy(.regular)

        if let createIssueWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            createIssueWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "New GitHub Issue"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenPrimary, .participatesInCycle]
        window.contentMinSize = NSSize(width: 420, height: 440)
        window.setFrameAutosaveName("CreateGitHubIssueWindow")
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.delegate = self
        window.center()
        createIssueHasPendingChanges = false
        allowCreateIssueClose = false
        createIssueCloseConfirmationVisible = false
        window.contentView = NSHostingView(rootView: CreateGitHubIssueView(
            onCancel: { [weak window] in
                window?.performClose(nil)
            },
            onCreated: { [weak window, weak self] issue, repository, createAnother in
                self?.sendIssueCreatedNotification(issue: issue, repository: repository)
                self?.issueFetcher.fetch()
                if !createAnother {
                    self?.createIssueHasPendingChanges = false
                    window?.performClose(nil)
                }
            },
            onPendingChangesChanged: { [weak self] hasPendingChanges in
                self?.createIssueHasPendingChanges = hasPendingChanges
            }))
        createIssueWindow = window
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
                guard let self, let displayID = self.activeDisplayID() else { return }
                let groupIndex = self.activeDisplayGroupIndex()
                let issueNum = number
                SpaceCloser.addSpaceAndSwitch(
                    toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                    displayID: displayID,
                    displayGroupIndex: groupIndex
                ) { [weak self] success in
                    guard success else {
                        self?.refreshAfterClose()
                        return
                    }
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
                guard let self, let displayID = self.activeDisplayID() else { return }
                let groupIndex = self.activeDisplayGroupIndex()
                SpaceCloser.addSpaceAndSwitch(
                    toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                    displayID: displayID,
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

    private func builtInDisplayID() -> String? {
        physicalDisplayOrder.first {
            CGDisplayIsBuiltin(DisplayGeometryUtilities.displayID(for: $0)) != 0
        }
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
            displayID: space.displayID,
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
            displayID: focusSpace.displayID,
            displayGroup: displayGroupIndex(for: focusSpace.displayID),
            desktopIndex: finalIndex + 1)
    }

    private func withFreshSpaces(_ action: @escaping () -> Void) {
        guard let requestSpaceRefresh else {
            action()
            return
        }

        requestSpaceRefresh { success in
            DispatchQueue.main.async {
                if success {
                    action()
                } else {
                    NSLog("StatusBarController: fresh Space snapshot was unavailable; action canceled")
                    NSSound.beep()
                }
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
                self.switchViaMissionControl(to: target)
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
                    self.switchViaMissionControl(to: target)
                }
        } else {
            switchViaMissionControl(to: target)
        }
    }

    private func switchViaMissionControl(to target: Space) {
        guard !target.isFullScreen,
              let desktopIndex = desktopIndexOnDisplay(for: target)
        else {
            showSwitchError()
            return
        }

        spaceSwitcher.switchViaMissionControl(
            displayID: target.displayID,
            displayGroupIndex: displayGroupIndex(for: target.displayID),
            desktopIndex: desktopIndex) {
                self.showSwitchError()
            }
    }

    private func showSwitchError() {
        let hasAcc = AppPermissions.check(.accessibility)
        var msg = "Space switching failed.\n\n"
        if !hasAcc { msg += "- Accessibility permission NOT granted\n" }
        if hasAcc { msg += "Accessibility permission appears granted. Try removing and re-adding Space Manager in System Settings > Privacy & Security > Accessibility, then restart the app." }

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

    @objc private func resetCurrentSpace() {
        guard let current = currentSpace() else { return }

        NotificationCenter.default.post(
            name: NSNotification.Name("RenameSpace"),
            object: nil,
            userInfo: ["spaceID": current.spaceID, "name": ""])

        do {
            let wallpaperURL = try WallpaperResetter.resetWallpaper(on: current.displayID)
            SpaceOperationLog.write(
                "Reset space=\(current.spaceID) display=\(current.displayID) wallpaper=\(wallpaperURL.path)")
        } catch {
            SpaceOperationLog.write(
                "Reset wallpaper failed space=\(current.spaceID) display=\(current.displayID) error=\(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn’t Reset Wallpaper"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
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
        let focusTarget = space.isCurrentSpace
            ? self.focusTarget(afterClosing: [space], preferredClosedSpace: space)
            : nil
        SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] success in
            if success { self?.removePersistedState(for: [space]) }
            self?.refreshAfterClose()
        }
    }

    @objc private func closeCurrentSpace() {
        closeCurrentSpaceFromShortcut()
    }

    func closeCurrentSpaceFromShortcut() {
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
        SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] success in
            if success { self?.removePersistedState(for: [current]) }
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

        guard let closeButtons = closeButtonsViaAccessibility(for: current.windows) else {
            NSLog("StatusBarController: could not resolve every window close button; Space close canceled")
            NSSound.beep()
            return
        }

        for closeButton in closeButtons {
            guard AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
                NSLog("StatusBarController: a window close action failed; Space close canceled")
                NSSound.beep()
                return
            }
        }

        waitForWindowsToClose(Set(current.windows.map(\.windowID))) { [weak self] windowsClosed in
            guard let self else { return }
            guard windowsClosed else {
                NSLog("StatusBarController: windows remained open after close requests; Space close canceled")
                NSSound.beep()
                self.refreshAfterClose()
                return
            }
            let focusTarget = self.focusTarget(afterClosing: [current], preferredClosedSpace: current)
            SpaceCloser.closeSpaces(targets: [target], focusTarget: focusTarget) { [weak self] success in
                if success { self?.removePersistedState(for: [current]) }
                self?.refreshAfterClose()
            }
        }
    }

    /// Resolves every close button before pressing any of them. This avoids partially
    /// closing a Space's windows when one app is not accessibility-controllable.
    private func closeButtonsViaAccessibility(for windows: [SpaceWindow]) -> [AXUIElement]? {
        var closeButtons: [AXUIElement] = []
        for window in windows {
            let appElement = AXUIElementCreateApplication(window.ownerPID)
            var axWindowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
                  let axWindows = axWindowsRef as? [AXUIElement]
            else { return nil }

            var matchedCloseButton: AXUIElement?
            for axWindow in axWindows {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                var pos = CGPoint.zero
                var size = CGSize.zero
                guard let p = posRef,
                      let s = sizeRef,
                      CFGetTypeID(p) == AXValueGetTypeID(),
                      CFGetTypeID(s) == AXValueGetTypeID(),
                      AXValueGetValue(p as! AXValue, .cgPoint, &pos),
                      AXValueGetValue(s as! AXValue, .cgSize, &size)
                else { continue }

                let axBounds = CGRect(origin: pos, size: size)
                guard abs(axBounds.origin.x - window.bounds.origin.x) < 2,
                      abs(axBounds.origin.y - window.bounds.origin.y) < 2,
                      abs(axBounds.width - window.bounds.width) < 2,
                      abs(axBounds.height - window.bounds.height) < 2
                else { continue }

                var closeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    axWindow, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
                   let closeRef,
                   CFGetTypeID(closeRef) == AXUIElementGetTypeID()
                {
                    matchedCloseButton = unsafeBitCast(closeRef, to: AXUIElement.self)
                }
                break
            }

            guard let matchedCloseButton else { return nil }
            closeButtons.append(matchedCloseButton)
        }
        return closeButtons
    }

    private func waitForWindowsToClose(
        _ windowIDs: Set<Int>,
        attempt: Int = 1,
        completion: @escaping (Bool) -> Void
    ) {
        guard !windowIDs.isEmpty else {
            completion(true)
            return
        }

        let remainingIDs: Set<Int>
        if let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            remainingIDs = Set(windowInfo.compactMap { $0[kCGWindowNumber as String] as? Int })
                .intersection(windowIDs)
        } else {
            remainingIDs = windowIDs
        }

        if remainingIDs.isEmpty {
            completion(true)
        } else if attempt >= 30 {
            completion(false)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForWindowsToClose(
                    windowIDs,
                    attempt: attempt + 1,
                    completion: completion)
            }
        }
    }

    @objc private func closeEmptySpaces() {
        closeEmptySpacesFromShortcut()
    }

    func closeEmptySpacesFromShortcut() {
        withFreshSpaces { [weak self] in
            self?.performCloseEmptySpaces()
        }
    }

    private func performCloseEmptySpaces() {
        let freshWindows = WindowDetector.detectWindowsPerSpace()
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        let targetSpaces = closeableEmptyTargetSpaces(from: desktopSpaces, windowsBySpaceID: freshWindows)

        let targets = targetSpaces.compactMap { closeTarget(for: $0) }
        guard !targets.isEmpty else {
            sendSpaceNotification(title: "No Empty Spaces to Close")
            return
        }

        let current = currentDesktopSpace()
        let focusTarget = current.flatMap { current in
            targetSpaces.contains(where: { $0.spaceID == current.spaceID })
                ? self.focusTarget(afterClosing: targetSpaces, preferredClosedSpace: current)
                : nil
        }

        SpaceCloser.closeSpaces(targets: targets, focusTarget: focusTarget) { [weak self] success in
            if success {
                self?.removePersistedState(for: targetSpaces)
                let noun = targets.count == 1 ? "Space" : "Spaces"
                self?.sendSpaceNotification(title: "Closed \(targets.count) Empty \(noun)")
            } else {
                self?.sendSpaceNotification(title: "Couldn’t Close Empty Spaces")
            }
            self?.refreshAfterClose()
        }
    }

    @objc private func closeAllSpaces() {
        closeAllSpacesFromShortcut()
    }

    func closeAllSpacesFromShortcut() {
        withFreshSpaces { [weak self] in
            self?.performCloseAllSpaces()
        }
    }

    private func performCloseAllSpaces() {
        let desktopSpaces = currentSpaces.filter { !$0.isFullScreen }
        let targetSpaces = closeAllTargetSpaces(from: desktopSpaces)

        let targets = targetSpaces.compactMap { closeTarget(for: $0) }
        guard !targets.isEmpty else { return }

        let current = currentDesktopSpace()
        let focusTarget = current.flatMap { current in
            targetSpaces.contains(where: { $0.spaceID == current.spaceID })
                ? self.focusTarget(afterClosing: targetSpaces, preferredClosedSpace: current)
                : nil
        }

        SpaceCloser.closeSpaces(targets: targets, focusTarget: focusTarget) { [weak self] success in
            if success { self?.removePersistedState(for: targetSpaces) }
            self?.refreshAfterClose()
        }
    }

    @objc private func addSpace() {
        withFreshSpaces { [weak self] in
            guard let self, let displayID = self.activeDisplayID() else { return }
            let groupIndex = self.activeDisplayGroupIndex()
            SpaceCloser.addSpaceAndSwitch(
                toDesktopNumber: self.nextDesktopNumberOnActiveDisplay(),
                displayID: displayID,
                displayGroupIndex: groupIndex
            ) { [weak self] _ in
                self?.refreshAfterClose()
            }
        }
    }

    @objc private func addTerminalSpace() {
        createTerminalSpace()
    }

    func createTerminalSpace() {
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

    @objc private func createSpacesForTerminalWindows() {
        organizeTerminalWindows()
    }

    func organizeTerminalWindows() {
        withFreshSpaces { [weak self] in
            self?.performCreateSpacesForTerminalWindows()
        }
    }

    private func performCreateSpacesForTerminalWindows() {
        // Prefer the MacBook's built-in panel even when the pointer and active
        // Space are on an external display. Preparing the desktops there means
        // they survive in the intended order when the external displays detach.
        guard let targetDisplayID = builtInDisplayID() ?? activeDisplayID() else { return }
        let terminalWindows = terminalWindowsForOrganization()
        guard !terminalWindows.isEmpty,
              let targetFrame = DisplayGeometryUtilities.accessibilityVisibleFrame(
                for: targetDisplayID)
        else { return }

        let existingSpaceIDs = Set(currentSpaces.map(\.spaceID))
        let groupIndex = displayGroupIndex(for: targetDisplayID)
        SpaceOperationLog.write(
            "Terminal organization started targetDisplay=\(targetDisplayID) windows=\(terminalWindows.count)")

        SpaceCloser.addSpaces(
            count: terminalWindows.count,
            displayID: targetDisplayID,
            displayGroupIndex: groupIndex
        ) { [weak self] addedCount in
            guard let self else { return }
            guard addedCount == terminalWindows.count else {
                SpaceOperationLog.write(
                    "Terminal organization canceled requested=\(terminalWindows.count) added=\(addedCount)")
                NSSound.beep()
                self.refreshAfterClose()
                return
            }

            self.requestSpaceRefresh? { [weak self] success in
                DispatchQueue.main.async {
                    guard let self, success else {
                        NSSound.beep()
                        return
                    }

                    let newSpaces = self.currentSpaces.filter {
                        $0.displayID == targetDisplayID
                            && !$0.isFullScreen
                            && !existingSpaceIDs.contains($0.spaceID)
                    }
                    guard newSpaces.count == terminalWindows.count else {
                        SpaceOperationLog.write(
                            "Terminal organization canceled expectedNewSpaces=\(terminalWindows.count) actual=\(newSpaces.count)")
                        NSSound.beep()
                        return
                    }

                    let assignments = zip(terminalWindows, newSpaces).map {
                        SpaceTransfer.ManagedSpaceAssignment(
                            window: $0.0,
                            targetSpaceID: $0.1.spaceID,
                            targetFrame: targetFrame)
                    }
                    MissionControlAccessibility.operationQueue.async { [weak self] in
                        let movedCount = SpaceTransfer.moveWindowsToManagedSpaces(assignments)
                        SpaceOperationLog.write(
                            "Terminal organization completed moved=\(movedCount)/\(assignments.count)")
                        DispatchQueue.main.async {
                            if movedCount != assignments.count { NSSound.beep() }
                            self?.refreshAfterClose()
                        }
                    }
                }
            }
        }
    }

    @objc private func fillTerminalWindows() {
        withFreshSpaces { [weak self] in
            self?.performFillTerminalWindows()
        }
    }

    private func performFillTerminalWindows() {
        guard let targetDisplayID = builtInDisplayID() ?? activeDisplayID(),
              let targetFrame = DisplayGeometryUtilities.accessibilityVisibleFrame(
                for: targetDisplayID)
        else { return }

        let assignments = currentSpaces.compactMap { space -> (
            window: SpaceWindow,
            displayID: String,
            displayGroup: Int,
            desktopIndex: Int
        )? in
            guard !space.isFullScreen,
                  let desktopIndex = desktopIndexOnDisplay(for: space),
                  let window = space.windows.first(where: SpaceNamer.isTerminalWindow)
            else { return nil }
            return (
                window,
                space.displayID,
                displayGroupIndex(for: space.displayID),
                desktopIndex)
        }
        guard !assignments.isEmpty else { return }

        MissionControlAccessibility.operationQueue.async { [weak self] in
            let filledCount = SpaceTransfer.fillWindowsOnSpaces(
                assignments,
                targetFrame: targetFrame)
            SpaceOperationLog.write(
                "Terminal window fill completed filled=\(filledCount)/\(assignments.count)")
            DispatchQueue.main.async {
                if filledCount != assignments.count { NSSound.beep() }
                self?.refreshAfterClose()
            }
        }
    }

    private func terminalWindowsForOrganization() -> [SpaceWindow] {
        let namer = SpaceNamer()
        var seenWindowIDs = Set<Int>()
        return currentSpaces
            .filter { !$0.isFullScreen }
            .flatMap { space -> [SpaceWindow] in
                let terminalWindows = space.windows.filter(SpaceNamer.isTerminalWindow)
                return terminalWindows.count > 1 ? terminalWindows : []
            }
            .filter { seenWindowIDs.insert($0.windowID).inserted }
            .sorted { lhs, rhs in
                let comparison = namer.terminalWindowSortName(lhs).localizedStandardCompare(
                    namer.terminalWindowSortName(rhs))
                return comparison == .orderedSame
                    ? lhs.windowID < rhs.windowID
                    : comparison == .orderedAscending
            }
    }

    @objc private func openDevTerminal() {
        let script = """
        tell application "Terminal"
            set devWindow to do script "cd ~/Sites/mac-space-manager"
            set frontmost of devWindow to true
            activate
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

    @objc private func openChromeProfile(_ sender: NSMenuItem) {
        guard let profileDirectory = sender.representedObject as? String else { return }
        ChromeProfileManager.openNewWindow(profileDirectory: profileDirectory)
    }

    private func updateChromeProfilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let profiles = ChromeProfileManager.profiles()
        guard !profiles.isEmpty else {
            let item = NSMenuItem(title: "No Chrome profiles found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for profile in profiles {
            let title = profile.name.isEmpty || profile.email.isEmpty
                ? profile.displayName
                : "\(profile.displayName) (\(profile.email))"
            let item = NSMenuItem(
                title: title,
                action: #selector(openChromeProfile(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = profile.directory
            menu.addItem(item)
        }
    }

    @objc private func showMissionControl() {
        MissionControlAccessibility.open()
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

    @objc func openWindowLayoutShortcutEditor() {
        openSettingsWindow(selectedTab: .windowLayouts)
    }

    @objc private func openWindowManagementPermissions() {
        openSettingsWindow(selectedTab: .permissions)
    }

    @objc private func openSettings() {
        openSettingsWindow(selectedTab: .general)
    }

    private func openSettingsWindow(selectedTab: SettingsTab) {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow, existing.isVisible {
            settingsWindowModel?.selection = selectedTab
            existing.makeKeyAndOrderFront(nil)
            return
        }

        do {
            let coordinator = try MagnetShortcutEditorCoordinator()
            let model = SettingsWindowModel(selection: selectedTab)
            let content = SpaceManagerSettingsView(
                model: model,
                commands: coordinator.editorCommands,
                onSave: { [weak coordinator] commands in
                    try coordinator?.save(commands)
                },
                onApply: { [weak coordinator] commands in
                    try await coordinator?.apply(commands)
                })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Space Manager Settings"
            window.contentView = NSHostingView(rootView: content)
            window.contentMinSize = NSSize(width: 920, height: 640)
            window.setFrameAutosaveName("SpaceManagerSettings")
            window.center()
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)

            windowLayoutShortcutCoordinator = coordinator
            settingsWindowModel = model
            settingsWindow = window
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Open Settings"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func refreshAfterClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
        }
    }

    private func removePersistedState(for spaces: [Space]) {
        let spaceIDs = Set(spaces.map(\.spaceID))
        SpaceNameStore.shared.remove(spaceIDs: spaceIDs)
        SpaceLabelStore.shared.removeSpaces(withIDs: spaceIDs)
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
            updatePerformanceMenuHeight()
            statusMenuIsOpen = true
            refreshPermissionsMenuItem()
            refreshAILimits()
            menuContextDisplayID = DisplayGeometryUtilities.displayUUID(
                containing: NSEvent.mouseLocation,
                candidates: physicalDisplayOrder)
            issueFetcher.refreshIfNeeded()
            startPerformanceMonitoring()
            refreshProcessHealth()
            requestSpaceRefresh? { _ in }
        }
    }

    private func refreshPermissionsMenuItem() {
        let hasMissingPermissions = !AppPermissions.missingWindowManagementPermissions.isEmpty
        permissionsMenuItem?.isHidden = !hasMissingPermissions
        permissionsMenuSeparator?.isHidden = !hasMissingPermissions
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusMenu {
            statusMenuIsOpen = false
            if let pendingProcessHealthSnapshot {
                performanceViewModel.processHealthSnapshot = pendingProcessHealthSnapshot
                self.pendingProcessHealthSnapshot = nil
                updatePerformanceMenuHeight()
            }
            stopPerformanceMonitoring()
            menuContextDisplayID = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === chromeProfilesMenu {
            updateChromeProfilesMenu(menu)
            return
        }

        if menu === issuesMenu {
            populateIssuesMenu(menu)
        }
    }
}

extension StatusBarController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let shouldOpenIssue = response.actionIdentifier == openCreatedIssueNotificationAction ||
            response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let urlString = response.notification.request.content.userInfo[
            createdIssueURLNotificationKey] as? String

        if shouldOpenIssue, let urlString, let url = URL(string: urlString) {
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}

extension StatusBarController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === createIssueWindow,
              createIssueHasPendingChanges,
              !allowCreateIssueClose
        else { return true }

        guard !createIssueCloseConfirmationVisible else { return false }
        createIssueCloseConfirmationVisible = true

        let alert = NSAlert()
        alert.messageText = "Discard Pending Changes?"
        alert.informativeText = "You have pending changes. Are you sure you want to close this window?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.createIssueCloseConfirmationVisible = false
            guard response == .alertFirstButtonReturn else { return }
            self.allowCreateIssueClose = true
            sender?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === createIssueWindow
        else { return }
        createIssueWindow = nil
        createIssueHasPendingChanges = false
        allowCreateIssueClose = false
        createIssueCloseConfirmationVisible = false
        DispatchQueue.main.async {
            let hasOtherManagedWindow = NSApp.windows.contains {
                $0 !== window && $0.isVisible && $0.canBecomeMain
            }
            if !hasOtherManagedWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
