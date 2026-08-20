//
//  UsageTelemetryEvent.swift
//  SpaceManager
//

import Foundation

/// A stable, code-defined name used to aggregate telemetry across app versions.
/// Identifiers must describe the feature rather than its current visible title or position.
struct TelemetryIdentifier: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        precondition(!rawValue.isEmpty, "Telemetry identifiers cannot be empty")
        self.rawValue = rawValue
    }
}

struct UsageTelemetryEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case menuOpened = "menu_opened"
        case menuClosed = "menu_closed"
        case actionSelected = "action_selected"
    }

    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let identifier: TelemetryIdentifier
    let parentIdentifier: TelemetryIdentifier?
    let sessionID: UUID?
    let durationSeconds: Double?

    init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        timestamp: Date,
        kind: Kind,
        identifier: TelemetryIdentifier,
        parentIdentifier: TelemetryIdentifier? = nil,
        sessionID: UUID? = nil,
        durationSeconds: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.sessionID = sessionID
        self.durationSeconds = durationSeconds
    }
}
