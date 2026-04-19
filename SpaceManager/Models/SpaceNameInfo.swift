//
//  SpaceNameInfo.swift
//  SpaceManager
//
//  Adapted from Spaceman by Sasindu Jayasinghe (MIT License).
//

import Foundation

struct SpaceNameInfo: Hashable, Codable {
    let spaceNum: Int
    let spaceName: String
    let spaceByDesktopID: String

    var displayUUID: String?
    var positionOnDisplay: Int?
    var currentDisplayIndex: Int?
    var currentSpaceNumber: Int?

    var isUserOverride: Bool

    var hasUserData: Bool {
        return isUserOverride && !spaceName.isEmpty
    }

    init(
        spaceNum: Int,
        spaceName: String,
        spaceByDesktopID: String,
        isUserOverride: Bool = false
    ) {
        self.spaceNum = spaceNum
        self.spaceName = spaceName
        self.spaceByDesktopID = spaceByDesktopID
        self.isUserOverride = isUserOverride
    }

    func withName(_ newName: String, isOverride: Bool) -> SpaceNameInfo {
        var copy = SpaceNameInfo(
            spaceNum: spaceNum,
            spaceName: newName,
            spaceByDesktopID: spaceByDesktopID,
            isUserOverride: isOverride
        )
        copy.displayUUID = displayUUID
        copy.positionOnDisplay = positionOnDisplay
        copy.currentDisplayIndex = currentDisplayIndex
        copy.currentSpaceNumber = currentSpaceNumber
        return copy
    }
}
