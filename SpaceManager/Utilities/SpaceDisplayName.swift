//
//  SpaceDisplayName.swift
//  SpaceManager
//

import Foundation

enum SpaceDisplayName {
    static func repositoryName(for space: Space) -> String? {
        SpaceNamer().terminalFolderName(from: space.windows)
    }

    @MainActor
    static func title(for space: Space) -> String {
        let folderName = repositoryName(for: space)
        let nickname = SpaceLabelStore.shared.label(for: space.spaceID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName = generatedAppName(from: space.windows)

        var seen = Set<String>()
        let components = [
            folderName.map { ($0, "[\($0)]") },
            nickname.isEmpty ? nil : (nickname, "• \(nickname)"),
            generatedName.map { ($0, $0) }
        ]
            .compactMap { $0 }
            .filter { component in
                let value = component.0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return false }
                let key = value
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .lowercased()
                return seen.insert(key).inserted
            }
            .map(\.1)

        return components.isEmpty ? space.spaceName : components.joined(separator: " · ")
    }

    private static func generatedAppName(from windows: [SpaceWindow]) -> String? {
        var seen = Set<String>()
        let appNames = windows.compactMap { window -> String? in
            let name = displayName(for: window.ownerName)
            return seen.insert(name).inserted ? name : nil
        }
        return appNames.isEmpty ? nil : appNames.joined(separator: ", ")
    }

    private static func displayName(for applicationName: String) -> String {
        switch applicationName {
        case "Google Chrome": "Chrome"
        default: applicationName
        }
    }
}
