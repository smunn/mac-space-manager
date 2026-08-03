//
//  ProcessHealthMonitor.swift
//  SpaceManager
//
//  Process and simulator discovery is intentionally kept off the main thread
//  and cached. Cleanup repeats every safety check immediately before acting so
//  stale menu state can never terminate a reused PID or an active process.
//

import AppKit
import Darwin
import Foundation

protocol ProcessHealthSystemProviding: AnyObject {
    func scan(at date: Date) -> ProcessHealthSnapshot
    func simulatorIsSafeToShutdown(_ item: SimulatorHealthItem, at date: Date) -> Bool
    func shutDownSimulator(uuid: UUID) -> Bool
    func aiSessionIsSafeToCleanUp(_ item: AISessionHealthItem, at date: Date) -> Bool
    func terminateProcess(pid: pid_t) -> Bool
    func reviewSimulator(_ simulator: SimulatorHealthItem) -> Bool
    func reviewURL(for session: AISessionHealthItem) -> URL?
}

final class ProcessHealthMonitor: @unchecked Sendable {
    typealias Completion = @Sendable (ProcessHealthSnapshot) -> Void
    typealias ActionCompletion = @Sendable (Bool) -> Void
    typealias BatchActionCompletion = @Sendable (Int) -> Void

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let cacheInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let system: ProcessHealthSystemProviding
    private var cachedSnapshot: ProcessHealthSnapshot?
    private var refreshCompletions: [Completion] = []
    private var refreshInProgress = false

    init(
        cacheInterval: TimeInterval = 60,
        queue: DispatchQueue = DispatchQueue(
            label: "com.smunn.SpaceManager.process-health",
            qos: .utility),
        callbackQueue: DispatchQueue = .main,
        now: @escaping @Sendable () -> Date = { Date() },
        system: ProcessHealthSystemProviding = ProcessHealthSystemProvider()
    ) {
        self.cacheInterval = cacheInterval
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.now = now
        self.system = system
    }

    func refreshIfNeeded(force: Bool = false, completion: @escaping Completion) {
        queue.async {
            let date = self.now()
            if !force,
               let cached = self.cachedSnapshot,
               date.timeIntervalSince(cached.scannedAt) < self.cacheInterval
            {
                self.callbackQueue.async { completion(cached) }
                return
            }

            self.refreshCompletions.append(completion)
            guard !self.refreshInProgress else { return }
            self.refreshInProgress = true

            let snapshot = self.system.scan(at: date)
            self.cachedSnapshot = snapshot
            self.refreshInProgress = false
            let completions = self.refreshCompletions
            self.refreshCompletions.removeAll()
            self.callbackQueue.async {
                completions.forEach { $0(snapshot) }
            }
        }
    }

    func review(_ simulator: SimulatorHealthItem, completion: ActionCompletion? = nil) {
        callbackQueue.async {
            completion?(self.system.reviewSimulator(simulator))
        }
    }

    func review(_ session: AISessionHealthItem, completion: ActionCompletion? = nil) {
        callbackQueue.async {
            guard let url = self.system.reviewURL(for: session) else {
                completion?(false)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            completion?(true)
        }
    }

    func shutDown(_ simulator: SimulatorHealthItem, completion: @escaping ActionCompletion) {
        queue.async {
            let success = self.system.simulatorIsSafeToShutdown(simulator, at: self.now())
                && self.system.shutDownSimulator(uuid: simulator.deviceUUID)
            if success { self.cachedSnapshot = nil }
            self.callbackQueue.async { completion(success) }
        }
    }

    func cleanUp(_ session: AISessionHealthItem, completion: @escaping ActionCompletion) {
        queue.async {
            let success = self.cleanUpIsSuccessful(session)
            if success { self.cachedSnapshot = nil }
            self.callbackQueue.async { completion(success) }
        }
    }

    func cleanUp(
        _ sessions: [AISessionHealthItem],
        completion: @escaping BatchActionCompletion
    ) {
        queue.async {
            var successCount = 0
            for session in sessions where self.cleanUpIsSuccessful(session) {
                successCount += 1
            }
            if successCount > 0 { self.cachedSnapshot = nil }
            self.callbackQueue.async { completion(successCount) }
        }
    }

    private func cleanUpIsSuccessful(_ session: AISessionHealthItem) -> Bool {
        // Do not even revalidate an item the original scan considered unsafe.
        session.canCleanUp
            && system.aiSessionIsSafeToCleanUp(session, at: now())
            && system.terminateProcess(pid: session.processID)
    }

}

final class ProcessHealthSystemProvider: ProcessHealthSystemProviding {
    static let simulatorThresholdDefaultsKey = "processHealthSimulatorThresholdMinutes"

    private struct ProcessRecord {
        let pid: pid_t
        let parentPID: pid_t
        let tty: String
        let startedAt: Date
        let cpuUsagePercent: Double
        let cpuTime: TimeInterval
        let command: String
    }

    private struct StandardIOState {
        let unavailable: Bool
        let openFiles: [String]
    }

    private let fileManager: FileManager
    private let simulatorWarningThreshold: TimeInterval

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        simulatorWarningThreshold: TimeInterval? = nil
    ) {
        self.fileManager = fileManager
        self.simulatorWarningThreshold = simulatorWarningThreshold.flatMap { $0 > 0 ? $0 : nil }
            ?? Self.configuredSimulatorWarningThreshold(userDefaults: userDefaults)
    }

    func scan(at date: Date) -> ProcessHealthSnapshot {
        let processes = processRecords()
        return ProcessHealthSnapshot(
            simulators: scanSimulators(at: date, processes: processes),
            aiSessions: scanAISessions(at: date, processes: processes),
            scannedAt: date)
    }

    func simulatorIsSafeToShutdown(_ item: SimulatorHealthItem, at date: Date) -> Bool {
        guard item.canCleanUp else { return false }
        return scan(at: date).simulators.contains {
            $0.deviceUUID == item.deviceUUID && $0.canCleanUp && $0.bootedAt == item.bootedAt
        }
    }

    func shutDownSimulator(uuid: UUID) -> Bool {
        runSimctl(["shutdown", uuid.uuidString]).status == 0
    }

    func aiSessionIsSafeToCleanUp(_ item: AISessionHealthItem, at date: Date) -> Bool {
        guard item.canCleanUp else { return false }
        return scanAISessions(at: date, processes: processRecords()).contains {
            $0.processID == item.processID
                && abs($0.processStartedAt.timeIntervalSince(item.processStartedAt)) < 1
                && $0.service == item.service
                && $0.sessionLogPath == item.sessionLogPath
                && $0.canCleanUp
        }
    }

    func terminateProcess(pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        guard kill(pid, SIGTERM) == 0 else { return false }
        if waitForProcessExit(pid: pid, attempts: 15) { return true }

        // These processes have already passed the detached/revoked-I/O safety
        // checks. Escalate only when a graceful termination did not finish.
        guard kill(pid, SIGKILL) == 0 else { return false }
        return waitForProcessExit(pid: pid, attempts: 10)
    }

    private func waitForProcessExit(pid: pid_t, attempts: Int) -> Bool {
        for _ in 0..<attempts {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(100_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    func reviewSimulator(_ simulator: SimulatorHealthItem) -> Bool {
        guard let developerDirectory = resolvedDeveloperDirectory() else { return false }
        let simulatorURL = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Applications/Simulator.app", isDirectory: true)
        guard fileManager.fileExists(atPath: simulatorURL.path) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = ["-CurrentDeviceUDID", simulator.deviceUUID.uuidString]
        NSWorkspace.shared.openApplication(at: simulatorURL, configuration: configuration) { _, _ in }
        return true
    }

    func reviewURL(for session: AISessionHealthItem) -> URL? {
        if let projectPath = session.projectPath, fileManager.fileExists(atPath: projectPath) {
            return URL(fileURLWithPath: projectPath, isDirectory: true)
        }
        if let logPath = session.sessionLogPath, fileManager.fileExists(atPath: logPath) {
            return URL(fileURLWithPath: logPath)
        }
        return nil
    }

    private func scanSimulators(at date: Date, processes: [ProcessRecord]) -> [SimulatorHealthItem] {
        // Builds/tests/previews can legitimately leave a simulator busy without
        // a visible window, so suppress the entire warning class while present.
        let developmentIsActive = Self.shouldSuppressSimulatorWarnings(
            processCommands: processes.map(\.command))

        guard !developmentIsActive else { return [] }
        let result = runSimctl(["list", "devices", "booted", "--json"])
        guard result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let devicesByRuntime = object["devices"] as? [String: [[String: Any]]]
        else { return [] }

        let simulatorIsFrontmost = frontmostBundleIdentifier() == "com.apple.iphonesimulator"
        var items: [SimulatorHealthItem] = []
        for (runtimeIdentifier, devices) in devicesByRuntime {
            for device in devices where (device["state"] as? String) == "Booted" {
                guard let uuidText = device["udid"] as? String,
                      let uuid = UUID(uuidString: uuidText),
                      let name = device["name"] as? String,
                      let bootedAt = simulatorBootDate(uuid: uuid)
                else { continue }

                let duration = date.timeIntervalSince(bootedAt)
                guard duration >= simulatorWarningThreshold else { continue }
                items.append(SimulatorHealthItem(
                    deviceName: name,
                    runtimeName: Self.runtimeDisplayName(runtimeIdentifier),
                    deviceUUID: uuid,
                    bootedAt: bootedAt,
                    scannedAt: date,
                    isActivelyUsed: simulatorIsFrontmost))
            }
        }
        return items.sorted { $0.bootDuration > $1.bootDuration }
    }

    private func scanAISessions(at date: Date, processes: [ProcessRecord]) -> [AISessionHealthItem] {
        let processesByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return processes.compactMap { process in
            guard let service = Self.aiService(command: process.command) else { return nil }

            let io = standardIOState(pid: process.pid)
            let logPath = Self.sessionLogPath(in: io.openFiles, service: service)
                ?? Self.sessionLogPath(in: Self.paths(in: process.command), service: service)
            let context = logPath.map { Self.sessionContext(logPath: $0, service: service) }
                ?? SessionContext(
                    projectPath: nil,
                    sessionID: nil,
                    taskSummary: nil,
                    completionSummary: nil,
                    status: .uncertain)
            let hasNoTTY = Self.ttyIsUnavailable(process.tty)
            let parent = processesByPID[process.parentPID]
            let isDetached = hasNoTTY && (process.parentPID == 1 || parent?.parentPID == 1)
            return AISessionHealthItem(
                service: service,
                processID: process.pid,
                processStartedAt: process.startedAt,
                projectPath: processCWD(pid: process.pid) ?? context.projectPath,
                sessionID: context.sessionID ?? logPath.flatMap(Self.sessionID(from:)),
                sessionLogPath: logPath,
                elapsedTime: max(0, date.timeIntervalSince(process.startedAt)),
                cpuTime: process.cpuTime,
                cpuUsagePercent: process.cpuUsagePercent,
                command: process.command,
                taskSummary: context.taskSummary,
                completionSummary: context.completionSummary,
                completionStatus: context.status,
                isDetached: isDetached,
                hasUnavailableStandardIO: io.unavailable)
        }.sorted {
            if $0.isDetached != $1.isDetached { return $0.isDetached }
            if $0.isHighCPU != $1.isHighCPU { return $0.isHighCPU }
            return $0.elapsedTime > $1.elapsedTime
        }
    }

    private func processRecords() -> [ProcessRecord] {
        let result = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,lstart=,%cpu=,time=,command="])
        guard result.status == 0, let text = String(data: result.output, encoding: .utf8) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 10, whereSeparator: \.isWhitespace)
            guard fields.count == 11,
                  let pid = pid_t(fields[0]),
                  let parentPID = pid_t(fields[1]),
                  let startedAt = formatter.date(from: fields[3...7].joined(separator: " ")),
                  let cpuUsagePercent = Double(fields[8]),
                  let cpuTime = Self.parseProcessTime(String(fields[9]))
            else { return nil }
            return ProcessRecord(
                pid: pid,
                parentPID: parentPID,
                tty: String(fields[2]),
                startedAt: startedAt,
                cpuUsagePercent: cpuUsagePercent,
                cpuTime: cpuTime,
                command: String(fields[10]))
        }
    }

    private func standardIOState(pid: pid_t) -> StandardIOState {
        let result = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "0,1,2", "-Fn"])
        let text = String(data: result.output, encoding: .utf8) ?? ""
        let paths = text.split(separator: "\n").filter { $0.first == "n" }.map { String($0.dropFirst()) }
        let unavailable = result.status != 0 || paths.isEmpty || paths.allSatisfy {
            $0 == "/dev/null" || $0.contains("revoked") || $0 == "(revoked)"
        }

        let allFiles = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-Fn"])
        let allText = String(data: allFiles.output, encoding: .utf8) ?? ""
        return StandardIOState(
            unavailable: unavailable,
            openFiles: allText.split(separator: "\n").filter { $0.first == "n" }.map { String($0.dropFirst()) })
    }

    private func processCWD(pid: pid_t) -> String? {
        let result = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        let text = String(data: result.output, encoding: .utf8) ?? ""
        return text.split(separator: "\n").first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }

    private func simulatorBootDate(uuid: UUID) -> Date? {
        // CoreSimulator creates this bootstrap file during each boot. Unlike the
        // surrounding run directory, its timestamp remains stable while booted.
        let devicePath = NSHomeDirectory()
            + "/Library/Developer/CoreSimulator/Devices/\(uuid.uuidString)/data/var/run/launchd_bootstrap.plist"
        guard let attributes = try? fileManager.attributesOfItem(atPath: devicePath) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private func frontmostBundleIdentifier() -> String? {
        let front = run("/usr/bin/lsappinfo", ["front"])
        guard front.status == 0,
              let asn = String(data: front.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !asn.isEmpty
        else { return nil }
        let info = run("/usr/bin/lsappinfo", ["info", "-only", "bundleID", asn])
        let text = String(data: info.output, encoding: .utf8) ?? ""
        return text.split(separator: "\"").dropFirst().first.map(String.init)
    }

    private func runSimctl(_ arguments: [String]) -> (status: Int32, output: Data) {
        guard let developerDirectory = resolvedDeveloperDirectory() else { return (-1, Data()) }
        return run(
            "/usr/bin/xcrun",
            ["simctl"] + arguments,
            environment: ["DEVELOPER_DIR": developerDirectory])
    }

    private func resolvedDeveloperDirectory() -> String? {
        let selectedResult = run("/usr/bin/xcode-select", ["-p"])
        let selectedDirectory = selectedResult.status == 0
            ? String(data: selectedResult.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return Self.developerDirectory(
            environment: ProcessInfo.processInfo.environment,
            selectedDirectory: selectedDirectory,
            applicationDirectories: [
                "/Applications/Xcode.app/Contents/Developer",
                "/Applications/Xcode-beta.app/Contents/Developer"
            ],
            hasSimctl: { [fileManager] directory in
                fileManager.isExecutableFile(atPath: directory + "/usr/bin/simctl")
            })
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (-1, Data())
        }
    }

    static func aiService(command: String) -> AISessionService? {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        if name == "codex" { return .codex }
        if name == "claude" { return .claude }
        let lowerCommand = command.lowercased()
        if name == "node"
            && (lowerCommand.contains("/@anthropic-ai/claude-code/")
                || lowerCommand.contains("/bin/claude"))
        {
            return .claude
        }
        return nil
    }

    static func parseProcessTime(_ value: String) -> TimeInterval? {
        let dayParts = value.split(separator: "-", maxSplits: 1)
        let days: Int
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsedDays = Int(dayParts[0]) else { return nil }
            days = parsedDays
            clock = dayParts[1]
        } else {
            days = 0
            clock = dayParts[0]
        }

        let components = clock.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last!)
        else { return nil }
        let minutesIndex = components.count - 2
        guard let minutes = Double(components[minutesIndex]) else { return nil }
        let hours = components.count == 3 ? Double(components[0]) ?? -1 : 0
        guard hours >= 0 else { return nil }
        return Double(days) * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    private static func ttyIsUnavailable(_ tty: String) -> Bool {
        tty == "??" || tty == "?" || tty == "-"
    }

    private static func paths(in command: String) -> [String] {
        command.split(separator: " ").map(String.init).filter { $0.hasPrefix("/") }
    }

    private static func sessionLogPath(in paths: [String], service: AISessionService) -> String? {
        paths.first { path in
            let lower = path.lowercased()
            guard lower.hasSuffix(".jsonl") || lower.hasSuffix(".json") else { return false }
            return service == .codex ? lower.contains("codex") : lower.contains("claude")
        }
    }

    private static func sessionID(from path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let matches = name.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return matches.last.map(String.init)
    }

    struct SessionContext: Equatable {
        let projectPath: String?
        let sessionID: String?
        let taskSummary: String?
        let completionSummary: String?
        let status: AISessionCompletionStatus
    }

    static func sessionContext(logData: Data, service: AISessionService) -> SessionContext {
        let text = String(data: logData, encoding: .utf8) ?? ""
        let objects = text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        var projectPath: String?
        var sessionID: String?
        var lastUser: String?
        var lastAssistant: String?
        var completion = false
        var activityAfterCompletion = false

        for object in objects {
            let payload = object["payload"] as? [String: Any] ?? object
            let nestedMessage = payload["message"] as? [String: Any]
            projectPath = (payload["cwd"] as? String) ?? projectPath
            sessionID = (payload["session_id"] as? String) ?? (payload["sessionId"] as? String) ?? sessionID
            let type = ((payload["type"] as? String) ?? (object["type"] as? String) ?? "").lowercased()
            let role = ((payload["role"] as? String) ?? (nestedMessage?["role"] as? String))?.lowercased()
            let message = textualContent(
                nestedMessage?["content"] ?? payload["content"] ?? payload["message"] ?? payload["text"])
            let nestedContent = nestedMessage?["content"] as? [[String: Any]]
            let containsToolActivity = nestedContent?.contains {
                let contentType = ($0["type"] as? String)?.lowercased()
                return contentType == "tool_use" || contentType == "tool_result"
            } ?? false

            if role == "user" || type == "user" || type == "user_message" {
                lastUser = message ?? lastUser
                if completion { activityAfterCompletion = true }
            }
            if role == "assistant" || type == "assistant" || type == "agent_message" {
                lastAssistant = message ?? lastAssistant
            }

            let explicitCodexCompletion = service == .codex
                && ["task_complete", "turn.completed", "turn_completed"].contains(type)
            let explicitClaudeCompletion = service == .claude
                && role == "assistant"
                && ((payload["stop_reason"] as? String) ?? (nestedMessage?["stop_reason"] as? String)) == "end_turn"
                && !(message?.isEmpty ?? true)
            if explicitCodexCompletion || explicitClaudeCompletion {
                completion = true
            }
            if containsToolActivity
                || type == "tool_use"
                || type == "tool_result"
                || type == "turn.started"
                || type == "turn_started"
            {
                if completion { activityAfterCompletion = true }
                completion = false
            }
        }

        return SessionContext(
            projectPath: projectPath,
            sessionID: sessionID,
            taskSummary: lastUser.map(shortSummary),
            completionSummary: lastAssistant.map(shortSummary),
            status: completion && !activityAfterCompletion ? .completed : (objects.isEmpty ? .uncertain : .active))
    }

    private static func sessionContext(logPath: String, service: AISessionService) -> SessionContext {
        guard let handle = FileHandle(forReadingAtPath: logPath) else {
            return SessionContext(
                projectPath: nil,
                sessionID: nil,
                taskSummary: nil,
                completionSummary: nil,
                status: .uncertain)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailSize = min(size, 512 * 1_024)
        try? handle.seek(toOffset: size - tailSize)
        return sessionContext(logData: handle.readDataToEndOfFile(), service: service)
    }

    private static func textualContent(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let dictionary = value as? [String: Any] {
            return textualContent(dictionary["text"] ?? dictionary["content"])
        }
        if let array = value as? [[String: Any]] {
            let text = array.compactMap { textualContent($0) }.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func shortSummary(_ text: String) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.count > 180 ? String(compact.prefix(177)) + "..." : compact
    }

    private static func runtimeDisplayName(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func configuredSimulatorWarningThreshold(userDefaults: UserDefaults) -> TimeInterval {
        let minutes = userDefaults.double(forKey: simulatorThresholdDefaultsKey)
        let safeMinutes = minutes.isFinite && minutes > 0 ? minutes : 60
        return safeMinutes * 60
    }

    static func developerDirectory(
        environment: [String: String],
        selectedDirectory: String?,
        applicationDirectories: [String],
        hasSimctl: (String) -> Bool
    ) -> String? {
        let candidates = [environment["DEVELOPER_DIR"], selectedDirectory]
            .compactMap { $0 } + applicationDirectories
        return candidates.first(where: hasSimctl)
    }

    static func shouldSuppressSimulatorWarnings(processCommands: [String]) -> Bool {
        processCommands.contains { processCommand in
            let command = processCommand.lowercased()
            return command.contains("xcodebuild")
                || command.contains("xctest")
                || command.contains("swiftuipreview")
                || command.contains("previewsagent")
        }
    }
}
