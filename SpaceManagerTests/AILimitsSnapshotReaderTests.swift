//
//  AILimitsSnapshotReaderTests.swift
//  SpaceManagerTests
//

import XCTest
@testable import Space_Manager

final class AILimitsSnapshotReaderTests: XCTestCase {
    func testFormatsResetTimesInChicagoTime() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-08-13T17:00:00-05:00"))
        let today = try XCTUnwrap(formatter.date(from: "2026-08-13T20:30:00-05:00"))
        let tomorrow = try XCTUnwrap(formatter.date(from: "2026-08-14T20:30:00-05:00"))
        let later = try XCTUnwrap(formatter.date(from: "2026-08-15T20:30:00-05:00"))

        XCTAssertEqual(AILimitsResetFormatter.compact(today, now: now), "8:30 PM")
        XCTAssertEqual(AILimitsResetFormatter.compact(tomorrow, now: now), "Tomorrow 8:30 PM")
        XCTAssertEqual(AILimitsResetFormatter.compact(later, now: now), "Sat 8:30 PM")
    }

    func testReadsClaudeAndCodexLimitsFromSharedSnapshot() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(#"""
        {
          "claude": {
            "session": 52,
            "sessionResetEpoch": 4102444800000,
            "weeklyAll": 61,
            "weeklyAllResetEpoch": 4102448400000,
            "metrics": [{"key":"fable","pctUsed":92,"resetEpoch":4102452000000}],
            "ts": 4102400000000
          },
          "codex": {
            "limits": [
              {"label":"5 hour usage limit","pctUsed":22,"resetEpoch":4102444800000},
              {"label":"Weekly usage limit","pctUsed":10,"resetEpoch":4102448400000},
              {"label":"GPT-5.3-Codex-Spark Weekly usage limit","pctUsed":99}
            ],
            "ts": 4102401000000
          }
        }
        """#.utf8).write(to: fileURL)

        let snapshot = try XCTUnwrap(AILimitsSnapshotReader(fileURL: fileURL).read())

        XCTAssertEqual(snapshot.claude.fiveHour.percentUsed, 52)
        XCTAssertEqual(snapshot.claude.weekly.percentUsed, 61)
        XCTAssertEqual(snapshot.claude.fable?.percentUsed, 92)
        XCTAssertEqual(snapshot.codex.fiveHour.percentUsed, 22)
        XCTAssertEqual(snapshot.codex.weekly.percentUsed, 10)
        XCTAssertEqual(snapshot.claude.collectedAt?.timeIntervalSince1970, 4_102_400_000)
    }

    func testFallsBackToFreshestAccountAndSupportsSecondsEpochs() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data(#"""
        {
          "codex": {
            "accounts": {
              "old@example.com": {"ts":100,"limits":[{"label":"Weekly usage limit","pctUsed":3}]},
              "new@example.com": {"ts":200,"limits":[{"windowMinutes":10080,"limitName":null,"usedPercent":47,"resetsAt":300}]}
            }
          }
        }
        """#.utf8).write(to: fileURL)

        let snapshot = try XCTUnwrap(AILimitsSnapshotReader(fileURL: fileURL).read())

        XCTAssertEqual(snapshot.codex.weekly.percentUsed, 47)
        XCTAssertEqual(snapshot.codex.weekly.resetsAt?.timeIntervalSince1970, 300)
        XCTAssertEqual(snapshot.codex.collectedAt?.timeIntervalSince1970, 200)
    }
}
