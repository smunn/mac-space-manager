//
//  MagnetShortcutManager.swift
//  SpaceManager
//
//  Imports and updates Magnet's private preference schema. The schema is not a
//  supported Magnet API and may change without notice. To limit that risk, this
//  service preserves every unknown plist key and command JSON field, validates
//  the generated payload, creates a timestamped backup before every write, and
//  verifies the imported preference domain before Magnet is relaunched.
//

import AppKit
import Foundation

enum MagnetShortcutManagerError: LocalizedError {
    case preferencesNotFound(URL)
    case malformedPropertyList
    case missingCommandData(String)
    case malformedCommandData(String, Error)
    case duplicateShortcuts([MagnetShortcutConflict])
    case cannotSerializePropertyList
    case commandFailed(String, String)
    case verificationFailed
    case magnetApplicationNotFound

    var errorDescription: String? {
        switch self {
        case .preferencesNotFound(let url): return "Magnet preferences were not found at \(url.path)."
        case .malformedPropertyList: return "Magnet preferences are not a valid property list."
        case .missingCommandData(let key): return "Magnet preferences do not contain \(key)."
        case .malformedCommandData(let key, let error): return "Magnet's \(key) data could not be decoded: \(error.localizedDescription)"
        case .duplicateShortcuts(let conflicts): return "The draft contains \(conflicts.count) duplicate shortcut conflict(s)."
        case .cannotSerializePropertyList: return "The updated Magnet preferences could not be serialized."
        case .commandFailed(let command, let output): return "\(command) failed: \(output)"
        case .verificationFailed: return "Magnet preferences did not match the requested configuration after import."
        case .magnetApplicationNotFound: return "Magnet.app could not be found."
        }
    }
}

struct MagnetApplyResult: Sendable {
    let backupURL: URL
    let relaunchedMagnet: Bool
}

final class MagnetShortcutManager {
    static let shared = MagnetShortcutManager()

    static let magnetBundleIdentifier = "com.crowdcafe.windowmagnet"
    static let preferenceDomain = "com.crowdcafe.windowmagnet"

    let preferencesURL: URL
    let draftURL: URL
    let backupsDirectoryURL: URL

    private let fileManager: FileManager
    private let workspace: NSWorkspace

    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        preferencesURL = homeDirectory
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(Self.preferenceDomain).plist")

        let support = homeDirectory
            .appendingPathComponent("Library/Application Support/Space Manager", isDirectory: true)
        draftURL = support.appendingPathComponent("MagnetShortcuts.json")
        backupsDirectoryURL = support.appendingPathComponent("Magnet Backups", isDirectory: true)
    }

    func loadMagnetConfiguration() throws -> MagnetShortcutConfiguration {
        guard fileManager.fileExists(atPath: preferencesURL.path) else {
            throw MagnetShortcutManagerError.preferencesNotFound(preferencesURL)
        }
        let plistData = try Data(contentsOf: preferencesURL)
        return try decodeConfiguration(from: plistData)
    }

    func loadDraft() throws -> MagnetShortcutConfiguration? {
        guard fileManager.fileExists(atPath: draftURL.path) else { return nil }
        return try JSONDecoder().decode(MagnetShortcutConfiguration.self, from: Data(contentsOf: draftURL))
    }

    /// Returns the user's in-progress edits when present, otherwise imports the
    /// current Magnet domain. This is the normal editor-loading entry point.
    func loadDraftOrMagnetConfiguration() throws -> MagnetShortcutConfiguration {
        try loadDraft() ?? loadMagnetConfiguration()
    }

    @discardableResult
    func saveDraft(_ configuration: MagnetShortcutConfiguration) throws -> URL {
        try fileManager.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: draftURL, options: .atomic)
        return draftURL
    }

    func validate(_ configuration: MagnetShortcutConfiguration) -> [MagnetShortcutConflict] {
        MagnetOrientation.allCases.flatMap { orientation in
            let active = configuration.commands(for: orientation).compactMap { command -> (MagnetShortcut, MagnetCommand)? in
                guard command.isShortcutEnabled, let shortcut = command.shortcut else { return nil }
                return (shortcut, command)
            }
            return Dictionary(grouping: active, by: { $0.0 })
                .filter { $0.value.count > 1 }
                .map { shortcut, matches in
                    MagnetShortcutConflict(
                        orientation: orientation,
                        shortcut: shortcut,
                        commandIDs: matches.map(\.1.id),
                        commandNames: matches.map(\.1.name)
                    )
                }
        }
        .sorted {
            if $0.orientation != $1.orientation { return $0.orientation.rawValue < $1.orientation.rawValue }
            if $0.shortcut.carbonModifiers != $1.shortcut.carbonModifiers {
                return $0.shortcut.carbonModifiers < $1.shortcut.carbonModifiers
            }
            return $0.shortcut.carbonKeyCode < $1.shortcut.carbonKeyCode
        }
    }

    /// Applies an edited configuration in one operation: save the draft, quit
    /// Magnet, back up its live plist, import and verify the new domain, then
    /// relaunch Magnet. This method is synchronous and should be called off the
    /// main thread by UI code.
    @discardableResult
    func applyCurrentConfiguration(_ configuration: MagnetShortcutConfiguration) throws -> MagnetApplyResult {
        let conflicts = validate(configuration)
        guard conflicts.isEmpty else { throw MagnetShortcutManagerError.duplicateShortcuts(conflicts) }

        try saveDraft(configuration)
        let magnetURL = applicationURL()
        try quitMagnet()
        let backupURL = try backupCurrentPreferences()

        do {
            let updatedData = try makeUpdatedPropertyList(from: configuration)
            try importPreferences(updatedData)
            try verify(configuration)
            let relaunched = try relaunchMagnet(at: magnetURL)
            return MagnetApplyResult(backupURL: backupURL, relaunchedMagnet: relaunched)
        } catch {
            // Do not leave Magnet closed just because its private preference format
            // changed or the import failed. Restore the known-good domain before
            // reopening Magnet; the timestamped backup remains available as well.
            if let backupData = try? Data(contentsOf: backupURL) {
                try? importPreferences(backupData)
            }
            _ = try? relaunchMagnet(at: magnetURL)
            throw error
        }
    }

    /// Applies the persisted editor draft without requiring the caller to load it
    /// again. UI code may use this as its one-click Apply action after saveDraft.
    @discardableResult
    func applySavedDraft() throws -> MagnetApplyResult {
        guard let draft = try loadDraft() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: draftURL.path])
        }
        return try applyCurrentConfiguration(draft)
    }

    private func decodeConfiguration(from plistData: Data) throws -> MagnetShortcutConfiguration {
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
                as? [String: Any]
        else { throw MagnetShortcutManagerError.malformedPropertyList }

        return MagnetShortcutConfiguration(
            verticalCommands: try decodeCommands(key: "verticalCommands", plist: plist),
            horizontalCommands: try decodeCommands(key: "horizontalCommands", plist: plist),
            sourcePropertyList: plistData,
            importedAt: Date()
        )
    }

    private func decodeCommands(key: String, plist: [String: Any]) throws -> [MagnetCommand] {
        guard let data = plist[key] as? Data else { throw MagnetShortcutManagerError.missingCommandData(key) }
        do {
            let values = try JSONDecoder().decode([[String: MagnetJSONValue]].self, from: data)
            return values.map(MagnetCommand.init(rawObject:))
        } catch {
            throw MagnetShortcutManagerError.malformedCommandData(key, error)
        }
    }

    private func makeUpdatedPropertyList(from configuration: MagnetShortcutConfiguration) throws -> Data {
        let liveData = try? Data(contentsOf: preferencesURL)
        let baseData = liveData ?? configuration.sourcePropertyList
        guard var plist = try PropertyListSerialization.propertyList(from: baseData, options: [], format: nil)
                as? [String: Any]
        else { throw MagnetShortcutManagerError.malformedPropertyList }

        let encoder = JSONEncoder()
        plist["verticalCommands"] = try encoder.encode(configuration.verticalCommands.map(\.rawObject))
        plist["horizontalCommands"] = try encoder.encode(configuration.horizontalCommands.map(\.rawObject))
        guard PropertyListSerialization.propertyList(plist, isValidFor: .binary) else {
            throw MagnetShortcutManagerError.cannotSerializePropertyList
        }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    private func backupCurrentPreferences() throws -> URL {
        guard fileManager.fileExists(atPath: preferencesURL.path) else {
            throw MagnetShortcutManagerError.preferencesNotFound(preferencesURL)
        }
        try fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let destination = backupsDirectoryURL
            .appendingPathComponent("com.crowdcafe.windowmagnet_\(formatter.string(from: Date())).plist")
        try fileManager.copyItem(at: preferencesURL, to: destination)
        return destination
    }

    private func quitMagnet() throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.magnetBundleIdentifier)
        guard !applications.isEmpty else { return }

        applications.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if applications.allSatisfy({ $0.isTerminated }) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        applications.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        let forceDeadline = Date().addingTimeInterval(2)
        while Date() < forceDeadline {
            if applications.allSatisfy({ $0.isTerminated }) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func importPreferences(_ data: Data) throws {
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("magnet-preferences-\(UUID().uuidString).plist")
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let output = try run("/usr/bin/defaults", arguments: ["import", Self.preferenceDomain, temporaryURL.path])
        guard output.status == 0 else {
            throw MagnetShortcutManagerError.commandFailed("defaults import", output.stderr)
        }
    }

    private func verify(_ expected: MagnetShortcutConfiguration) throws {
        let export = try run("/usr/bin/defaults", arguments: ["export", Self.preferenceDomain, "-"])
        guard export.status == 0,
              let data = export.stdout.data(using: .utf8),
              let actual = try? decodeConfiguration(from: data),
              actual.verticalCommands == expected.verticalCommands,
              actual.horizontalCommands == expected.horizontalCommands
        else { throw MagnetShortcutManagerError.verificationFailed }
    }

    private func applicationURL() -> URL? {
        workspace.urlForApplication(withBundleIdentifier: Self.magnetBundleIdentifier)
            ?? ["/Applications/Magnet.app", "\(NSHomeDirectory())/Applications/Magnet.app"]
                .map(URL.init(fileURLWithPath:))
                .first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    @discardableResult
    private func relaunchMagnet(at url: URL?) throws -> Bool {
        guard let url else { throw MagnetShortcutManagerError.magnetApplicationNotFound }
        // `open` is intentionally used instead of waiting on NSWorkspace's async
        // completion handler, which can deadlock if a caller invokes Apply on the
        // main thread. `-g` launches Magnet without stealing focus.
        let result = try run("/usr/bin/open", arguments: ["-g", url.path])
        guard result.status == 0 else {
            throw MagnetShortcutManagerError.commandFailed("open Magnet.app", result.stderr)
        }
        return true
    }

    private func run(_ executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain stdout before waiting so a large `defaults export` cannot fill the
        // pipe buffer and leave the child process blocked indefinitely.
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
