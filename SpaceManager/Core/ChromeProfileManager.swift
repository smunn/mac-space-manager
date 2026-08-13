//
//  ChromeProfileManager.swift
//  SpaceManager
//
//  Discovers Chrome profiles and always launches a new window so selecting a
//  profile cannot reuse a tab in a Chrome window on another macOS Space.
//

import Foundation

struct ChromeProfile: Equatable {
    let directory: String
    let name: String
    let email: String

    var displayName: String {
        if !name.isEmpty { return name }
        if !email.isEmpty { return email }
        return directory
    }
}

enum ChromeProfileManager {
    private static let chromeApplicationName = "Google Chrome"

    static var defaultLocalStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    static var sharedProfileCacheURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("com.smunn.SpaceManager", isDirectory: true)
            .appendingPathComponent("chrome-profiles.json")
    }

    private static var legacyProfileCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/chrome-profiles.json")
    }

    static func profiles(
        localStateURL: URL = defaultLocalStateURL,
        sharedCacheURL: URL = sharedProfileCacheURL
    ) -> [ChromeProfile] {
        // Chrome's live registry is authoritative. The generated shared cache is
        // machine-local and is used when privacy controls block direct Local
        // State access. No profile mapping is shared between Macs.
        let detectedProfiles: [ChromeProfile]
        if let liveProfiles = try? profilesFromLocalState(at: localStateURL) {
            detectedProfiles = liveProfiles
        } else if let cachedProfiles = try? profilesFromSharedCache(at: sharedCacheURL) {
            detectedProfiles = cachedProfiles
        } else if sharedCacheURL == sharedProfileCacheURL,
                  let legacyProfiles = try? profilesFromSharedCache(at: legacyProfileCacheURL) {
            detectedProfiles = legacyProfiles
        } else {
            detectedProfiles = []
        }

        let profilesByDirectory = Dictionary(
            uniqueKeysWithValues: detectedProfiles.map { ($0.directory, $0) })

        return profilesByDirectory.values.sorted { lhs, rhs in
            profileSortKey(lhs.directory) < profileSortKey(rhs.directory)
        }
    }

    /// Space Manager is the narrow, signed process that receives Full Disk
    /// Access. It exports only Chrome profile metadata to an unprotected cache
    /// so terminal commands never need broad disk access themselves.
    @discardableResult
    static func syncSharedProfileCache(
        localStateURL: URL = defaultLocalStateURL,
        cacheURL: URL = sharedProfileCacheURL
    ) throws -> Int {
        let profiles = try profilesFromLocalState(at: localStateURL)
        let payload: [String: Any] = [
            "version": 1,
            "profiles": profiles.map { profile in
                [
                    "directory": profile.directory,
                    "name": profile.name,
                    "email": profile.email,
                    "aliases": []
                ] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)

        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if (try? Data(contentsOf: cacheURL)) == data {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: cacheURL.path)
        } else {
            try data.write(to: cacheURL, options: .atomic)
        }
        if cacheURL == sharedProfileCacheURL {
            try? FileManager.default.removeItem(at: legacyProfileCacheURL)
        }
        return profiles.count
    }

    static func openNewWindow(profileDirectory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        // `-n` ensures Chrome receives the arguments even when it is already
        // running. `--new-window` is essential: without it Chrome can reuse a tab
        // in a window assigned to another Space and macOS will switch Spaces.
        process.arguments = [
            "-n", "-a", chromeApplicationName,
            "--args", "--new-window", "chrome://newtab",
            "--profile-directory=\(profileDirectory)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                NSLog(
                    "ChromeProfileManager: failed to open profile '%@': %@",
                    profileDirectory,
                    error.localizedDescription)
            }
        }
    }

    private static func profilesFromLocalState(at url: URL) throws -> [ChromeProfile] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return infoCache.compactMap { directory, rawInfo in
            guard let info = rawInfo as? [String: Any] else { return nil }
            return ChromeProfile(
                directory: directory,
                name: stringValue(info["name"]),
                email: stringValue(info["user_name"]))
        }
    }

    private static func profilesFromSharedCache(at url: URL) throws -> [ChromeProfile] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["profiles"] as? [[String: Any]]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return entries.compactMap { entry in
            let directory = stringValue(entry["directory"])
            guard !directory.isEmpty else { return nil }
            return ChromeProfile(
                directory: directory,
                name: stringValue(entry["name"]),
                email: stringValue(entry["email"]))
        }
    }

    private static func stringValue(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func profileSortKey(_ directory: String) -> String {
        if directory == "Default" { return "00000000" }
        if directory.hasPrefix("Profile "),
           let number = Int(directory.dropFirst("Profile ".count)) {
            return String(format: "%08d", number + 1)
        }
        return "99999999-\(directory.localizedLowercase)"
    }
}
