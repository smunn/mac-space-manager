//
//  WorkspaceConfig.swift
//  SpaceManager
//

import Foundation

struct WorkspaceEntry {
    let key: String
    let displayName: String
}

struct SiteFolderEntry {
    let displayName: String
    let path: String
}

enum WorkspaceConfig {
    private static let configPath = NSString(
        string: "~/Sites/sm-mac-configuration-scripts/config/workspaces.json"
    ).expandingTildeInPath

    private static let sitesPath = NSString(string: "~/Sites").expandingTildeInPath

    static func loadWorkspaces() -> [WorkspaceEntry] {
        guard let workspaces = loadWorkspaceDictionary() else { return [] }

        return workspaces.compactMap { key, value in
            guard value["prompt"] == nil else { return nil }
            let displayName = value["displayName"] as? String ?? key
            return WorkspaceEntry(key: key, displayName: displayName)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func loadSiteFolders() -> [SiteFolderEntry] {
        let represented = representedWorkspaceIdentifiers()
        let sitesURL = URL(fileURLWithPath: sitesPath)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sitesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let name = url.lastPathComponent
            let normalizedName = normalizeIdentifier(name)
            let normalizedPath = normalizePath(url.path)

            guard !represented.names.contains(normalizedName),
                  !represented.paths.contains(normalizedPath)
            else { return nil }

            return SiteFolderEntry(displayName: name, path: url.path)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func loadWorkspaceDictionary() -> [String: [String: Any]]? {
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = json["workspaces"] as? [String: [String: Any]]
        else { return nil }

        return workspaces
    }

    private static func representedWorkspaceIdentifiers() -> (names: Set<String>, paths: Set<String>) {
        guard let workspaces = loadWorkspaceDictionary() else {
            return ([], [])
        }

        var names = Set<String>()
        var paths = Set<String>()

        for (key, value) in workspaces {
            names.insert(normalizeIdentifier(key))

            if let displayName = value["displayName"] as? String {
                names.insert(normalizeIdentifier(displayName))
            }

            if let projectPath = value["projectPath"] as? String {
                paths.insert(normalizePath(NSString(string: projectPath).expandingTildeInPath))
            }
        }

        return (names, paths)
    }

    private static func normalizeIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizePath(_ value: String) -> String {
        URL(fileURLWithPath: value)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .lowercased()
    }
}
