//
//  WindowLayoutShortcutStore.swift
//  Space Manager
//
//  Persists the editor's portable shortcut model separately from Magnet's
//  private preference payload. The Application Support copy is available to
//  every installed build. When the source checkout is present, the same JSON
//  is mirrored into the repository so changes can be reviewed and versioned.
//

import Foundation

final class WindowLayoutShortcutStore {
    static let shared = WindowLayoutShortcutStore()

    let applicationSupportURL: URL
    let projectURL: URL?

    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        projectRoot: URL? = WindowLayoutShortcutStore.detectProjectRoot()
    ) {
        self.fileManager = fileManager
        applicationSupportURL = homeDirectory
            .appendingPathComponent("Library/Application Support/Space Manager", isDirectory: true)
            .appendingPathComponent("WindowLayoutShortcuts.json")
        projectURL = projectRoot?
            .appendingPathComponent("Configuration", isDirectory: true)
            .appendingPathComponent("WindowLayoutShortcuts.json")
    }

    func load() throws -> [MagnetShortcutCommand]? {
        for url in [projectURL, applicationSupportURL].compactMap({ $0 })
        where fileManager.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(
                [MagnetShortcutCommand].self,
                from: Data(contentsOf: url))
        }
        return nil
    }

    func save(_ commands: [MagnetShortcutCommand]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(commands)

        for url in [applicationSupportURL, projectURL].compactMap({ $0 }) {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private static func detectProjectRoot() -> URL? {
        let fileManager = FileManager.default
        if let path = ProcessInfo.processInfo.environment["SPACE_MANAGER_PROJECT_ROOT"],
           !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
        }

        let candidate = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Sites/mac-space-manager", isDirectory: true)
        return fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path)
            ? candidate
            : nil
    }
}
