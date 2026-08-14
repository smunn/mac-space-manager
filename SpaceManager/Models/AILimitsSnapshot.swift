//
//  AILimitsSnapshot.swift
//  SpaceManager
//

import Foundation

struct AILimitValue: Equatable {
    let percentUsed: Int?
    let resetsAt: Date?
}

struct AIServiceLimitsSnapshot: Equatable {
    let fiveHour: AILimitValue
    let weekly: AILimitValue
    let fable: AILimitValue?
    let collectedAt: Date?
}

struct AILimitsSnapshot: Equatable {
    let claude: AIServiceLimitsSnapshot
    let codex: AIServiceLimitsSnapshot
}
