//
//  WorkspaceLauncher.swift
//  SpaceManager
//

import Foundation

enum WorkspaceLauncher {
    private static let scriptPath = NSString(
        string: "~/Sites/sm-mac-configuration-scripts/bin/launch-work.js"
    ).expandingTildeInPath

    private static let projectSpacesPath = NSString(
        string: "~/Sites/sm-mac-configuration-scripts/lib/project-spaces.js"
    ).expandingTildeInPath

    static func launch(_ workspaceKey: String) {
        let escaped = workspaceKey.replacingOccurrences(of: "'", with: "'\\''")
        let command = "node '\(scriptPath)' '\(escaped)' --from-app"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                NSLog("WorkspaceLauncher: failed to launch '%@': %@", workspaceKey, error.localizedDescription)
            }
        }
    }

    static func launchSite(name: String, path sitePath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let configPath = try writeTemporarySiteConfig(name: name, path: sitePath)
                launchTemporarySiteConfig(configPath: configPath, name: name)
            } catch {
                NSLog("WorkspaceLauncher: failed to prepare site '%@': %@", name, error.localizedDescription)
            }
        }
    }

    private static func writeTemporarySiteConfig(name: String, path sitePath: String) throws -> String {
        let terminalWorkingDirectory = shellQuoted(sitePath)
        let config: [String: Any] = [
            "version": 1,
            "workspaces": [
                "__site__": [
                    "displayName": name,
                    "spaceName": name,
                    "projectPath": sitePath,
                    "wallpaper": false,
                    "apps": [
                        [
                            "type": "chrome",
                            "position": "left",
                            "profile": "Default"
                        ],
                        [
                            "type": "terminal",
                            "position": "top-right",
                            "workingDirectory": terminalWorkingDirectory
                        ],
                        [
                            "type": "terminal",
                            "position": "bottom-right",
                            "workingDirectory": terminalWorkingDirectory,
                            "command": "todo"
                        ]
                    ]
                ]
            ]
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("space-manager-site-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        return url.path
    }

    private static func launchTemporarySiteConfig(configPath: String, name: String) {
        let script = """
        const fs = require('fs');
        const { launchWorkspace } = require(process.argv[1]);
        const configPath = process.argv[2];
        launchWorkspace('__site__', configPath, { fromApp: true })
          .catch((error) => {
            console.error(error && error.message ? error.message : error);
            process.exitCode = 1;
          })
          .finally(() => {
            try { fs.unlinkSync(configPath); } catch (_) {}
          });
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-l",
            "-c",
            [
                "node",
                "-e",
                shellQuoted(script),
                shellQuoted(projectSpacesPath),
                shellQuoted(configPath)
            ].joined(separator: " ")
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("WorkspaceLauncher: failed to launch site '%@': %@", name, error.localizedDescription)
            try? FileManager.default.removeItem(atPath: configPath)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
