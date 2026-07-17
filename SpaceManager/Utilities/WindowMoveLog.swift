//
//  WindowMoveLog.swift
//  SpaceManager
//

import Foundation

enum WindowMoveLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Space Manager/window-move.log")

    private static let queue = DispatchQueue(label: "com.smunn.SpaceManager.windowMoveLog")

    static func write(_ message: String) {
        queue.sync {
            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(timestamp)  \(message)\n".data(using: .utf8) else { return }

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}
