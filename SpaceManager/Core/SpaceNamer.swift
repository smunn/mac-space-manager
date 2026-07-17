//
//  SpaceNamer.swift
//  SpaceManager
//
//  Auto-generates descriptive names for spaces based on their window contents.
//

import Foundation

struct SpaceNamer {

    func terminalFolderName(from windows: [SpaceWindow]) -> String? {
        for window in windows {
            if let name = parseTerminalCWD(window) { return name }
        }
        return nil
    }

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
        // Priority: IDE projects > terminal CWD > Chrome context
        for window in windows {
            if let name = parseXcodeProject(window) { return name }
        }
        for window in windows {
            if let name = parseCursorOrVSCode(window) { return name }
        }
        if let name = terminalFolderName(from: windows) { return name }
        for window in windows {
            if let name = parseChromeContext(window) { return name }
        }
        return nil
    }

    private func parseXcodeProject(_ window: SpaceWindow) -> String? {
        guard window.ownerName == "Xcode" else { return nil }
        let title = window.windowTitle
        if title.isEmpty { return nil }

        if let dashRange = title.range(of: " \u{2014} ") ?? title.range(of: " - ") {
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

        if let dashRange = title.range(of: " \u{2014} ") ?? title.range(of: " - ") {
            let afterDash = String(title[dashRange.upperBound...])
            let folderName = afterDash
                .replacingOccurrences(of: " [SSH:", with: "")
                .replacingOccurrences(of: " (Workspace)", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !folderName.isEmpty && !folderName.contains("/") {
                return folderName
            }
        }

        return nil
    }

    private func parseTerminalCWD(_ window: SpaceWindow) -> String? {
        let terminals: Set<String> = ["Terminal", "iTerm2", "Alacritty", "kitty", "Warp", "Ghostty"]
        guard terminals.contains(window.ownerName) else { return nil }

        // Prefer the individual window title because one terminal process can own
        // windows in several different working directories.
        let title = window.windowTitle
        if !title.isEmpty,
           let dashRange = title.range(of: " \u{2014} ") ?? title.range(of: " - ")
        {
            let leadingValue = String(title[..<dashRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let genericValues: Set<String> = ["Terminal", "zsh", "bash", "fish", "sh"]
            if !leadingValue.isEmpty, !genericValues.contains(leadingValue) {
                return lastPathComponent(leadingValue)
            }
        }

        // Read from the pre-resolved process cache when the title has no folder.
        if let name = ProcessHelper.shared.cachedProjectName(terminalPID: window.ownerPID) {
            return name
        }

        if title.isEmpty { return nil }

        if let colonRange = title.range(of: ": ") {
            let path = String(title[colonRange.upperBound...])
            return lastPathComponent(path)
        }

        if title.hasPrefix("~") || title.hasPrefix("/") {
            return lastPathComponent(title)
        }

        return nil
    }

    private func parseChromeContext(_ window: SpaceWindow) -> String? {
        guard window.ownerName == "Google Chrome" else { return nil }
        let title = window.windowTitle
        if title.isEmpty { return nil }

        // Chrome multi-profile: "Page Title - ProfileName - Google Chrome"
        // Chrome single profile: "Page Title - Google Chrome"
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }

        if parts.count >= 3 {
            let profileName = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
            let pageTitle = parts[0].trimmingCharacters(in: .whitespaces)
            if !profileName.isEmpty && profileName != "Google Chrome" {
                return profileName
            }
            if !pageTitle.isEmpty {
                return truncatePageTitle(pageTitle)
            }
        }

        let pageTitle = parts[0].trimmingCharacters(in: .whitespaces)
        if !pageTitle.isEmpty {
            return truncatePageTitle(pageTitle)
        }

        return nil
    }

    private func truncatePageTitle(_ title: String) -> String {
        if title.count <= 30 { return title }
        return String(title.prefix(27)) + "..."
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
