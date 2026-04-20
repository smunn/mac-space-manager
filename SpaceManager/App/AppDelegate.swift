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
    }

    @objc private func handleRefreshRequest() {
        spaceObserver.updateSpaceInformation()
    }

    @objc private func handleRenameSpace(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let spaceID = userInfo["spaceID"] as? String,
              let name = userInfo["name"] as? String
        else { return }

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
                    let newInfo = SpaceNameInfo(
                        spaceNum: 0, spaceName: name, spaceByDesktopID: "",
                        isUserOverride: true)
                    names[spaceID] = newInfo
                }
            }
        }

        spaceObserver.updateSpaceInformation()
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
