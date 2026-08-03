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

    var id: String { deviceUUID.uuidString.lowercased() }
    var title: String { deviceName }
    var detail: String { runtimeName }
    var bootDuration: TimeInterval { max(0, scannedAt.timeIntervalSince(bootedAt)) }
    var canCleanUp: Bool { !isActivelyUsed }
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
    let sessionID: String?
    let sessionLogPath: String?
    let elapsedTime: TimeInterval
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
        if let projectPath, !projectPath.isEmpty {
            return URL(fileURLWithPath: projectPath).lastPathComponent
        }
        return sessionID
    }

    /// Cleanup is intentionally narrower than detection. Every independent
    /// signal must agree before the UI is allowed to offer process termination.
    var canCleanUp: Bool {
        // Claude's `end_turn` means it is waiting for the user, not that the
        // overall task is finished. Until Claude exposes stronger evidence,
        // detected Claude sessions remain review-only.
        service == .codex
            && isDetached
            && hasUnavailableStandardIO
            && completionStatus == .completed
            && sessionLogPath != nil
    }
}
