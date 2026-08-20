//
//  UsageTelemetry.swift
//  SpaceManager
//

import AppKit
import Foundation

protocol UsageTelemetryStoring {
    func append(_ event: UsageTelemetryEvent) throws
    func loadEvents() throws -> [UsageTelemetryEvent]
}

/// Append-only local storage. A malformed line does not make the rest of the history unreadable.
final class JSONLinesUsageTelemetryStore: UsageTelemetryStoring {
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Space Manager/Telemetry/events.jsonl")

    let fileURL: URL

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.smunn.SpaceManager.usageTelemetryStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = defaultFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func append(_ event: UsageTelemetryEvent) throws {
        try queue.sync {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            var data = try encoder.encode(event)
            data.append(0x0A)

            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }

    func loadEvents() throws -> [UsageTelemetryEvent] {
        try queue.sync {
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            let data = try Data(contentsOf: fileURL)
            return data.split(separator: 0x0A).compactMap { line in
                try? decoder.decode(UsageTelemetryEvent.self, from: Data(line))
            }
        }
    }
}

/// Records only local, product-interaction events. It deliberately captures no window titles,
/// repository names, issue text, URLs, process arguments, or other user content.
final class UsageTelemetryRecorder: @unchecked Sendable {
    static let shared = UsageTelemetryRecorder(store: JSONLinesUsageTelemetryStore())

    private struct OpenMenu {
        let sessionID: UUID
        let openedAt: Date
    }

    private let store: UsageTelemetryStoring
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let lock = NSLock()
    private var openMenus: [TelemetryIdentifier: OpenMenu] = [:]

    init(
        store: UsageTelemetryStoring,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.store = store
        self.now = now
        self.makeUUID = makeUUID
    }

    func menuOpened(_ identifier: TelemetryIdentifier) {
        let timestamp = now()
        let sessionID = makeUUID()

        lock.lock()
        let wasAlreadyOpen = openMenus[identifier] != nil
        if !wasAlreadyOpen {
            openMenus[identifier] = OpenMenu(sessionID: sessionID, openedAt: timestamp)
        }
        lock.unlock()

        guard !wasAlreadyOpen else { return }
        append(UsageTelemetryEvent(
            id: makeUUID(),
            timestamp: timestamp,
            kind: .menuOpened,
            identifier: identifier,
            sessionID: sessionID))
    }

    func menuClosed(_ identifier: TelemetryIdentifier) {
        let timestamp = now()

        lock.lock()
        let openMenu = openMenus.removeValue(forKey: identifier)
        lock.unlock()

        guard let openMenu else { return }
        append(UsageTelemetryEvent(
            id: makeUUID(),
            timestamp: timestamp,
            kind: .menuClosed,
            identifier: identifier,
            sessionID: openMenu.sessionID,
            durationSeconds: max(0, timestamp.timeIntervalSince(openMenu.openedAt))))
    }

    func closeAllOpenMenus() {
        let timestamp = now()

        lock.lock()
        let menus = openMenus
        openMenus.removeAll()
        lock.unlock()

        for (identifier, openMenu) in menus {
            append(UsageTelemetryEvent(
                id: makeUUID(),
                timestamp: timestamp,
                kind: .menuClosed,
                identifier: identifier,
                sessionID: openMenu.sessionID,
                durationSeconds: max(0, timestamp.timeIntervalSince(openMenu.openedAt))))
        }
    }

    func actionSelected(
        _ identifier: TelemetryIdentifier,
        in parentIdentifier: TelemetryIdentifier? = nil
    ) {
        lock.lock()
        let sessionID = parentIdentifier.flatMap { openMenus[$0]?.sessionID }
        lock.unlock()

        append(UsageTelemetryEvent(
            id: makeUUID(),
            timestamp: now(),
            kind: .actionSelected,
            identifier: identifier,
            parentIdentifier: parentIdentifier,
            sessionID: sessionID))
    }

    private func append(_ event: UsageTelemetryEvent) {
        // Telemetry must never prevent the requested menu action from running.
        try? store.append(event)
    }
}

/// Observes registered menus without replacing their delegates. AppKit's begin/end tracking
/// notifications identify only the root menu, so forward `NSMenuDelegate` callbacks via
/// `menuWillOpen` and `menuDidClose` to measure individual submenus.
@MainActor
final class MenuTelemetryObserver {
    private let recorder: UsageTelemetryRecorder
    private let notificationCenter: NotificationCenter
    private var registrations: [ObjectIdentifier: TelemetryIdentifier] = [:]
    private var notificationTokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    init(
        recorder: UsageTelemetryRecorder = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.recorder = recorder
        self.notificationCenter = notificationCenter
    }

    func register(menu: NSMenu, identifier: TelemetryIdentifier) {
        unregister(menu: menu)
        let key = ObjectIdentifier(menu)
        registrations[key] = identifier

        let opened = notificationCenter.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak recorder] _ in
            recorder?.menuOpened(identifier)
        }
        let closed = notificationCenter.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak recorder] _ in
            // AppKit posts this for the root tracking menu, not each open submenu.
            // End every tracked submenu session so its dwell time is never left open.
            recorder?.closeAllOpenMenus()
        }
        let action = notificationCenter.addObserver(
            forName: NSMenu.didSendActionNotification,
            object: menu,
            queue: .main
        ) { [weak recorder] notification in
            guard let menuItem = notification.userInfo?["MenuItem"] as? NSMenuItem,
                  let action = menuItem.action,
                  let actionIdentifier = Self.actionIdentifier(for: action)
            else { return }
            recorder?.actionSelected(actionIdentifier, in: identifier)
        }
        notificationTokens[key] = [opened, closed, action]
    }

    func unregister(menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        if let identifier = registrations.removeValue(forKey: key) {
            recorder.menuClosed(identifier)
        }
        notificationTokens.removeValue(forKey: key)?.forEach {
            notificationCenter.removeObserver($0)
        }
    }

    func unregisterAll() {
        recorder.closeAllOpenMenus()
        notificationTokens.values.joined().forEach(notificationCenter.removeObserver)
        notificationTokens.removeAll()
        registrations.removeAll()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let identifier = registrations[ObjectIdentifier(menu)] else { return }
        recorder.menuOpened(identifier)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let identifier = registrations[ObjectIdentifier(menu)] else { return }
        recorder.menuClosed(identifier)
    }

    nonisolated static func actionIdentifier(for selector: Selector) -> TelemetryIdentifier? {
        let selectorName = NSStringFromSelector(selector)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .replacingOccurrences(of: ":", with: ".")
        guard !selectorName.isEmpty else { return nil }
        return TelemetryIdentifier(rawValue: "action.\(selectorName)")
    }

    deinit {
        notificationTokens.values.joined().forEach(notificationCenter.removeObserver)
    }
}
