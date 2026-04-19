//
//  SpaceObserver.swift
//  SpaceManager
//
//  Detects macOS Spaces via Core Graphics private APIs.
//  Adapted from Spaceman by Sasindu Jayasinghe & René Uittenbogaard (MIT License).
//

import Cocoa
import Foundation

enum SpaceNameMatchingStrategy {
    case positionOnly
    case idWithPositionFallback
    case idOnly
}

protocol SpaceObserverDelegate: AnyObject {
    func didUpdateSpaces(spaces: [Space])
}

class SpaceObserver {
    private let workspace = NSWorkspace.shared
    private let conn = _CGSDefaultConnection()
    private let nameStore = SpaceNameStore.shared
    private let workerQueue = DispatchQueue(label: "com.smunn.SpaceManager.SpaceObserver")

    private var _needsPositionRevalidation = true
    private var _lastKnownDisplayIDs: Set<String> = []
    private var _topologyChangeGracePeriod: Int = 0

    weak var delegate: SpaceObserverDelegate?

    init() {
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(updateSpaceInformation),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: workspace)
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func handleWake() {
        _needsPositionRevalidation = true
    }

    @objc private func handleScreenChange() {
        updateSpaceInformation()
    }

    @objc public func updateSpaceInformation() {
        let needsRevalidation = _needsPositionRevalidation
        _needsPositionRevalidation = false
        workerQueue.async { [weak self] in
            self?.performSpaceInformationUpdate(needsRevalidation: needsRevalidation)
        }
    }

    private func performSpaceInformationUpdate(needsRevalidation: Bool) {
        guard var displays = fetchDisplaySpaces() else { return }

        displays.sort { a, b in
            let c1 = DisplayGeometryUtilities.getDisplayCenter(display: a)
            let c2 = DisplayGeometryUtilities.getDisplayCenter(display: b)
            return c1.x < c2.x
        }

        let connectedDisplayIDs: Set<String> = Set(
            displays.compactMap { $0["Display Identifier"] as? String }
        )

        let topologyChanged = !_lastKnownDisplayIDs.isEmpty && connectedDisplayIDs != _lastKnownDisplayIDs
        _lastKnownDisplayIDs = connectedDisplayIDs

        if topologyChanged {
            _topologyChangeGracePeriod = 5
        }
        let inTopologyTransition = topologyChanged || _topologyChangeGracePeriod > 0
        if _topologyChangeGracePeriod > 0 {
            _topologyChangeGracePeriod -= 1
        }

        let spaceNumberMap = buildSpaceNumberMap(from: displays)
        let storedNames = nameStore.loadAll()
        let storedDisplayIDs: Set<String> = Set(storedNames.values.compactMap { $0.displayUUID })

        var updatedNames: [String: SpaceNameInfo] = [:]
        var activeSpaceID = -1
        var lastSpaceByDesktopNumber = 0
        var lastFullScreenNumber = 0
        var collectedSpaces: [Space] = []

        for d in displays {
            guard let currentSpaces = d["Current Space"] as? [String: Any],
                  let spaces = d["Spaces"] as? [[String: Any]],
                  let displayID = d["Display Identifier"] as? String
            else { continue }

            let strategy: SpaceNameMatchingStrategy
            if needsRevalidation && !inTopologyTransition {
                strategy = .positionOnly
            } else if inTopologyTransition || needsRevalidation || !storedDisplayIDs.contains(displayID) {
                strategy = .idWithPositionFallback
            } else {
                strategy = .idOnly
            }

            var positionOnThisDisplay = 0
            let currentSpaceID = currentSpaces["ManagedSpaceID"] as? Int ?? -1
            if currentSpaceID != -1 && activeSpaceID == -1 {
                activeSpaceID = currentSpaceID
            }

            for spaceDict in spaces {
                guard let managedInt = spaceDict["ManagedSpaceID"] as? Int else { continue }
                let managedSpaceID = String(managedInt)
                guard let spaceNumber = spaceNumberMap[managedSpaceID] else { continue }

                let isCurrentSpace = currentSpaceID == managedInt
                let isFullScreen = spaceDict["TileLayoutManager"] is [String: Any]

                positionOnThisDisplay += 1

                let spaceByDesktopID: String
                if isFullScreen {
                    lastFullScreenNumber += 1
                    spaceByDesktopID = "F\(lastFullScreenNumber)"
                } else {
                    lastSpaceByDesktopNumber += 1
                    spaceByDesktopID = String(lastSpaceByDesktopNumber)
                }

                let savedInfo = SpaceObserver.resolveSpaceNameInfo(
                    managedSpaceID: managedSpaceID,
                    displayID: displayID,
                    position: positionOnThisDisplay,
                    storedNames: storedNames,
                    strategy: strategy,
                    connectedDisplayIDs: strategy != .idOnly ? connectedDisplayIDs : nil)

                let savedName = savedInfo?.spaceName
                let resolvedName = resolveSpaceName(
                    from: savedName,
                    spaceByDesktopID: spaceByDesktopID,
                    isFullScreen: isFullScreen,
                    spaceDict: spaceDict)

                let space = Space(
                    displayID: displayID,
                    spaceID: managedSpaceID,
                    spaceName: resolvedName,
                    spaceNumber: spaceNumber,
                    spaceByDesktopID: spaceByDesktopID,
                    isCurrentSpace: isCurrentSpace,
                    isFullScreen: isFullScreen,
                    windows: [])

                var nameInfo = SpaceNameInfo(
                    spaceNum: spaceNumber,
                    spaceName: resolvedName,
                    spaceByDesktopID: spaceByDesktopID,
                    isUserOverride: savedInfo?.isUserOverride ?? false)
                nameInfo.displayUUID = displayID
                nameInfo.positionOnDisplay = positionOnThisDisplay

                updatedNames[managedSpaceID] = nameInfo
                collectedSpaces.append(space)
            }
        }

        let mergedNames = SpaceObserver.mergeSpaceNames(
            updatedNames: updatedNames,
            storedNames: storedNames,
            connectedDisplayIDs: connectedDisplayIDs)

        if mergedNames != storedNames {
            nameStore.save(mergedNames)
        }

        DispatchQueue.main.async {
            self.delegate?.didUpdateSpaces(spaces: collectedSpaces)
        }
    }

    private func fetchDisplaySpaces() -> [NSDictionary]? {
        guard let rawDisplays = CGSCopyManagedDisplaySpaces(conn)?.takeRetainedValue() as? [NSDictionary] else {
            return nil
        }
        return rawDisplays
    }

    private func buildSpaceNumberMap(from displays: [NSDictionary]) -> [String: Int] {
        var mapping: [String: Int] = [:]
        var index = 1
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let managedID = space["ManagedSpaceID"] as? Int else { continue }
                mapping[String(managedID)] = index
                index += 1
            }
        }
        return mapping
    }

    static func findSpaceByPosition(
        in storedNames: [String: SpaceNameInfo],
        displayID: String,
        position: Int,
        connectedDisplayIDs: Set<String>? = nil
    ) -> SpaceNameInfo? {
        if let match = storedNames.values.first(where: {
            $0.displayUUID == displayID && $0.positionOnDisplay == position
        }) {
            return match
        }
        guard let connectedIDs = connectedDisplayIDs else { return nil }
        return storedNames.values.first { info in
            guard let uuid = info.displayUUID else { return false }
            return !connectedIDs.contains(uuid) && info.positionOnDisplay == position
        }
    }

    static func resolveSpaceNameInfo(
        managedSpaceID: String,
        displayID: String,
        position: Int,
        storedNames: [String: SpaceNameInfo],
        strategy: SpaceNameMatchingStrategy = .positionOnly,
        connectedDisplayIDs: Set<String>? = nil
    ) -> SpaceNameInfo? {
        switch strategy {
        case .positionOnly:
            return findSpaceByPosition(
                in: storedNames, displayID: displayID,
                position: position,
                connectedDisplayIDs: connectedDisplayIDs)
        case .idWithPositionFallback:
            if let idMatch = storedNames[managedSpaceID] {
                return idMatch
            }
            return findSpaceByPosition(
                in: storedNames, displayID: displayID,
                position: position,
                connectedDisplayIDs: connectedDisplayIDs)
        case .idOnly:
            return storedNames[managedSpaceID]
        }
    }

    static func mergeSpaceNames(
        updatedNames: [String: SpaceNameInfo],
        storedNames: [String: SpaceNameInfo],
        connectedDisplayIDs: Set<String>
    ) -> [String: SpaceNameInfo] {
        let updatedPositions: Set<String> = Set(updatedNames.values.compactMap { info in
            guard let uuid = info.displayUUID, let pos = info.positionOnDisplay else { return nil }
            return "\(uuid):\(pos)"
        })

        var merged = updatedNames
        for (key, info) in storedNames {
            guard merged[key] == nil else { continue }
            guard let uuid = info.displayUUID else { continue }

            if !connectedDisplayIDs.contains(uuid) {
                merged[key] = info
            } else if info.hasUserData {
                let posKey = "\(uuid):\(info.positionOnDisplay ?? -1)"
                if !updatedPositions.contains(posKey) {
                    merged[key] = info
                }
            }
        }
        return merged
    }

    private func resolveSpaceName(
        from savedName: String?,
        spaceByDesktopID: String,
        isFullScreen: Bool,
        spaceDict: [String: Any]
    ) -> String {
        if let savedName, !savedName.isEmpty {
            return savedName
        }
        if isFullScreen {
            if let pid = spaceDict["pid"] as? pid_t,
               let app = NSRunningApplication(processIdentifier: pid),
               let name = app.localizedName {
                return name
            }
            return "Fullscreen"
        }
        return "Space \(spaceByDesktopID)"
    }
}
