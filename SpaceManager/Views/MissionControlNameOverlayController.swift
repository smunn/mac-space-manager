//
//  MissionControlNameOverlayController.swift
//  SpaceManager
//
//  Displays Space Manager's names over Mission Control's immutable Desktop N
//  labels. macOS does not expose a user-facing Space rename API, so these
//  noninteractive panels follow the undocumented Mission Control AX elements.
//

import Cocoa

@MainActor
final class MissionControlNameOverlayController {
    static let enabledDefaultsKey = "showNamesInMissionControl"

    private let pollInterval: TimeInterval = 0.12
    private var spaces: [Space] = []
    private var displayOrder: [String] = []
    private var panelsBySpaceID: [String: MissionControlNamePanel] = [:]
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    init() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePreferenceChange()
            }
        }
        handlePreferenceChange()
    }

    deinit {
        timer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func updateSpaces(_ spaces: [Space], missionControlDisplayOrder: [String]) {
        self.spaces = spaces
        displayOrder = missionControlDisplayOrder
        if isEnabled {
            refreshOverlays()
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    private func handlePreferenceChange() {
        if isEnabled {
            startPolling()
            refreshOverlays()
        } else {
            stopPolling()
            hideAllPanels()
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshOverlays()
            }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshOverlays() {
        guard isEnabled, !spaces.isEmpty else {
            hideAllPanels()
            return
        }

        // Poll only the native hierarchy for this OS. Falling back from WindowManager
        // to Dock on every inactive tick is expensive and cannot produce macOS 27
        // Mission Control elements anyway.
        let snapshots = MissionControlAccessibility.currentDisplaySnapshots(
            includeLegacyFallback: false)
        guard !snapshots.isEmpty else {
            hideAllPanels()
            return
        }

        var visibleSpaceIDs = Set<String>()

        for (snapshotIndex, snapshot) in snapshots.enumerated() {
            guard let displayID = resolvedDisplayID(
                for: snapshot,
                snapshotIndex: snapshotIndex)
            else { continue }

            let desktopSpaces = spaces.filter {
                $0.displayID == displayID && !$0.isFullScreen
            }

            let desktopFrames = snapshot.desktopButtons.map {
                MissionControlAccessibility.frame(of: $0).map(
                    Self.appKitFrame(fromAccessibilityFrame:))
            }
            let validHeights = desktopFrames.compactMap(\.self).map(\.height)
            let isExpanded = (validHeights.sorted().dropFirst(validHeights.count / 2).first ?? 0) >= 50

            for desktopIndex in snapshot.desktopButtons.indices {
                guard desktopSpaces.indices.contains(desktopIndex),
                      desktopFrames.indices.contains(desktopIndex),
                      let desktopFrame = desktopFrames[desktopIndex]
                else { continue }

                let space = desktopSpaces[desktopIndex]
                let name = space.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }

                let panel = panelsBySpaceID[space.spaceID] ?? makePanel(for: space.spaceID)
                let repositoryColor = SpaceDisplayName.repositoryName(for: space)
                    .map { RepositoryColor.color(for: $0) }
                panel.update(
                    name: name,
                    repositoryColor: repositoryColor,
                    desktopFrame: desktopFrame,
                    maximumWidth: Self.maximumLabelWidth(
                        at: desktopIndex,
                        frames: desktopFrames),
                    isExpanded: isExpanded)
                visibleSpaceIDs.insert(space.spaceID)
            }
        }

        for (spaceID, panel) in panelsBySpaceID where !visibleSpaceIDs.contains(spaceID) {
            panel.orderOut(nil)
        }
    }

    private func resolvedDisplayID(
        for snapshot: MissionControlAccessibility.DisplaySnapshot,
        snapshotIndex: Int
    ) -> String? {
        if let displayID = snapshot.displayID {
            return displayID
        }
        guard displayOrder.indices.contains(snapshotIndex) else { return nil }
        return displayOrder[snapshotIndex]
    }

    private func makePanel(for spaceID: String) -> MissionControlNamePanel {
        let panel = MissionControlNamePanel()
        panelsBySpaceID[spaceID] = panel
        return panel
    }

    private func hideAllPanels() {
        panelsBySpaceID.values.forEach { $0.orderOut(nil) }
    }

    static func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height)
    }

    private static func maximumLabelWidth(at index: Int, frames: [CGRect?]) -> CGFloat {
        guard frames.indices.contains(index), let frame = frames[index] else { return 72 }
        var centerDistances: [CGFloat] = []

        if index > 0, let previous = frames[index - 1] {
            centerDistances.append(frame.midX - previous.midX)
        }
        if frames.indices.contains(index + 1), let next = frames[index + 1] {
            centerDistances.append(next.midX - frame.midX)
        }

        let cellWidth = centerDistances.min().map { $0 - 8 } ?? frame.width
        return max(48, min(max(60, frame.width - 8), cellWidth))
    }
}

private final class MissionControlNamePanel: NSPanel {
    private let nameView = MissionControlNameView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        level = .screenSaver
        contentView = nameView
    }

    func update(
        name: String,
        repositoryColor: NSColor?,
        desktopFrame: CGRect,
        maximumWidth: CGFloat,
        isExpanded: Bool
    ) {
        let size = nameView.update(
            name: name,
            repositoryColor: repositoryColor,
            maximumWidth: maximumWidth)
        guard let screen = Self.screen(containing: desktopFrame) else {
            orderOut(nil)
            return
        }

        let desiredX = desktopFrame.midX - size.width / 2
        // Expanded Mission Control buttons describe the thumbnail only, with the
        // native Desktop N title immediately below it. Collapsed buttons describe
        // the title itself. Place our label after whichever native element is
        // represented rather than using a fixed screen offset.
        let nativeTitleAllowance: CGFloat = isExpanded ? 19 : 2
        let desiredY = desktopFrame.minY - size.height - nativeTitleAllowance
        let x = min(
            max(desiredX, screen.frame.minX + 6),
            screen.frame.maxX - size.width - 6)
        let y = min(
            max(desiredY, screen.frame.minY + 6),
            screen.frame.maxY - size.height - 6)

        setFrame(
            CGRect(origin: CGPoint(x: x, y: y), size: size),
            display: false)
        orderFrontRegardless()
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(rect).area < rhs.frame.intersection(rect).area
        }
    }
}

private final class MissionControlNameView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(name: String, repositoryColor: NSColor?, maximumWidth: CGFloat) -> CGSize {
        label.stringValue = name
        let backgroundColor = repositoryColor ?? NSColor.black.withAlphaComponent(0.68)
        layer?.backgroundColor = backgroundColor.cgColor
        label.textColor = repositoryColor.map {
            RepositoryColor.contrastingTextColor(for: $0)
        } ?? .white
        let intrinsicWidth = ceil(label.intrinsicContentSize.width) + 14
        return CGSize(width: min(maximumWidth, max(48, intrinsicWidth)), height: 19)
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
