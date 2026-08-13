//
//  WorkspaceDetailView.swift
//  SpaceManager
//

import SwiftUI

struct WorkspaceDetailView: View {
    @ObservedObject var store: WorkspaceStore
    let workspaceKey: String

    @State private var displayName = ""
    @State private var projectPath = ""
    @State private var layout = ""
    @State private var wpBackground = ""
    @State private var wpForeground = ""
    @State private var wpFont = ""
    @State private var apps: [WorkspaceAppEntry] = []
    @State private var isArchived = false
    @State private var hasPrompt = false
    @State private var promptQuestion = ""
    @State private var promptChoices: [WorkspacePromptChoice] = []

    var body: some View {
        Form {
            generalSection
            wallpaperSection
            layoutSection
            appsSection
            if hasPrompt {
                promptSection
            } else {
                Section {
                    Button(action: { hasPrompt = true }) {
                        Label("Add Prompt", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadWorkspace() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveWorkspace() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .debugLabel("workspaceDetailView")
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            LabeledContent("Key") {
                Text(workspaceKey)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            TextField("Display Name", text: $displayName)
            LabeledContent("Project Path") {
                HStack {
                    TextField("", text: $projectPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") { browseProjectPath() }
                }
            }
            Toggle("Archived", isOn: $isArchived)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var layoutSection: some View {
        Section("Layout") {
            Picker("Layout", selection: $layout) {
                Text("None").tag("")
                ForEach(store.availableLayouts, id: \.self) { l in
                    Text(l).tag(l)
                }
            }
        }
    }

    // MARK: - Wallpaper

    @ViewBuilder
    private var wallpaperSection: some View {
        Section("Wallpaper") {
            HexColorPicker(label: "Background", hex: $wpBackground)
            HexColorPicker(label: "Foreground", hex: $wpForeground)
            TextField("Font", text: $wpFont)
        }
    }

    // MARK: - Apps

    @ViewBuilder
    private var appsSection: some View {
        Section("Apps") {
            if apps.isEmpty {
                Text("No app entries")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach($apps) { $app in
                    AppEntryRow(app: $app, onDelete: {
                        apps.removeAll { $0.id == app.id }
                    })
                }
            }
            Button(action: { apps.append(WorkspaceAppEntry()) }) {
                Label("Add App Entry", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Prompt

    @ViewBuilder
    private var promptSection: some View {
        Section("Prompt") {
            TextField("Question", text: $promptQuestion)
            ForEach($promptChoices) { $choice in
                DisclosureGroup {
                    TextField("Choice Name", text: $choice.name)
                    ForEach($choice.apps) { $app in
                        AppEntryRow(app: $app, onDelete: {
                            choice.apps.removeAll { $0.id == app.id }
                        })
                    }
                    Button(action: { choice.apps.append(WorkspaceAppEntry()) }) {
                        Label("Add App", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Spacer()
                        Button("Remove Choice", role: .destructive) {
                            promptChoices.removeAll { $0.id == choice.id }
                        }
                        .foregroundStyle(.red)
                    }
                } label: {
                    Text(choice.name.isEmpty ? "Untitled Choice" : choice.name)
                }
            }
            Button(action: {
                promptChoices.append(WorkspacePromptChoice(name: "", apps: []))
            }) {
                Label("Add Choice", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            HStack {
                Spacer()
                Button("Remove Prompt", role: .destructive) {
                    hasPrompt = false
                    promptQuestion = ""
                    promptChoices = []
                }
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Load / Save

    private func loadWorkspace() {
        guard let ws = store.workspaces.first(where: { $0.key == workspaceKey }) else { return }
        displayName = ws.displayName
        projectPath = ws.projectPath ?? ""
        layout = ws.layout ?? ""
        wpBackground = ws.wallpaper?.background ?? ""
        wpForeground = ws.wallpaper?.foreground ?? ""
        wpFont = ws.wallpaper?.font ?? ""
        isArchived = ws.isArchived

        // Synthesize chrome app entries from top-level chrome fields
        var loadedApps: [WorkspaceAppEntry] = []
        if let profile = ws.chromeProfile, !profile.isEmpty {
            if let urls = ws.chromeUrls, !urls.isEmpty {
                for url in urls {
                    loadedApps.append(WorkspaceAppEntry(type: "chrome", profile: profile, url: url))
                }
            } else {
                loadedApps.append(WorkspaceAppEntry(type: "chrome", profile: profile, url: ws.chromeUrl))
            }
        }
        if let existing = ws.apps {
            loadedApps.append(contentsOf: existing)
        }
        apps = loadedApps

        if let prompt = ws.prompt {
            hasPrompt = true
            promptQuestion = prompt.question
            promptChoices = prompt.choices
        } else {
            hasPrompt = false
            promptQuestion = ""
            promptChoices = []
        }
    }

    private func saveWorkspace() {
        let wallpaper: WorkspaceWallpaper? = (!wpBackground.isEmpty && !wpForeground.isEmpty)
            ? WorkspaceWallpaper(background: wpBackground, foreground: wpForeground,
                                 font: wpFont.isEmpty ? nil : wpFont)
            : nil

        let prompt: WorkspacePromptConfig? = hasPrompt && !promptQuestion.isEmpty
            ? WorkspacePromptConfig(question: promptQuestion, choices: promptChoices)
            : nil

        // When a layout is set, chrome entries map to top-level fields for launcher compat
        var chromeProfile: String? = nil
        var chromeUrl: String? = nil
        var chromeUrls: [String]? = nil
        var savedApps: [WorkspaceAppEntry] = []

        if !layout.isEmpty {
            let chromeEntries = apps.filter { $0.type == "chrome" }
            let otherEntries = apps.filter { $0.type != "chrome" }

            if let first = chromeEntries.first {
                chromeProfile = first.profile
                let urls = chromeEntries.compactMap(\.url).filter { !$0.isEmpty }
                if urls.count == 1 {
                    chromeUrl = urls[0]
                } else if urls.count > 1 {
                    chromeUrls = urls
                }
            }
            savedApps = otherEntries
        } else {
            savedApps = apps
        }

        let updated = ManagedWorkspace(
            key: workspaceKey,
            displayName: displayName,
            projectPath: projectPath.isEmpty ? nil : projectPath,
            isArchived: isArchived,
            chromeProfile: chromeProfile,
            chromeUrl: chromeUrl,
            chromeUrls: chromeUrls,
            layout: layout.isEmpty ? nil : layout,
            wallpaper: wallpaper,
            apps: savedApps.isEmpty ? nil : savedApps,
            prompt: prompt
        )

        store.updateWorkspace(updated)
    }

    private func browseProjectPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = url.path
            projectPath = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }
}

// MARK: - App Entry Row

struct AppEntryRow: View {
    @Binding var app: WorkspaceAppEntry
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            Picker("Type", selection: $app.type) {
                Text("Chrome").tag("chrome")
                Text("Terminal").tag("terminal")
                Text("App").tag("app")
                Text("Xcode").tag("xcode")
            }

            TextField("Position", text: optionalBinding(\.position))

            switch app.type {
            case "chrome":
                ChromeProfilePicker(profile: optionalBinding(\.profile))
                TextField("URL", text: optionalBinding(\.url))
            case "terminal":
                TextField("Command", text: optionalBinding(\.command))
                Toggle("Reuse Current", isOn: optionalBoolBinding(\.reuseCurrent))
            case "app":
                TextField("Name", text: optionalBinding(\.name))
                Toggle("Background", isOn: optionalBoolBinding(\.isBackground))
            case "xcode":
                TextField("Project", text: optionalBinding(\.project))
            default:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Remove", role: .destructive, action: onDelete)
                    .foregroundStyle(.red)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: app.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(app.summary)
                    .lineLimit(1)
                Spacer()
                if let pos = app.position, !pos.isEmpty {
                    Text(pos)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .debugLabel("AppEntryRow")
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<WorkspaceAppEntry, String?>) -> Binding<String> {
        Binding(
            get: { app[keyPath: keyPath] ?? "" },
            set: { app[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalBoolBinding(_ keyPath: WritableKeyPath<WorkspaceAppEntry, Bool?>) -> Binding<Bool> {
        Binding(
            get: { app[keyPath: keyPath] ?? false },
            set: { app[keyPath: keyPath] = $0 ? true : nil }
        )
    }
}

// MARK: - Chrome Profile Picker

struct ChromeProfilePicker: View {
    @Binding var profile: String

    private var knownProfiles: [ChromeProfile] {
        ChromeProfileManager.profiles()
    }

    private var isCustom: Bool {
        !profile.isEmpty && !knownProfiles.contains(where: { $0.directory == profile })
    }

    var body: some View {
        Picker("Chrome Profile", selection: $profile) {
            Text("None").tag("")
            ForEach(knownProfiles, id: \.directory) { profile in
                Text("\(profile.displayName) (\(profile.directory))").tag(profile.directory)
            }
            if isCustom {
                Text(profile).tag(profile)
            }
        }
        .debugLabel("ChromeProfilePicker")
    }
}

// MARK: - Hex Color Picker

private struct HexColorPicker: View {
    let label: String
    @Binding var hex: String

    private var color: Binding<Color> {
        Binding(
            get: { Color(hex: hex.isEmpty ? "000000" : hex) },
            set: { hex = $0.hexString }
        )
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField("", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .font(.system(.body, design: .monospaced))
                ColorPicker("", selection: color, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - Color Helpers

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02x%02x%02x",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255)))
    }
}
