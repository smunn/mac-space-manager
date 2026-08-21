//
//  SettingsView.swift
//  SpaceManager
//

import SwiftUI

enum SettingsTab: Hashable {
    case general
    case permissions
    case windowLayouts
}

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published var selection: SettingsTab

    init(selection: SettingsTab) {
        self.selection = selection
    }
}

struct SpaceManagerSettingsView: View {
    @ObservedObject var model: SettingsWindowModel
    let commands: [MagnetShortcutCommand]
    let onSave: ([MagnetShortcutCommand]) throws -> Void
    let onApply: ([MagnetShortcutCommand]) async throws -> Void

    var body: some View {
        TabView(selection: $model.selection) {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            WindowManagementPermissionsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)

            MagnetShortcutConfigurationView(
                commands: commands,
                onSave: onSave,
                onApply: onApply
            )
            .tabItem { Label("Window Layouts", systemImage: "keyboard") }
            .tag(SettingsTab.windowLayouts)
        }
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .debugLabel("spaceManagerSettingsView")
    }
}

struct SettingsView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @ObservedObject private var windowLayouts = WindowLayoutManager.shared
    @AppStorage("autoUpdateWorkspaceNames") private var autoUpdateWorkspaceNames = true
    @AppStorage(MissionControlNameOverlayController.enabledDefaultsKey)
    private var showNamesInMissionControl = true
    @AppStorage(WallpaperResetter.folderDefaultsKey) private var defaultWallpaperFolder = WallpaperResetter.defaultFolderPath

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("General") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Open at login",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .disabled(!launchAtLogin.canToggle)

                    HStack(spacing: 8) {
                        Text(launchAtLogin.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if launchAtLogin.needsApproval {
                            Button("Open Login Items") {
                                launchAtLogin.openLoginItemsSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }

                    if let errorMessage = launchAtLogin.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Toggle(
                        "Auto-update workspace names",
                        isOn: $autoUpdateWorkspaceNames
                    )

                    Toggle(
                        "Show names in Mission Control",
                        isOn: $showNamesInMissionControl
                    )

                    if windowLayouts.isMagnetRunning {
                        Divider()

                        HStack(spacing: 8) {
                            Text("Conflict: Magnet is running")
                                .font(.caption)
                                .foregroundStyle(.red)

                            Spacer()

                            Button("Quit Magnet") {
                                windowLayouts.quitMagnet()
                            }
                            .font(.caption)
                        }
                    }

                    if let error = windowLayouts.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if !windowLayouts.shortcutConflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Shortcut Conflicts", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            ForEach(windowLayouts.shortcutConflicts) { conflict in
                                Text(conflict.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Space Reset") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Default wallpaper folder", text: $defaultWallpaperFolder)

                        Button("Choose…") {
                            chooseWallpaperFolder()
                        }
                    }

                    Button("Reset Current Space") {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("ResetCurrentSpace"),
                            object: nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear {
            launchAtLogin.refresh()
        }
        .debugLabel("settingsView")
    }

    private func chooseWallpaperFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: NSString(string: defaultWallpaperFolder).expandingTildeInPath)

        if panel.runModal() == .OK, let url = panel.url {
            defaultWallpaperFolder = url.path
        }
    }
}

struct WindowManagementPermissionsView: View {
    @State private var permissionStates: [AppPermission: Bool] = [:]

    private var nextPermission: AppPermission? {
        AppPermission.allCases.first { permissionStates[$0] != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Window Management Permissions")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AppPermission.allCases) { permission in
                        PermissionStatusRow(
                            permission: permission,
                            isGranted: permissionStates[permission] ?? false
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let nextPermission {
                    Button("Grant \(nextPermission.title)") {
                        AppPermissions.request(nextPermission)
                        refreshAfterRequest()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Button("Refresh") {
                    refresh()
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .debugLabel("windowManagementPermissionsView")
    }

    private func refresh() {
        permissionStates = Dictionary(
            uniqueKeysWithValues: AppPermission.allCases.map { permission in
                (permission, AppPermissions.check(permission))
            }
        )
    }

    private func refreshAfterRequest() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            refresh()
        }
    }
}

private struct PermissionStatusRow: View {
    let permission: AppPermission
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(isGranted ? "Granted" : "Needed")
                .font(.caption)
                .foregroundStyle(isGranted ? Color.secondary : Color.red)

            Button(isGranted ? "Open" : "Grant") {
                AppPermissions.openSettings(for: permission)
            }
        }
        .debugLabel("PermissionStatusRow")
    }
}
