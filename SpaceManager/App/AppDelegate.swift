//
//  AppDelegate.swift
//  SpaceManager
//
//  Orchestrates space detection, window mapping, and the menu bar UI.
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

        NSApp.activate(ignoringOtherApps: false)
    }

    @objc private func handleRefreshRequest() {
        spaceObserver.updateSpaceInformation()
    }
}

extension AppDelegate: SpaceObserverDelegate {
    func didUpdateSpaces(spaces: [Space]) {
        var enrichedSpaces = spaces

        if let currentSpace = spaces.first(where: { $0.isCurrentSpace }) {
            windowDetector.snapshotCurrentSpace(spaceID: currentSpace.spaceID)
        }

        let nameStore = SpaceNameStore.shared
        let storedNames = nameStore.loadAll()

        for i in enrichedSpaces.indices {
            let spaceID = enrichedSpaces[i].spaceID
            let windows = windowDetector.windows(for: spaceID)
            enrichedSpaces[i].windows = windows

            let storedInfo = storedNames[spaceID]
            if let storedInfo, storedInfo.isUserOverride {
                enrichedSpaces[i].spaceName = storedInfo.spaceName
            } else if !windows.isEmpty {
                let autoName = spaceNamer.generateName(
                    for: windows,
                    spaceNumber: enrichedSpaces[i].spaceNumber)
                enrichedSpaces[i].spaceName = autoName
            }
        }

        currentSpaces = enrichedSpaces
        statusBarController.updateSpaces(enrichedSpaces)
    }
}
