//
//  UsageTelemetryReportExporter.swift
//  SpaceManager
//

import Foundation

struct UsageTelemetryExport {
    let directoryURL: URL
    let rawDataURL: URL
    let analysisPromptURL: URL
}

final class UsageTelemetryReportExporter {
    private let store: UsageTelemetryStoring
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder

    init(
        store: UsageTelemetryStoring = JSONLinesUsageTelemetryStore(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.fileManager = fileManager
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// Creates a self-contained folder containing machine-readable history and an AI-ready prompt.
    func export(to parentDirectory: URL) throws -> UsageTelemetryExport {
        let events = try store.loadEvents().sorted { $0.timestamp < $1.timestamp }
        let exportDirectory = uniqueExportDirectory(in: parentDirectory)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let rawDataURL = exportDirectory.appendingPathComponent("space-manager-telemetry.json")
        let promptURL = exportDirectory.appendingPathComponent("analyze-menu-order.md")
        try encoder.encode(events).write(to: rawDataURL, options: .atomic)
        try analysisPrompt(for: events).write(to: promptURL, atomically: true, encoding: .utf8)

        return UsageTelemetryExport(
            directoryURL: exportDirectory,
            rawDataURL: rawDataURL,
            analysisPromptURL: promptURL)
    }

    private func uniqueExportDirectory(in parentDirectory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let baseName = "Space Manager Telemetry \(formatter.string(from: now()))"
        var candidate = parentDirectory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentDirectory.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func analysisPrompt(for events: [UsageTelemetryEvent]) -> String {
        let first = events.first?.timestamp
        let last = events.last?.timestamp
        let menuOpenCount = events.count { $0.kind == .menuOpened }
        let actionCount = events.count { $0.kind == .actionSelected }
        let durations = events.compactMap(\.durationSeconds)
        let totalDuration = durations.reduce(0, +)
        let averageDuration = durations.isEmpty ? 0 : totalDuration / Double(durations.count)
        let range = dateRange(first: first, last: last)

        return """
        # Space Manager Menu Telemetry Analysis

        Analyze the attached `space-manager-telemetry.json` file and recommend a revised ordering and grouping for the Space Manager menu based on observed use.

        ## Export summary

        - Date range: \(range)
        - Events: \(events.count)
        - Menu opens: \(menuOpenCount)
        - Action selections: \(actionCount)
        - Average completed menu dwell time: \(String(format: "%.2f", averageDuration)) seconds

        ## Analysis requirements

        1. Rank menus by open count, completed dwell time, and action conversion rate.
        2. Rank actions by selection count and recency.
        3. Identify frequently opened menus, commonly selected actions, opened-but-rarely-used menus, and items that should be promoted, demoted, regrouped, or collapsed.
        4. Reexamine the current menu order and propose a specific top-to-bottom order optimized for actual usage.
        5. Preserve fast access to core Space switching and lifecycle controls, and treat destructive actions conservatively.
        6. Separate evidence from recommendations and call out sparse data or ambiguous results.
        7. Do not interpret a menu open as proof that any individual row was viewed; this telemetry records menu tracking and explicit actions, not eye tracking or row exposure. Submenu durations can be upper bounds because any submenu still marked open is closed when the root menu's tracking session ends.
        8. Include a compact table of counts, dwell-time statistics, conversion rates, and the proposed destination for every recorded identifier.

        The telemetry is local interaction metadata. Stable identifiers describe product features; use their event kinds and timestamps to calculate the analysis rather than relying on current display positions.
        """
    }

    private func dateRange(first: Date?, last: Date?) -> String {
        guard let first, let last else { return "No events recorded" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a zzz"
        return "\(formatter.string(from: first)) through \(formatter.string(from: last))"
    }
}
