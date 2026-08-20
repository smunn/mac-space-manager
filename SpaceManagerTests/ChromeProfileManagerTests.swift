import XCTest
@testable import Space_Manager

final class ChromeProfileManagerTests: XCTestCase {
    func testProfilesMergeNewChromeProfilesAndUseLiveNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("Local State")
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

        let profiles = ChromeProfileManager.profiles(localStateURL: localStateURL)

        XCTAssertEqual(profiles.first?.directory, "Default")
        XCTAssertEqual(profiles.first?.name, "Updated Personal")
        XCTAssertEqual(profiles.first?.email, "updated@example.com")
        XCTAssertTrue(profiles.contains(ChromeProfile(
            directory: "Profile 12",
            name: "New Profile",
            email: "new@example.com")))
    }

    func testProfilesAreEmptyWhenChromeStateAndMachineCacheAreUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("missing-local-state")
        let cacheURL = root.appendingPathComponent("missing-cache.json")

        let profiles = ChromeProfileManager.profiles(
            localStateURL: localStateURL,
            sharedCacheURL: cacheURL)

        XCTAssertTrue(profiles.isEmpty)
    }

    func testSharedCacheIsUsedWhenChromeStateIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("missing-local-state")
        let cacheURL = root.appendingPathComponent("chrome-profile-cache.json")

        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "profiles": [[
                "directory": "Profile 15",
                "name": "Cached Profile",
                "email": "cached@example.com"
            ]]
        ]).write(to: cacheURL)

        let profiles = ChromeProfileManager.profiles(
            localStateURL: localStateURL,
            sharedCacheURL: cacheURL)

        XCTAssertEqual(profiles.map(\.directory), ["Profile 15"])
    }

    func testSyncSharedProfileCacheWritesSanitizedProfileRegistry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let localStateURL = root.appendingPathComponent("Local State")
        let cacheURL = root.appendingPathComponent("state/chrome-profiles.json")
        let localState: [String: Any] = [
            "profile": [
                "info_cache": [
                    "Profile 15": [
                        "name": "VSA",
                        "user_name": "vsa@example.com"
                    ]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: localState).write(to: localStateURL)

        XCTAssertEqual(
            try ChromeProfileManager.syncSharedProfileCache(
                localStateURL: localStateURL,
                cacheURL: cacheURL),
            1)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
        let profiles = try XCTUnwrap(payload["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.first?["directory"] as? String, "Profile 15")
        XCTAssertEqual(profiles.first?["name"] as? String, "VSA")
        XCTAssertEqual(profiles.first?["email"] as? String, "vsa@example.com")
    }

    func testRepositoryOwnersRouteToExpectedChromeProfiles() {
        XCTAssertEqual(
            ChromeProfileManager.profileEmail(forRepository: "smunn/mac-space-manager"),
            "scott@scottmunn.com")
        XCTAssertEqual(
            ChromeProfileManager.profileEmail(forRepository: "ScottMakesTech/project"),
            "scottmakestech@gmail.com")
        XCTAssertNil(ChromeProfileManager.profileEmail(forRepository: "other/project"))
    }
}
