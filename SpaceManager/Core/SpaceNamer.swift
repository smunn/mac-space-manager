//
//  SpaceNamer.swift
//  SpaceManager
//
//  Auto-generates descriptive names for spaces based on their window contents.
//

import Foundation

struct SpaceNamer {

    func generateName(for windows: [SpaceWindow], spaceNumber: Int) -> String {
        if windows.isEmpty {
            return "Space \(spaceNumber)"
        }

        if let projectName = detectProjectName(from: windows) {
            return projectName
        }

        let appGroups = groupByApp(windows)

        if appGroups.count == 1, let appName = appGroups.first?.key {
            return appName
        }

        let sorted = appGroups.sorted { $0.value.count > $1.value.count }
        let topApps = sorted.prefix(2).map { $0.key }
        return topApps.joined(separator: ", ")
    }

    private func detectProjectName(from windows: [SpaceWindow]) -> String? {
        for window in windows {
            if let name = parseXcodeProject(window) { return name }
            if let name = parseCursorOrVSCode(window) { return name }
            if let name = parseTerminal(window) { return name }
        }
        return nil
    }

    private func parseXcodeProject(_ window: SpaceWindow) -> String? {
        guard window.ownerName == "Xcode" else { return nil }
        let title = window.windowTitle
        if title.isEmpty { return nil }

        // Xcode titles: "ProjectName — FileName.swift" or "ProjectName"
        if let dashRange = title.range(of: " — ") ?? title.range(of: " - ") {
            let project = String(title[title.startIndex..<dashRange.lowerBound])
            if !project.isEmpty { return project }
        }

        if !title.contains(".") && !title.contains("/") {
            return title
        }

        return nil
    }

    private func parseCursorOrVSCode(_ window: SpaceWindow) -> String? {
        let editors = ["Cursor", "Code", "Visual Studio Code", "VSCodium"]
        guard editors.contains(window.ownerName) else { return nil }
        let title = window.windowTitle
        if title.isEmpty { return nil }

        // Cursor/VS Code titles: "filename — ProjectFolder" or "ProjectFolder"
        if let dashRange = title.range(of: " — ") ?? title.range(of: " - ") {
            let afterDash = String(title[dashRange.upperBound...])
            let folderName = afterDash
                .replacingOccurrences(of: " [SSH", with: "")
                .replacingOccurrences(of: " (Workspace)", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !folderName.isEmpty && !folderName.contains("/") {
                return folderName
            }
        }

        return nil
    }

    private func parseTerminal(_ window: SpaceWindow) -> String? {
        let terminals = ["Terminal", "iTerm2", "Alacritty", "kitty", "Warp", "Ghostty"]
        guard terminals.contains(window.ownerName) else { return nil }

        let title = window.windowTitle
        if title.isEmpty { return nil }

        // Terminal titles often show "user@host: ~/path/to/project" or just the directory
        if let colonRange = title.range(of: ": ") {
            let path = String(title[colonRange.upperBound...])
            return lastPathComponent(path)
        }

        if title.hasPrefix("~") || title.hasPrefix("/") {
            return lastPathComponent(title)
        }

        return nil
    }

    private func lastPathComponent(_ path: String) -> String? {
        let cleaned = path.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        let components = cleaned.split(separator: "/")
        if let last = components.last {
            let name = String(last)
            if name != "~" && !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func groupByApp(_ windows: [SpaceWindow]) -> [String: [SpaceWindow]] {
        var groups: [String: [SpaceWindow]] = [:]
        for window in windows {
            groups[window.ownerName, default: []].append(window)
        }
        return groups
    }
}
