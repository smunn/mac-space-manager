import XCTest
@testable import Space_Manager

final class MagnetShortcutManagerTests: XCTestCase {
    func testLoadsConfigurationFromDefaultsDomainWithoutPhysicalPreferenceFile() throws {
        let domain = "com.smunn.SpaceManagerTests.\(UUID().uuidString)"
        let home = try makeTemporaryDirectory()
        let sourceURL = home.appendingPathComponent("source.plist")
        try makePreferenceData().write(to: sourceURL)
        try runDefaults(["import", domain, sourceURL.path])
        defer {
            try? runDefaults(["delete", domain])
            try? FileManager.default.removeItem(at: home)
        }

        let manager = MagnetShortcutManager(homeDirectory: home, preferenceDomain: domain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.preferencesURL.path))

        let configuration = try manager.loadMagnetConfiguration()

        XCTAssertEqual(configuration.verticalCommands.map(\.id), ["vertical-command"])
        XCTAssertEqual(configuration.horizontalCommands.map(\.id), ["horizontal-command"])
    }

    func testFallsBackToPhysicalPreferenceFileWhenDefaultsDomainIsMissing() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let domain = "com.smunn.SpaceManagerTests.\(UUID().uuidString)"
        let manager = MagnetShortcutManager(homeDirectory: home, preferenceDomain: domain)
        try FileManager.default.createDirectory(
            at: manager.preferencesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try makePreferenceData().write(to: manager.preferencesURL)

        let configuration = try manager.loadMagnetConfiguration()

        XCTAssertEqual(configuration.verticalCommands.map(\.id), ["vertical-command"])
        XCTAssertEqual(configuration.horizontalCommands.map(\.id), ["horizontal-command"])
    }

    @MainActor
    func testCoordinatorUsesStandardCommandsWithoutMagnetPreferences() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = MagnetShortcutManager(
            homeDirectory: home,
            preferenceDomain: "com.smunn.SpaceManagerTests.\(UUID().uuidString)")
        let store = WindowLayoutShortcutStore(homeDirectory: home, projectRoot: nil)

        let coordinator = try MagnetShortcutEditorCoordinator(manager: manager, shortcutStore: store)

        XCTAssertEqual(coordinator.editorCommands, MagnetShortcutCommand.standardSet)
        var edits = coordinator.editorCommands
        edits[0].isEnabled.toggle()
        try coordinator.save(edits)
        XCTAssertEqual(try store.load(), edits)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePreferenceData() throws -> Data {
        func commands(id: String, axis: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [[
                "id": id,
                "name": id,
                "axis": axis,
                "category": "custom"
            ]])
        }

        return try PropertyListSerialization.data(
            fromPropertyList: [
                "verticalCommands": commands(id: "vertical-command", axis: "vertical"),
                "horizontalCommands": commands(id: "horizontal-command", axis: "horizontal")
            ],
            format: .xml,
            options: 0)
    }

    private func runDefaults(_ arguments: [String]) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardError = stderr
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MagnetShortcutManagerTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "defaults failed"])
        }
    }
}
