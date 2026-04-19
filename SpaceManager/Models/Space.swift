//
//  Space.swift
//  SpaceManager
//
//  Space detection model adapted from Spaceman by Sasindu Jayasinghe (MIT License).
//

import Foundation

struct Space: Equatable, Identifiable {
    var id: String { spaceID }
    var displayID: String
    var spaceID: String
    var spaceName: String
    var spaceNumber: Int
    var spaceByDesktopID: String
    var isCurrentSpace: Bool
    var isFullScreen: Bool
    var windows: [SpaceWindow]

    static let maxSwitchableDesktop = 16

    static func buildSwitchIndexMap(for spaces: [Space]) -> [String: Int] {
        var map: [String: Int] = [:]
        var desktopIndex = 1
        var fullscreenIndex = 1
        for s in spaces {
            if s.isFullScreen {
                if fullscreenIndex == 1 {
                    map[s.spaceID] = -1
                }
                fullscreenIndex += 1
            } else {
                if desktopIndex <= maxSwitchableDesktop {
                    map[s.spaceID] = desktopIndex
                }
                desktopIndex += 1
            }
        }
        return map
    }
}
