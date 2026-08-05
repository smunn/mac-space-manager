//
//  ProcessHealth.swift
//  SpaceManager
//
//  Value types displayed by the Process Health section. Stable identifiers are
//  deliberately based on the underlying device/session rather than scan time.
//

import Foundation

struct ProcessHealthSnapshot: Sendable, Equatable {
    let simulators: [SimulatorHealthItem]
    let aiSessions: [AISessionHealthItem]
    let scannedAt: Date

    static let empty = ProcessHealthSnapshot(simulators: [], aiSessions: [], scannedAt: .distantPast)
}

struct SimulatorHealthItem: Identifiable, Sendable, Equatable {
    let deviceName: String
    let runtimeName: String
    let deviceUUID: UUID
    let bootedAt: Date
    let scannedAt: Date
    let isActivelyUsed: Bool
    let isDevelopmentActive: Bool
    let isPastWarningThreshold: Bool

    var id: String { deviceUUID.uuidString.lowercased() }
    var title: String { deviceName }
    var detail: String { runtimeName }
    var bootDuration: TimeInterval { max(0, scannedAt.timeIntervalSince(bootedAt)) }
    var canShutDown: Bool { !isActivelyUsed && !isDevelopmentActive }
    var canCleanUp: Bool { canShutDown && isPastWarningThreshold }

    var statusLabels: [String] {
        if canCleanUp { return ["Recommended"] }
        if isActivelyUsed { return ["Active"] }
        if isDevelopmentActive { return ["Development active"] }
        return ["Running"]
    }
}

enum AISessionService: String, Sendable, Equatable {
    case codex = "Codex"
    case claude = "Claude"
}

enum AISessionCompletionStatus: String, Sendable, Equatable {
    case completed
    case active
    case uncertain
}

struct AISessionHealthItem: Identifiable, Sendable, Equatable {
    let service: AISessionService
    let processID: pid_t
    /// Process start time is part of cleanup validation and protects against PID reuse.
    let processStartedAt: Date
    let projectPath: String?
    let repositoryName: String?
    let sessionID: String?
    let sessionLogPath: String?
    let elapsedTime: TimeInterval
    let cpuTime: TimeInterval
    let cpuUsagePercent: Double
    let command: String
    let taskSummary: String?
    let completionSummary: String?
    let completionStatus: AISessionCompletionStatus
    let isDetached: Bool
    let hasUnavailableStandardIO: Bool

    var id: String {
        if let sessionID, !sessionID.isEmpty { return "\(service.rawValue.lowercased()):\(sessionID)" }
        return "\(service.rawValue.lowercased()):\(processID):\(processStartedAt.timeIntervalSince1970)"
    }

    var title: String { service.rawValue }
    var detail: String? {
        if let projectPath, !projectPath.isEmpty { return projectPath }
        return sessionID
    }

    var isHighCPU: Bool { cpuUsagePercent >= 50 }
    var isLongRunning: Bool { elapsedTime >= 2 * 60 * 60 }

    var statusLabels: [String] {
        var labels: [String] = []
        if canCleanUp { labels.append("Recommended") }
        if isDetached { labels.append("Detached") }
        if isHighCPU { labels.append("High CPU") }
        if isLongRunning && !isDetached { labels.append("Long-running") }
        if labels.isEmpty { labels.append("Running") }
        return labels
    }

    /// A revoked terminal plus an orphaned process tree is stronger evidence
    /// than log completion, which is not consistently emitted after crashes.
    var canCleanUp: Bool { isDetached && hasUnavailableStandardIO }
}
