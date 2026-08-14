//
//  CodexSessionLauncher.swift
//  SpaceManager
//
//  A detached process cannot be assigned a new controlling terminal. AI tools
//  persist their transcripts separately, so the supported recovery path is to
//  terminate the stale process and invoke Scott's preferred resume command in
//  a new Terminal.
//

import AppKit
import Foundation

enum AISessionLauncher {
    static func resume(
        service: AISessionService,
        sessionID: String,
        projectPath: String?
    ) -> Bool {
        guard !sessionID.isEmpty else { return false }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-manager-ai-resume-\(UUID().uuidString).command")
        let directory = projectPath.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let resumeCommand = service == .codex ? "cxco" : "clco"
        let script = """
        #!/bin/zsh
        rm -f -- "$0"
        cd -- \(shellQuoted(directory))
        exec /bin/zsh -lic \(shellQuoted("\(resumeCommand) \(shellQuoted(sessionID))"))
        """

        guard FileManager.default.createFile(
            atPath: scriptURL.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700])
        else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        } catch {
            NSLog("AISessionLauncher: failed to open Terminal: %@", error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: scriptURL)
        return false
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum ProcessDiagnosticSampler {
    static func capture(pid: pid_t, completion: @escaping @Sendable (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard pid > 1 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Space-Manager-process-\(pid)-sample.txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "2", "1", "-file", outputURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                let result = process.terminationStatus == 0 ? outputURL : nil
                DispatchQueue.main.async { completion(result) }
            } catch {
                NSLog("ProcessDiagnosticSampler: sample failed: %@", error.localizedDescription)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
