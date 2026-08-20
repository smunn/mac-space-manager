import XCTest
@testable import Space_Manager

final class ProcessHealthMonitorTests: XCTestCase {
    private let scanDate = Date(timeIntervalSince1970: 2_000_000)

    func testDetachedSessionIsCleanableWithUnavailableStandardIO() {
        let safe = makeSession()
        XCTAssertTrue(safe.canCleanUp)
        XCTAssertTrue(makeSession(status: .active).canCleanUp)
        XCTAssertFalse(makeSession(isDetached: false).canCleanUp)
        XCTAssertFalse(makeSession(hasUnavailableStandardIO: false).canCleanUp)
        XCTAssertTrue(makeSession(logPath: nil).canCleanUp)
    }

    func testDetachedClaudeSessionCanBeTerminatedWhenStandardIOIsUnavailable() {
        let session = makeSession(service: .claude, status: .completed)

        XCTAssertTrue(session.isDetached)
        XCTAssertTrue(session.hasUnavailableStandardIO)
        XCTAssertEqual(session.completionStatus, .completed)
        XCTAssertTrue(session.canCleanUp)
    }

    func testSimulatorRecommendationIsSeparateFromManualShutdownSafety() {
        let recent = makeSimulator(isPastWarningThreshold: false)
        XCTAssertTrue(recent.canShutDown)
        XCTAssertFalse(recent.canCleanUp)
        XCTAssertEqual(recent.statusLabels, ["Running"])

        let old = makeSimulator(isPastWarningThreshold: true)
        XCTAssertTrue(old.canCleanUp)
        XCTAssertEqual(old.statusLabels, ["Recommended"])

        let developmentActive = makeSimulator(
            isDevelopmentActive: true,
            isPastWarningThreshold: true)
        XCTAssertFalse(developmentActive.canShutDown)
        XCTAssertFalse(developmentActive.canCleanUp)
        XCTAssertEqual(developmentActive.statusLabels, ["Development active"])
    }

    func testCodexParserRequiresExplicitCompletionAfterLastActivity() throws {
        let completed = try jsonLines([
            ["payload": ["type": "session_meta", "cwd": "/tmp/project", "session_id": "abc"]],
            ["payload": ["type": "user_message", "message": "Fix the issue"]],
            ["payload": ["type": "agent_message", "message": "Fixed it"]],
            ["payload": ["type": "task_complete"]]
        ])
        let context = ProcessHealthSystemProvider.sessionContext(logData: completed, service: .codex)
        XCTAssertEqual(context.status, .completed)
        XCTAssertEqual(context.projectPath, "/tmp/project")
        XCTAssertEqual(context.sessionID, "abc")
        XCTAssertEqual(context.taskSummary, "Fix the issue")
        XCTAssertEqual(context.completionSummary, "Fixed it")
        XCTAssertEqual(context.lastActivitySummary, "Turn completed")

        let resumed = completed + (try jsonLines([
            ["payload": ["type": "user_message", "message": "One more thing"]]
        ]))
        XCTAssertEqual(
            ProcessHealthSystemProvider.sessionContext(logData: resumed, service: .codex).status,
            .active)
    }

    func testClaudeParserRequiresAssistantEndTurnAndRejectsToolActivity() throws {
        let completed = try jsonLines([
            ["type": "user", "message": ["role": "user", "content": "Review this"]],
            ["type": "assistant", "message": [
                "role": "assistant",
                "content": [["type": "text", "text": "Review complete"]],
                "stop_reason": "end_turn"
            ]]
        ])
        let context = ProcessHealthSystemProvider.sessionContext(logData: completed, service: .claude)
        XCTAssertEqual(context.status, .completed)
        XCTAssertEqual(context.taskSummary, "Review this")
        XCTAssertEqual(context.completionSummary, "Review complete")

        let toolUse = try jsonLines([
            ["type": "assistant", "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "name": "Read"]],
                "stop_reason": "tool_use"
            ]]
        ])
        XCTAssertNotEqual(
            ProcessHealthSystemProvider.sessionContext(logData: toolUse, service: .claude).status,
            .completed)

        let resumedWithTool = completed + toolUse
        XCTAssertNotEqual(
            ProcessHealthSystemProvider.sessionContext(logData: resumedWithTool, service: .claude).status,
            .completed)
    }

    func testCodexParserReportsCurrentToolActivity() throws {
        let activity = try jsonLines([
            [
                "timestamp": "2026-08-14T02:53:24.381Z",
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call",
                    "name": "exec",
                    "input": "await tools.exec_command({cmd:\"npm test\"})"
                ]
            ]
        ])
        let context = ProcessHealthSystemProvider.sessionContext(logData: activity, service: .codex)

        XCTAssertEqual(
            context.lastActivitySummary,
            "Running exec: await tools.exec_command({cmd:\"npm test\"})")
        XCTAssertNotNil(context.lastActivityAt)
        XCTAssertEqual(context.status, .active)
    }

    func testRefreshUsesSixtySecondCacheUnlessForced() {
        let system = FakeProcessHealthSystem()
        let clock = TestClock(date: scanDate)
        let callbackQueue = DispatchQueue(label: "ProcessHealthMonitorTests.callback")
        let monitor = ProcessHealthMonitor(
            cacheInterval: 60,
            callbackQueue: callbackQueue,
            now: { clock.date },
            system: system)

        waitForRefresh(monitor)
        clock.date = scanDate.addingTimeInterval(59)
        waitForRefresh(monitor)
        XCTAssertEqual(system.scanCount, 1)
        XCTAssertFalse(system.scanWasOnMainThread)

        waitForRefresh(monitor, force: true)
        XCTAssertEqual(system.scanCount, 2)

        clock.date = scanDate.addingTimeInterval(120)
        waitForRefresh(monitor)
        XCTAssertEqual(system.scanCount, 3)
    }

    func testSimulatorWarningsAreSuppressedDuringBuildTestAndPreviewWork() {
        XCTAssertTrue(ProcessHealthSystemProvider.shouldSuppressSimulatorWarnings(
            processCommands: ["/usr/bin/xcodebuild test -scheme App"]))
        XCTAssertTrue(ProcessHealthSystemProvider.shouldSuppressSimulatorWarnings(
            processCommands: ["/Applications/Xcode.app/Contents/Developer/usr/bin/xctest AppTests"]))
        XCTAssertTrue(ProcessHealthSystemProvider.shouldSuppressSimulatorWarnings(
            processCommands: ["/Applications/Xcode.app/Contents/Developer/PreviewsAgent"] ))
        XCTAssertFalse(ProcessHealthSystemProvider.shouldSuppressSimulatorWarnings(
            processCommands: ["/Applications/Simulator.app/Contents/MacOS/Simulator"] ))
    }

    func testSimulatorThresholdUsesPositiveUserDefaultOrSafeDefault() {
        let suiteName = "ProcessHealthMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            ProcessHealthSystemProvider.configuredSimulatorWarningThreshold(userDefaults: defaults),
            60 * 60)
        defaults.set(30, forKey: ProcessHealthSystemProvider.simulatorThresholdDefaultsKey)
        XCTAssertEqual(
            ProcessHealthSystemProvider.configuredSimulatorWarningThreshold(userDefaults: defaults),
            30 * 60)
        defaults.set(-1, forKey: ProcessHealthSystemProvider.simulatorThresholdDefaultsKey)
        XCTAssertEqual(
            ProcessHealthSystemProvider.configuredSimulatorWarningThreshold(userDefaults: defaults),
            60 * 60)
    }

    func testProcessCPUTimeParserSupportsMacOSFormats() {
        XCTAssertEqual(ProcessHealthSystemProvider.parseProcessTime("04:02.48")!, 242.48, accuracy: 0.001)
        XCTAssertEqual(ProcessHealthSystemProvider.parseProcessTime("13:38:43.78")!, 49_123.78, accuracy: 0.001)
        XCTAssertEqual(ProcessHealthSystemProvider.parseProcessTime("2-01:02:03.50")!, 176_523.5, accuracy: 0.001)
        XCTAssertNil(ProcessHealthSystemProvider.parseProcessTime("bad"))
    }

    func testAIProcessDetectionIncludesPrimaryProcessesWithoutCountingCodexHelpersOrWrappers() {
        XCTAssertEqual(ProcessHealthSystemProvider.aiService(
            command: "/opt/openai/bin/codex --full-auto"), .codex)
        XCTAssertNil(ProcessHealthSystemProvider.aiService(
            command: "/opt/openai/bin/codex-code-mode-host"))
        XCTAssertNil(ProcessHealthSystemProvider.aiService(
            command: "node /opt/homebrew/bin/codex"))
        XCTAssertEqual(ProcessHealthSystemProvider.aiService(
            command: "/opt/anthropic/bin/claude"), .claude)
        XCTAssertEqual(ProcessHealthSystemProvider.aiService(
            command: "node /opt/node_modules/@anthropic-ai/claude-code/cli.js"), .claude)
        XCTAssertEqual(ProcessHealthSystemProvider.aiService(
            command: "/Users/scott/.local/share/claude/versions/2.1.235 --model fable"), .claude)
        XCTAssertNil(ProcessHealthSystemProvider.aiService(
            command: "/Users/scott/.local/share/claude/versions/2.1.235 --chrome-native-host"))
    }

    func testCodexSessionIDUsesCompleteUUIDFromRolloutFilename() {
        XCTAssertEqual(
            ProcessHealthSystemProvider.sessionID(
                from: "/tmp/rollout-2026-08-13T14-50-47-019ffcad-5bdc-7902-8a78-38a13d25f51e.jsonl"),
            "019ffcad-5bdc-7902-8a78-38a13d25f51e")
    }

    func testRepositoryNameFindsNearestGitAncestor() {
        let gitPaths = Set(["/Users/scott/Sites/mac-space-manager/.git"])
        XCTAssertEqual(
            ProcessHealthSystemProvider.repositoryName(
                forProjectPath: "/Users/scott/Sites/mac-space-manager/SpaceManager/Views",
                hasGitMetadata: { gitPaths.contains($0) }),
            "mac-space-manager")
        XCTAssertNil(ProcessHealthSystemProvider.repositoryName(
            forProjectPath: "/Users/scott/Downloads",
            hasGitMetadata: { _ in false }))
    }

    func testProcessStartTextUsesPreferredWeekdayDateAndTimeFormat() {
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = utc
        let started = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 3, hour: 14, minute: 30))!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 3, hour: 15, minute: 30))!

        XCTAssertEqual(
            processStartText(started, now: now, calendar: calendar, timeZone: utc),
            "M 8-3 · 2:30 pm")
    }

    func testBuildInfoUsesReleaseVersionAndChicagoTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        let chicago = TimeZone(identifier: "America/Chicago")!
        calendar.timeZone = chicago
        let buildDate = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 23, minute: 0, second: 0))!

        XCTAssertEqual(
            AppBuildInfo.dateText(buildDate, timeZone: chicago),
            "2026.08.04.23.00.00")
        XCTAssertEqual(
            AppBuildInfo(releaseVersion: "0.1.2", buildDate: buildDate).menuLabel,
            "v0.1.2 · 2026.08.04.23.00.00")
    }

    func testDeveloperDirectoryPrefersEnvironmentThenValidSelectedXcodeThenApplications() {
        let valid = Set(["/environment", "/selected", "/fallback"])
        let hasSimctl: (String) -> Bool = { valid.contains($0) }

        XCTAssertEqual(ProcessHealthSystemProvider.developerDirectory(
            environment: ["DEVELOPER_DIR": "/environment"],
            selectedDirectory: "/selected",
            applicationDirectories: ["/fallback"],
            hasSimctl: hasSimctl), "/environment")
        XCTAssertEqual(ProcessHealthSystemProvider.developerDirectory(
            environment: ["DEVELOPER_DIR": "/command-line-tools"],
            selectedDirectory: "/selected",
            applicationDirectories: ["/fallback"],
            hasSimctl: hasSimctl), "/selected")
        XCTAssertEqual(ProcessHealthSystemProvider.developerDirectory(
            environment: [:],
            selectedDirectory: "/command-line-tools",
            applicationDirectories: ["/fallback"],
            hasSimctl: hasSimctl), "/fallback")
    }

    func testCleanupRevalidatesBeforeTerminating() {
        let system = FakeProcessHealthSystem()
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)
        let session = makeSession()

        system.aiSessionSafe = false
        XCTAssertFalse(waitForAction { monitor.cleanUp(session, completion: $0) })
        XCTAssertEqual(system.terminatedPIDs, [])

        system.aiSessionSafe = true
        XCTAssertTrue(waitForAction { monitor.cleanUp(session, completion: $0) })
        XCTAssertEqual(system.terminatedPIDs, [session.processID])
    }

    func testDirectTerminationAllowsNonRecommendedSessionAfterRevalidation() {
        let system = FakeProcessHealthSystem()
        system.aiSessionSafe = true
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)
        let session = makeSession(isDetached: false)

        XCTAssertFalse(session.canCleanUp)
        XCTAssertTrue(waitForAction { monitor.cleanUp(session, completion: $0) })
        XCTAssertEqual(system.terminatedPIDs, [session.processID])
    }

    func testBatchCleanupSkipsNonRecommendedSession() {
        let system = FakeProcessHealthSystem()
        system.aiSessionSafe = true
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)
        let expectation = expectation(description: "batch cleanup")
        let result = BatchActionResult()

        monitor.cleanUp([makeSession(isDetached: false)]) {
            result.value = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(result.value, 0)
        XCTAssertEqual(system.aiRevalidationCount, 0)
        XCTAssertEqual(system.terminatedPIDs, [])
    }

    func testBatchCleanupReturnsSuccessfulTerminationCount() {
        let system = FakeProcessHealthSystem()
        system.aiSessionSafe = true
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)
        let sessions = [makeSession(), makeSession(service: .claude)]
        let expectation = expectation(description: "batch cleanup")
        let result = BatchActionResult()

        monitor.cleanUp(sessions) {
            result.value = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(result.value, 2)
        XCTAssertEqual(system.terminatedPIDs, [123, 123])
    }

    func testDetachedSessionWithoutLogCompletionStillRevalidatesBeforeTermination() {
        let system = FakeProcessHealthSystem()
        system.aiSessionSafe = true
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)

        XCTAssertTrue(waitForAction {
            monitor.cleanUp(self.makeSession(status: .uncertain), completion: $0)
        })
        XCTAssertEqual(system.aiRevalidationCount, 1)
        XCTAssertEqual(system.terminatedPIDs, [123])
    }

    func testSimulatorShutdownRevalidatesBeforeAction() {
        let system = FakeProcessHealthSystem()
        let monitor = ProcessHealthMonitor(callbackQueue: .main, now: { self.scanDate }, system: system)
        let simulator = makeSimulator(isPastWarningThreshold: true)

        system.simulatorSafe = false
        XCTAssertFalse(waitForAction { monitor.shutDown(simulator, completion: $0) })
        XCTAssertEqual(system.shutdownUUIDs, [])

        system.simulatorSafe = true
        XCTAssertTrue(waitForAction { monitor.shutDown(simulator, completion: $0) })
        XCTAssertEqual(system.shutdownUUIDs, [simulator.deviceUUID])
    }

    private func makeSession(
        service: AISessionService = .codex,
        status: AISessionCompletionStatus = .completed,
        isDetached: Bool = true,
        hasUnavailableStandardIO: Bool = true,
        logPath: String? = "/tmp/codex/session.jsonl"
    ) -> AISessionHealthItem {
        AISessionHealthItem(
            service: service,
            processID: 123,
            parentProcessID: 122,
            processStartedAt: scanDate.addingTimeInterval(-300),
            projectPath: "/tmp/project",
            repositoryName: nil,
            sessionID: "session-1",
            sessionLogPath: logPath,
            elapsedTime: 300,
            cpuTime: 30,
            cpuUsagePercent: 5,
            command: "/usr/local/bin/codex",
            taskSummary: "Fix issue",
            completionSummary: "Done",
            lastActivityAt: scanDate.addingTimeInterval(-10),
            lastActivitySummary: "Running exec: npm test",
            completionStatus: status,
            isDetached: isDetached,
            hasUnavailableStandardIO: hasUnavailableStandardIO)
    }

    private func makeSimulator(
        isActivelyUsed: Bool = false,
        isDevelopmentActive: Bool = false,
        isPastWarningThreshold: Bool = false
    ) -> SimulatorHealthItem {
        SimulatorHealthItem(
            deviceName: "iPhone 17 Pro",
            runtimeName: "iOS 26 0",
            deviceUUID: UUID(),
            bootedAt: scanDate.addingTimeInterval(-7_200),
            scannedAt: scanDate,
            isActivelyUsed: isActivelyUsed,
            isDevelopmentActive: isDevelopmentActive,
            isPastWarningThreshold: isPastWarningThreshold)
    }

    private func jsonLines(_ objects: [[String: Any]]) throws -> Data {
        try objects.map { object in
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }.joined(separator: "\n").data(using: .utf8)!
    }

    private func waitForRefresh(_ monitor: ProcessHealthMonitor, force: Bool = false) {
        let expectation = expectation(description: "refresh")
        monitor.refreshIfNeeded(force: force) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func waitForAction(_ action: (@escaping ProcessHealthMonitor.ActionCompletion) -> Void) -> Bool {
        let expectation = expectation(description: "action")
        let result = ActionResult()
        action {
            result.value = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        return result.value
    }
}

private final class TestClock: @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
}

private final class ActionResult: @unchecked Sendable {
    var value = false
}

private final class BatchActionResult: @unchecked Sendable {
    var value = 0
}

private final class FakeProcessHealthSystem: ProcessHealthSystemProviding {
    var scanCount = 0
    var scanWasOnMainThread = true
    var aiSessionSafe = false
    var simulatorSafe = false
    var aiRevalidationCount = 0
    var terminatedPIDs: [pid_t] = []
    var shutdownUUIDs: [UUID] = []

    func scan(at date: Date) -> ProcessHealthSnapshot {
        scanCount += 1
        scanWasOnMainThread = Thread.isMainThread
        return ProcessHealthSnapshot(simulators: [], aiSessions: [], scannedAt: date)
    }

    func simulatorIsSafeToShutdown(_ item: SimulatorHealthItem, at date: Date) -> Bool {
        simulatorSafe
    }

    func shutDownSimulator(uuid: UUID) -> Bool {
        shutdownUUIDs.append(uuid)
        return true
    }

    func aiSessionIsCurrent(_ item: AISessionHealthItem, at date: Date) -> Bool {
        aiRevalidationCount += 1
        return aiSessionSafe
    }

    func terminateProcess(pid: pid_t) -> Bool {
        terminatedPIDs.append(pid)
        return true
    }

    func reviewSimulator(_ simulator: SimulatorHealthItem) -> Bool { false }
}
