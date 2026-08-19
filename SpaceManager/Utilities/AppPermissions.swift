//
//  AppPermissions.swift
//  SpaceManager
//
//  Centralizes macOS privacy permission checks and System Settings deep links.
//

import Cocoa

enum AppPermission: CaseIterable, Identifiable, Hashable {
    case accessibility
    case screenRecording

    var id: String { title }

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            return "Move windows and manage Spaces"
        case .screenRecording:
            return "Read window names"
        }
    }
}

enum AppPermissions {
    static var missingWindowManagementPermissions: [AppPermission] {
        AppPermission.allCases.filter { !check($0) }
    }

    static func check(_ permission: AppPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        }
    }

    @discardableResult
    static func request(_ permission: AppPermission) -> Bool {
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            return AXIsProcessTrustedWithOptions(options as CFDictionary)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        }
    }

    static func openSettings(for permission: AppPermission) {
        switch permission {
        case .accessibility:
            openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording:
            openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    private static func openSystemSettingsPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
