//
//  MagnetShortcutEditorCoordinator.swift
//  Space Manager
//

import Foundation

@MainActor
final class MagnetShortcutEditorCoordinator {
    private let manager: MagnetShortcutManager
    private let shortcutStore: WindowLayoutShortcutStore
    private let adapter = MagnetShortcutEditorAdapter()
    private var configuration: MagnetShortcutConfiguration
    private var edits: [MagnetShortcutCommand]

    init(
        manager: MagnetShortcutManager = .shared,
        shortcutStore: WindowLayoutShortcutStore = .shared
    ) throws {
        self.manager = manager
        self.shortcutStore = shortcutStore
        configuration = try manager.loadDraftOrMagnetConfiguration()
        edits = try shortcutStore.load() ?? adapter.editorCommands(from: configuration)
        try shortcutStore.save(edits)
    }

    var editorCommands: [MagnetShortcutCommand] {
        edits
    }

    func save(_ edits: [MagnetShortcutCommand]) throws {
        let updated = try adapter.applying(edits, to: configuration)
        let conflicts = manager.validate(updated)
        guard conflicts.isEmpty else {
            throw MagnetShortcutManagerError.duplicateShortcuts(conflicts)
        }
        try manager.saveDraft(updated)
        try shortcutStore.save(edits)
        configuration = updated
        self.edits = edits
        NotificationCenter.default.post(name: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil)
    }

    func apply(_ edits: [MagnetShortcutCommand]) async throws {
        let updated = try adapter.applying(edits, to: configuration)
        let conflicts = manager.validate(updated)
        guard conflicts.isEmpty else {
            throw MagnetShortcutManagerError.duplicateShortcuts(conflicts)
        }
        try manager.saveDraft(updated)
        try shortcutStore.save(edits)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try MagnetShortcutManager.shared.applyCurrentConfiguration(updated)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        configuration = updated
        self.edits = edits
        NotificationCenter.default.post(name: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil)
    }
}
