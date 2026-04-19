//
//  SpaceWindow.swift
//  SpaceManager
//

import Foundation

struct SpaceWindow: Equatable, Hashable {
    let windowID: Int
    let ownerName: String
    let ownerPID: pid_t
    let windowTitle: String
    let bounds: CGRect
    let isOnScreen: Bool

    var displayName: String {
        if !windowTitle.isEmpty {
            return "\(ownerName): \(windowTitle)"
        }
        return ownerName
    }
}
