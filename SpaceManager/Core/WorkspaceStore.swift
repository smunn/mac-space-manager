//
//  WorkspaceStore.swift
//  SpaceManager
//

import Cocoa

// MARK: - Models

struct WorkspaceWallpaper {
    var background: String
    var foreground: String
    var font: String?
}

struct WorkspaceAppEntry: Identifiable {
    let id: UUID
    var type: String
    var position: String?
    var profile: String?
    var url: String?
    var name: String?
    var project: String?
    var command: String?
    var reuseCurrent: Bool?
    var isBackground: Bool?

    init(id: UUID = UUID(), type: String = "app", position: String? = nil, profile: String? = nil,
         url: String? = nil, name: String? = nil, project: String? = nil, command: String? = nil,
         reuseCurrent: Bool? = nil, isBackground: Bool? = nil) {
        self.id = id; self.type = type; self.position = position; self.profile = profile
        self.url = url; self.name = name; self.project = project; self.command = command
        self.reuseCurrent = reuseCurrent; self.isBackground = isBackground
    }

    static func from(_ dict: [String: Any]) -> WorkspaceAppEntry {
        WorkspaceAppEntry(
            type: dict["type"] as? String ?? "app",
            position: dict["position"] as? String,
            profile: dict["profile"] as? String,
            url: dict["url"] as? String,
            name: dict["name"] as? String,
            project: dict["project"] as? String,
            command: dict["command"] as? String,
            reuseCurrent: dict["reuseCurrent"] as? Bool,
            isBackground: dict["background"] as? Bool
        )
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let v = position, !v.isEmpty { dict["position"] = v }
        if let v = profile, !v.isEmpty { dict["profile"] = v }
        if let v = url, !v.isEmpty { dict["url"] = v }
        if let v = name, !v.isEmpty { dict["name"] = v }
        if let v = project, !v.isEmpty { dict["project"] = v }
        if let v = command, !v.isEmpty { dict["command"] = v }
        if let v = reuseCurrent, v { dict["reuseCurrent"] = v }
        if let v = isBackground, v { dict["background"] = v }
        return dict
    }

    var summary: String {
        switch type {
        case "chrome": return url ?? profile ?? "Chrome"
        case "terminal": return command ?? (reuseCurrent == true ? "Current shell" : "Terminal")
        case "xcode": return project?.components(separatedBy: "/").last ?? "Xcode"
        case "app": return name ?? "App"
        default: return type
        }
    }

    var icon: String {
        switch type {
        case "chrome": return "globe"
        case "terminal": return "terminal"
        case "xcode": return "hammer"
        case "app": return "app"
        default: return "questionmark.square"
        }
    }
}

struct WorkspacePromptChoice: Identifiable {
    let id: UUID
    var name: String
    var apps: [WorkspaceAppEntry]

    init(id: UUID = UUID(), name: String, apps: [WorkspaceAppEntry]) {
        self.id = id; self.name = name; self.apps = apps
    }
}

struct WorkspacePromptConfig {
    var question: String
    var choices: [WorkspacePromptChoice]

    func toDict() -> [String: Any] {
        var choicesDict: [String: [[String: Any]]] = [:]
        for choice in choices {
            choicesDict[choice.name] = choice.apps.map { $0.toDict() }
        }
        return ["question": question, "choices": choicesDict]
    }
}

struct ManagedWorkspace: Identifiable {
    let key: String
    var displayName: String
    var projectPath: String?
    var isArchived: Bool
    var chromeProfile: String?
    var chromeUrl: String?
    var chromeUrls: [String]?
    var layout: String?
    var wallpaper: WorkspaceWallpaper?
    var apps: [WorkspaceAppEntry]?
    var prompt: WorkspacePromptConfig?

    var hasPrompt: Bool { prompt != nil }
    var id: String { key }
}

// MARK: - Store

final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [ManagedWorkspace] = []
    @Published var availableLayouts: [String] = []

    static let configPath = NSString(
        string: "~/Sites/mac-configuration-scripts/config/workspaces.json"
    ).expandingTildeInPath

    private var fullJSON: [String: Any] = [:]

    init() {
        reload()
    }

    func reload() {
        let url = URL(fileURLWithPath: Self.configPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["workspaces"] as? [String: [String: Any]]
        else {
            workspaces = []
            return
        }

        fullJSON = json

        if let layouts = json["layouts"] as? [String: Any] {
            availableLayouts = layouts.keys.sorted()
        }

        workspaces = dict.map { key, value in
            let wallpaper: WorkspaceWallpaper? = {
                guard let wp = value["wallpaper"] as? [String: Any],
                      let bg = wp["background"] as? String,
                      let fg = wp["foreground"] as? String
                else { return nil }
                return WorkspaceWallpaper(background: bg, foreground: fg, font: wp["font"] as? String)
            }()

            let apps: [WorkspaceAppEntry]? = {
                guard let arr = value["apps"] as? [[String: Any]] else { return nil }
                return arr.map { WorkspaceAppEntry.from($0) }
            }()

            let prompt: WorkspacePromptConfig? = {
                guard let p = value["prompt"] as? [String: Any],
                      let question = p["question"] as? String,
                      let choices = p["choices"] as? [String: [[String: Any]]]
                else { return nil }
                let parsed = choices.map { name, appDicts in
                    WorkspacePromptChoice(name: name, apps: appDicts.map { WorkspaceAppEntry.from($0) })
                }.sorted { $0.name < $1.name }
                return WorkspacePromptConfig(question: question, choices: parsed)
            }()

            return ManagedWorkspace(
                key: key,
                displayName: value["displayName"] as? String ?? key,
                projectPath: value["projectPath"] as? String,
                isArchived: value["archived"] as? Bool ?? false,
                chromeProfile: value["chromeProfile"] as? String,
                chromeUrl: value["chromeUrl"] as? String,
                chromeUrls: value["chromeUrls"] as? [String],
                layout: value["layout"] as? String,
                wallpaper: wallpaper,
                apps: apps,
                prompt: prompt
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func setArchived(_ workspace: ManagedWorkspace, archived: Bool) {
        guard var dict = fullJSON["workspaces"] as? [String: [String: Any]],
              var entry = dict[workspace.key]
        else { return }

        if archived {
            entry["archived"] = true
        } else {
            entry.removeValue(forKey: "archived")
        }

        dict[workspace.key] = entry
        fullJSON["workspaces"] = dict
        save()
        reload()
    }

    func remove(_ workspace: ManagedWorkspace) {
        guard var dict = fullJSON["workspaces"] as? [String: [String: Any]] else { return }
        dict.removeValue(forKey: workspace.key)
        fullJSON["workspaces"] = dict
        save()
        reload()
    }

    func add(key: String, displayName: String, projectPath: String?) {
        guard var dict = fullJSON["workspaces"] as? [String: [String: Any]] else { return }
        guard !key.isEmpty, dict[key] == nil else { return }

        var entry: [String: Any] = ["displayName": displayName]
        if let path = projectPath, !path.isEmpty {
            entry["projectPath"] = path
        }

        dict[key] = entry
        fullJSON["workspaces"] = dict
        save()
        reload()
    }

    func updateWorkspace(_ workspace: ManagedWorkspace) {
        guard var dict = fullJSON["workspaces"] as? [String: [String: Any]] else { return }
        var entry = dict[workspace.key] ?? [:]

        entry["displayName"] = workspace.displayName
        setOrRemove(&entry, "projectPath", workspace.projectPath)
        setOrRemove(&entry, "chromeProfile", workspace.chromeProfile)
        setOrRemove(&entry, "layout", workspace.layout)

        if let urls = workspace.chromeUrls, !urls.filter({ !$0.isEmpty }).isEmpty {
            entry.removeValue(forKey: "chromeUrl")
            entry["chromeUrls"] = urls.filter { !$0.isEmpty }
        } else if let url = workspace.chromeUrl, !url.isEmpty {
            entry["chromeUrl"] = url
            entry.removeValue(forKey: "chromeUrls")
        } else {
            entry.removeValue(forKey: "chromeUrl")
            entry.removeValue(forKey: "chromeUrls")
        }

        if let wp = workspace.wallpaper, !wp.background.isEmpty, !wp.foreground.isEmpty {
            var wpDict: [String: Any] = ["background": wp.background, "foreground": wp.foreground]
            if let font = wp.font, !font.isEmpty { wpDict["font"] = font }
            entry["wallpaper"] = wpDict
        } else {
            entry.removeValue(forKey: "wallpaper")
        }

        if let apps = workspace.apps, !apps.isEmpty {
            entry["apps"] = apps.map { $0.toDict() }
        } else {
            entry.removeValue(forKey: "apps")
        }

        if let prompt = workspace.prompt {
            entry["prompt"] = prompt.toDict()
        } else {
            entry.removeValue(forKey: "prompt")
        }

        if workspace.isArchived {
            entry["archived"] = true
        } else {
            entry.removeValue(forKey: "archived")
        }

        dict[workspace.key] = entry
        fullJSON["workspaces"] = dict
        save()
        reload()
    }

    private func setOrRemove(_ dict: inout [String: Any], _ key: String, _ value: String?) {
        if let v = value, !v.isEmpty {
            dict[key] = v
        } else {
            dict.removeValue(forKey: key)
        }
    }

    private static let repoPath = NSString(
        string: "~/Sites/mac-configuration-scripts"
    ).expandingTildeInPath

    private func save() {
        let url = URL(fileURLWithPath: Self.configPath)
        guard let data = try? JSONSerialization.data(
            withJSONObject: fullJSON,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: url, options: [.atomic])

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("RequestSpaceRefresh"), object: nil)
        }

        commitAndPush()
    }

    private func commitAndPush() {
        DispatchQueue.global(qos: .utility).async {
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", """
                cd '\(Self.repoPath)' && \
                git add config/workspaces.json && \
                (git diff --cached --quiet || \
                (git commit -m 'Update workspaces config' && \
                git pull --rebase --quiet && \
                git push --quiet))
                """]
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Self.showSyncError("Failed to run git: \(error.localizedDescription)")
                return
            }

            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                Self.showSyncError(output)
                return
            }
        }
    }

    private static func showSyncError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Workspace Sync Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
