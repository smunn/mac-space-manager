//
//  SpaceManagerApp.swift
//  SpaceManager
//

import SwiftUI

@main
struct SpaceManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("Space Manager Preferences")
                .padding()
        }
    }
}
