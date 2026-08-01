import XCTest
@testable import Space_Manager

final class ChromeProfileManagerTests: XCTestCase {
    func testProfilesMergeNewChromeProfilesAndUseLiveNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("Local State")
        let configurationURL = root.appendingPathComponent("missing.json")
        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Default": [
                        "name": "Updated Personal",
                        "user_name": "updated@example.com"
                    ],
                    "Profile 12": [
                        "name": "New Profile",
                        "user_name": "new@example.com"
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: localStateURL)

        let profiles = ChromeProfileManager.profiles(
            localStateURL: localStateURL,
            sharedConfigurationURL: configurationURL)

        XCTAssertEqual(profiles.first?.directory, "Default")
        XCTAssertEqual(profiles.first?.name, "Updated Personal")
        XCTAssertEqual(profiles.first?.email, "updated@example.com")
        XCTAssertTrue(profiles.contains(ChromeProfile(
            directory: "Profile 12",
            name: "New Profile",
            email: "new@example.com")))
    }

    func testProfilesMergeSharedConfigurationWhenChromeStateIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("missing-local-state")
        let configurationURL = root.appendingPathComponent("chrome-profiles.json")
        let configuration: [[String: String]] = [[
            "directory": "Profile 14",
            "name": "Future Profile",
            "email": "future@example.com"
        ]]
        try JSONSerialization.data(withJSONObject: configuration).write(to: configurationURL)

        let profiles = ChromeProfileManager.profiles(
            localStateURL: localStateURL,
            sharedConfigurationURL: configurationURL)

        XCTAssertTrue(profiles.contains(ChromeProfile(
            directory: "Profile 14",
            name: "Future Profile",
            email: "future@example.com")))
    }
}
