//
//  MagnetShortcutEditorCoordinator.swift
//  Space Manager
//

import Foundation

@MainActor
final class MagnetShortcutEditorCoordinator {
    private let manager: MagnetShortcutManager
    private let adapter = MagnetShortcutEditorAdapter()
    private var configuration: MagnetShortcutConfiguration

    init(manager: MagnetShortcutManager = .shared) throws {
        self.manager = manager
        configuration = try manager.loadDraftOrMagnetConfiguration()
    }

    var editorCommands: [MagnetShortcutCommand] {
        adapter.editorCommands(from: configuration)
    }

    func save(_ edits: [MagnetShortcutCommand]) throws {
        let updated = try adapter.applying(edits, to: configuration)
        let conflicts = manager.validate(updated)
        guard conflicts.isEmpty else {
            throw MagnetShortcutManagerError.duplicateShortcuts(conflicts)
        }
        try manager.saveDraft(updated)
        configuration = updated
        NotificationCenter.default.post(name: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil)
    }

    func apply(_ edits: [MagnetShortcutCommand]) async throws {
        let updated = try adapter.applying(edits, to: configuration)
        let conflicts = manager.validate(updated)
        guard conflicts.isEmpty else {
            throw MagnetShortcutManagerError.duplicateShortcuts(conflicts)
        }
        try manager.saveDraft(updated)

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
        NotificationCenter.default.post(name: Notification.Name("WindowLayoutConfigurationDidChange"), object: nil)
    }
}
