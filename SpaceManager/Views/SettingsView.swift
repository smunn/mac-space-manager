//
//  SettingsView.swift
//  SpaceManager
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @ObservedObject private var windowLayouts = WindowLayoutManager.shared
    @AppStorage("autoUpdateWorkspaceNames") private var autoUpdateWorkspaceNames = true
    @AppStorage(WallpaperResetter.folderDefaultsKey) private var defaultWallpaperFolder = WallpaperResetter.defaultFolderPath
    @State private var permissionStates: [AppPermission: Bool] = [:]

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

                    Divider()

                    Toggle(
                        "Window layouts",
                        isOn: Binding(
                            get: { windowLayouts.isEnabled },
                            set: { windowLayouts.setEnabled($0) }
                        )
                    )

                    if let error = windowLayouts.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AppPermission.allCases, id: \.self) { permission in
                        PermissionStatusRow(
                            permission: permission,
                            isGranted: permissionStates[permission] ?? false
                        )
                    }

                    Button("Refresh") {
                        refresh()
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
            refresh()
        }
        .debugLabel("settingsView")
    }

    private func refresh() {
        permissionStates = Dictionary(
            uniqueKeysWithValues: AppPermission.allCases.map { permission in
                (permission, AppPermissions.check(permission))
            }
        )
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

            Button("Open") {
                AppPermissions.openSettings(for: permission)
            }
        }
        .debugLabel("PermissionStatusRow")
    }
}
