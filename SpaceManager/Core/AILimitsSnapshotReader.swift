//
//  AILimitsSnapshotReader.swift
//  SpaceManager
//
//  Reads the shared usage snapshot written by Scott's AI usage collectors.
//  The file is the same source used by the `limits` shell command, so opening
//  the menu never makes a second network request or requires browser access.
//

import Foundation

struct AILimitsSnapshotReader {
    static let shared = AILimitsSnapshotReader()

    private let fileURL: URL

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/usage-stats.json")) {
        self.fileURL = fileURL
    }

    func read() -> AILimitsSnapshot? {
        // The collector replaces this JSON frequently. A brief retry handles a
        // non-atomic writer without delaying normal menu opening.
        for attempt in 0..<3 {
            if let snapshot = readOnce() {
                return snapshot
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return nil
    }

    private func readOnce() -> AILimitsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["claude"] is [String: Any] || root["codex"] is [String: Any]
        else { return nil }

        let fallbackDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let claude = serviceDictionary(named: "claude", in: root)
        let codex = serviceDictionary(named: "codex", in: root)

        return AILimitsSnapshot(
            claude: claudeSnapshot(from: claude, fallbackDate: fallbackDate),
            codex: codexSnapshot(from: codex, fallbackDate: fallbackDate))
    }

    private func serviceDictionary(named name: String, in root: [String: Any]) -> [String: Any] {
        guard let service = root[name] as? [String: Any] else { return [:] }
        guard let accounts = service["accounts"] as? [String: Any] else { return service }

        let freshestAccount = accounts.values
            .compactMap { $0 as? [String: Any] }
            .max {
                (timestamp(from: $0) ?? .distantPast)
                    < (timestamp(from: $1) ?? .distantPast)
            }

        guard let freshestAccount else { return service }
        return freshestAccount.merging(service) { _, serviceValue in serviceValue }
    }

    private func claudeSnapshot(
        from service: [String: Any],
        fallbackDate: Date?
    ) -> AIServiceLimitsSnapshot {
        let metrics = service["metrics"] as? [[String: Any]] ?? []
        let sessionMetric = metrics.first { string($0["key"]) == "current_session" }
        let weeklyMetric = metrics.first { string($0["key"]) == "all_models" }
        let fableMetric = metrics.first {
            string($0["key"]).localizedCaseInsensitiveContains("fable") ||
                string($0["label"]).localizedCaseInsensitiveContains("fable")
        }

        return AIServiceLimitsSnapshot(
            fiveHour: limit(
                percent: integer(service["session"]) ?? integer(sessionMetric?["pctUsed"]),
                reset: epochDate(service["sessionResetEpoch"])
                    ?? epochDate(sessionMetric?["resetEpoch"])),
            weekly: limit(
                percent: integer(service["weeklyAll"]) ?? integer(weeklyMetric?["pctUsed"]),
                reset: epochDate(service["weeklyAllResetEpoch"])
                    ?? epochDate(weeklyMetric?["resetEpoch"])),
            fable: fableMetric.map {
                limit(
                    percent: integer($0["pctUsed"]) ?? integer($0["usedPercent"]),
                    reset: epochDate($0["resetEpoch"]) ?? epochDate($0["resetsAt"]))
            },
            collectedAt: timestamp(from: service) ?? fallbackDate)
    }

    private func codexSnapshot(
        from service: [String: Any],
        fallbackDate: Date?
    ) -> AIServiceLimitsSnapshot {
        let limits = service["limits"] as? [[String: Any]] ?? []
        let fiveHour = limits.first {
            let label = string($0["label"])
            return label.range(of: #"5[ -]?hour"#, options: [.regularExpression, .caseInsensitive]) != nil
                || integer($0["windowMinutes"]) == 300
        }
        let weekly = limits.first {
            string($0["label"]).caseInsensitiveCompare("Weekly usage limit") == .orderedSame
                || (integer($0["windowMinutes"]) == 10_080 && $0["limitName"] is NSNull)
        } ?? limits.first {
            string($0["label"]).localizedCaseInsensitiveContains("weekly")
        }

        return AIServiceLimitsSnapshot(
            fiveHour: limit(from: fiveHour),
            weekly: limit(from: weekly),
            fable: nil,
            collectedAt: timestamp(from: service) ?? fallbackDate)
    }

    private func limit(from dictionary: [String: Any]?) -> AILimitValue {
        limit(
            percent: integer(dictionary?["pctUsed"]) ?? integer(dictionary?["usedPercent"]),
            reset: epochDate(dictionary?["resetEpoch"])
                ?? epochDate(dictionary?["resetsAt"]))
    }

    private func limit(percent: Int?, reset: Date?) -> AILimitValue {
        AILimitValue(percentUsed: percent, resetsAt: reset)
    }

    private func timestamp(from dictionary: [String: Any]) -> Date? {
        epochDate(dictionary["ts"])
            ?? isoDate(dictionary["collectedAt"])
            ?? epochDate((dictionary["account"] as? [String: Any])?["scrapedAt"])
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private func epochDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let rawValue = number.doubleValue
        guard rawValue > 0 else { return nil }
        let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private func isoDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
