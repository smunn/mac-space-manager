//
//  AILimitsSnapshotReader.swift
//  SpaceManager
//
//  Reads the shared usage snapshot written by Scott's AI usage collectors.
//  The local file remains primary; machines without the collector fall back to
//  the same read-only Supabase RPC and cache used by the `limits` shell command.
//

import Foundation

struct AILimitsSnapshotReader {
    static let shared = AILimitsSnapshotReader()

    private let fileURL: URL
    private let cacheFileURL: URL
    private let cloudURL: URL
    private let cloudAnonKey: String

    init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/usage-stats.json"),
        cacheFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/sm-limits/usage-stats.json"),
        cloudURL: URL = URL(
            string: "https://gpagtzpuchrhyrhlyjou.supabase.co/rest/v1/rpc/usage_current")!,
        cloudAnonKey: String = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdwYWd0enB1Y2hyaHlyaGx5am91Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDcyMzg3OTUsImV4cCI6MjA2MjgxNDc5NX0.Ygw7pFOVPgpzoTq_NUoCepCxPOe9nV7V01Bbh0T81-g"
    ) {
        self.fileURL = fileURL
        self.cacheFileURL = cacheFileURL
        self.cloudURL = cloudURL
        self.cloudAnonKey = cloudAnonKey
    }

    func read() -> AILimitsSnapshot? {
        readResult()?.snapshot
    }

    func readResult() -> AILimitsSnapshotResult? {
        if let snapshot = read(fileURL) {
            return AILimitsSnapshotResult(snapshot: snapshot, source: .local)
        }
        if let snapshot = read(cacheFileURL) {
            return AILimitsSnapshotResult(snapshot: snapshot, source: .supabase)
        }
        return nil
    }

    var needsCloudFallback: Bool {
        read(fileURL) == nil
    }

    func fetchCloudSnapshot() async -> AILimitsSnapshot? {
        var request = URLRequest(url: cloudURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue(cloudAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let normalizedData = Self.normalizedCloudData(from: data),
              let snapshot = snapshot(from: normalizedData, fallbackDate: Date())
        else { return nil }

        storeCache(normalizedData)
        return snapshot
    }

    private func read(_ url: URL) -> AILimitsSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // The collector replaces this JSON frequently. A brief retry handles a
        // non-atomic writer without delaying normal menu opening.
        for attempt in 0..<3 {
            if let data = try? Data(contentsOf: url),
               let snapshot = snapshot(from: data, fallbackDate: modificationDate(of: url)) {
                return snapshot
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return nil
    }

    private func snapshot(from data: Data, fallbackDate: Date?) -> AILimitsSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["claude"] is [String: Any] || root["codex"] is [String: Any]
        else { return nil }

        let claude = serviceDictionary(named: "claude", in: root)
        let codex = serviceDictionary(named: "codex", in: root)

        return AILimitsSnapshot(
            claude: claudeSnapshot(from: claude, fallbackDate: fallbackDate),
            codex: codexSnapshot(from: codex, fallbackDate: fallbackDate))
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func storeCache(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            NSLog("AILimitsSnapshotReader: could not cache cloud snapshot: %@", error.localizedDescription)
        }
    }

    static func normalizedCloudData(from data: Data) -> Data? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty
        else { return nil }

        var grouped: [String: [(freshness: TimeInterval, key: String, snapshot: [String: Any])]] = [:]
        for (index, row) in rows.enumerated() {
            guard let service = row["service"] as? String, !service.isEmpty else { continue }
            var snapshot = row["usage"] as? [String: Any] ?? [:]
            if let billing = row["billing"] as? [String: Any] {
                snapshot["account"] = billing
            }
            let key = (row["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "profile_\(index)"
            grouped[service, default: []].append((
                freshness: cloudFreshness(row: row, snapshot: snapshot),
                key: key,
                snapshot: snapshot))
        }

        var root: [String: Any] = [:]
        for (service, entries) in grouped where !entries.isEmpty {
            let sorted = entries.sorted { $0.freshness > $1.freshness }
            var serviceSnapshot = sorted[0].snapshot
            serviceSnapshot["accounts"] = Dictionary(
                uniqueKeysWithValues: sorted.map { ($0.key, $0.snapshot) })
            root[service] = serviceSnapshot
        }

        guard !root.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func cloudFreshness(
        row: [String: Any],
        snapshot: [String: Any]
    ) -> TimeInterval {
        if let value = row["freshest_at"] as? String,
           let date = isoTimestamp(value) {
            return date.timeIntervalSince1970
        }
        if let number = snapshot["ts"] as? NSNumber {
            let value = number.doubleValue
            return value > 10_000_000_000 ? value / 1_000 : value
        }
        if let account = snapshot["account"] as? [String: Any],
           let value = account["scrapedAt"] as? String,
           let date = isoTimestamp(value) {
            return date.timeIntervalSince1970
        }
        return 0
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
            ?? isoDate((dictionary["account"] as? [String: Any])?["scrapedAt"])
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
        return Self.isoTimestamp(value)
    }

    private static func isoTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
