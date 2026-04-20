//
//  AppDelegate.swift
//  SpaceManager
//
//  Orchestrates space detection, window mapping, and the menu bar UI.
//  Heavy work (terminal CWD resolution) runs on a background queue;
//  the UI updates immediately with cached data then refines when ready.
//

import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spaceObserver: SpaceObserver!
    private var windowDetector: WindowDetector!
    private var spaceNamer: SpaceNamer!
    private var statusBarController: StatusBarController!

    private var currentSpaces: [Space] = []
    private var pendingCommandURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowDetector = WindowDetector()
        spaceNamer = SpaceNamer()
        statusBarController = StatusBarController()

        spaceObserver = SpaceObserver()
        spaceObserver.delegate = self
        spaceObserver.updateSpaceInformation()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRefreshRequest),
            name: NSNotification.Name("RequestSpaceRefresh"),
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRenameSpace(_:)),
            name: NSNotification.Name("RenameSpace"),
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTransferSpace(_:)),
            name: NSNotification.Name("TransferSpace"),
            object: nil)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleRefreshRequest() {
        spaceObserver.updateSpaceInformation()
    }

    @objc private func handleRenameSpace(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let spaceID = userInfo["spaceID"] as? String,
              let name = userInfo["name"] as? String
        else { return }

        setSpaceName(spaceID: spaceID, name: name)
    }

    @objc private func handleTransferSpace(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sourceSpaceID = userInfo["sourceSpaceID"] as? String,
              let sourceDisplayID = userInfo["sourceDisplayID"] as? String,
              let targetDisplayID = userInfo["targetDisplayID"] as? String
        else { return }

        let windows = windowDetector.windows(for: sourceSpaceID)

        let moved = windows.isEmpty ? 0 : SpaceTransfer.transferWindows(
            windows, fromDisplay: sourceDisplayID, toDisplay: targetDisplayID)

        let wallpaperOK = SpaceTransfer.transferWallpaper(
            fromDisplay: sourceDisplayID, toDisplay: targetDisplayID)

        // Transfer user-overridden name to the target display's current space
        let stored = SpaceNameStore.shared.loadAll()
        if stored[sourceSpaceID]?.isUserOverride == true {
            if let targetSpace = currentSpaces.first(where: {
                $0.displayID == targetDisplayID && $0.isCurrentSpace
            }) {
                setSpaceName(spaceID: targetSpace.spaceID, name: stored[sourceSpaceID]!.spaceName)
                setSpaceName(spaceID: sourceSpaceID, name: "")
            }
        }

        NSLog("SpaceTransfer: moved \(moved)/\(windows.count) windows, wallpaper: \(wallpaperOK)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.spaceObserver.updateSpaceInformation()
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }

        handleCommandURLWhenReady(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleCommandURLWhenReady(url)
        }
    }

    private func handleCommandURLWhenReady(_ url: URL) {
        guard url.scheme?.lowercased() == "spacemanager" else { return }

        if currentSpaces.isEmpty {
            pendingCommandURLs.append(url)
            spaceObserver.updateSpaceInformation()
            return
        }

        handleCommandURL(url)
    }

    private func handleCommandURL(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()

        switch (host, path) {
        case ("rename-current", _), ("space", "/current/rename"):
            guard let name = queryValue("name", in: url) ?? queryValue("title", in: url) else {
                NSLog("SpaceManager API: rename-current missing name query parameter")
                return
            }
            renameCurrentSpace(to: name)

        case ("clear-current-name", _), ("space", "/current/clear-name"):
            renameCurrentSpace(to: "")

        case ("refresh", _):
            spaceObserver.updateSpaceInformation()

        case ("settings", _):
            showSettingsWindow()

        default:
            NSLog("SpaceManager API: unsupported command URL \(url.absoluteString)")
        }
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func renameCurrentSpace(to name: String) {
        guard let current = currentSpaces.first(where: { $0.isCurrentSpace }) else {
            NSLog("SpaceManager API: no current space available")
            return
        }

        setSpaceName(spaceID: current.spaceID, name: name)
    }

    private func setSpaceName(spaceID: String, name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameStore = SpaceNameStore.shared

        if name.isEmpty {
            nameStore.update { names in
                if let info = names[spaceID] {
                    names[spaceID] = info.withName("", isOverride: false)
                }
            }
        } else {
            nameStore.update { names in
                if let info = names[spaceID] {
                    names[spaceID] = info.withName(name, isOverride: true)
                } else {
                    let space = currentSpaces.first(where: { $0.spaceID == spaceID })
                    let newInfo = SpaceNameInfo(
                        spaceNum: space?.spaceNumber ?? 0,
                        spaceName: name,
                        spaceByDesktopID: space?.spaceByDesktopID ?? "",
                        isUserOverride: true)
                    names[spaceID] = newInfo
                }
            }
        }

        spaceObserver.updateSpaceInformation()
    }

    private func showSettingsWindow() {
        statusBarController.showSettings()
    }

    private func processPendingCommandURLs() {
        guard !pendingCommandURLs.isEmpty else { return }
        let urls = pendingCommandURLs
        pendingCommandURLs.removeAll()

        for url in urls {
            handleCommandURL(url)
        }
    }

    private func enrichAndDisplay(_ spaces: [Space]) {
        var enriched = spaces
        let storedNames = SpaceNameStore.shared.loadAll()

        for i in enriched.indices {
            let spaceID = enriched[i].spaceID
            let windows = windowDetector.windows(for: spaceID)
            enriched[i].windows = windows

            let storedInfo = storedNames[spaceID]
            if let storedInfo, storedInfo.isUserOverride, !storedInfo.spaceName.isEmpty {
                enriched[i].spaceName = storedInfo.spaceName
            } else if !windows.isEmpty {
                enriched[i].spaceName = spaceNamer.generateName(
                    for: windows, spaceNumber: enriched[i].spaceNumber)
            }
        }

        currentSpaces = enriched
        statusBarController.updateSpaces(enriched)
        processPendingCommandURLs()
    }
}

extension AppDelegate: SpaceObserverDelegate {
    func didUpdateSpaces(spaces: [Space]) {
        windowDetector.snapshotAllSpaces()

        enrichAndDisplay(spaces)

        // Resolve terminal CWDs in background, then refresh names
        let terminalPIDs = collectTerminalPIDs(from: spaces)
        guard !terminalPIDs.isEmpty else { return }

        ProcessHelper.shared.resolveTerminalCWDs(pids: terminalPIDs) { [weak self] in
            guard let self else { return }
            self.enrichAndDisplay(spaces)
        }
    }

    private func collectTerminalPIDs(from spaces: [Space]) -> [pid_t] {
        let terminals: Set<String> = ["Terminal", "iTerm2", "Alacritty", "kitty", "Warp", "Ghostty"]
        guard let currentSpace = spaces.first(where: { $0.isCurrentSpace }) else { return [] }
        let windows = windowDetector.windows(for: currentSpace.spaceID)
        var pids: [pid_t] = []
        var seen = Set<pid_t>()
        for window in windows {
            if terminals.contains(window.ownerName) && seen.insert(window.ownerPID).inserted {
                pids.append(window.ownerPID)
            }
        }
        return pids
    }
}
