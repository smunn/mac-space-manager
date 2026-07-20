//
//  SpaceOperationLog.swift
//  SpaceManager
//

import Foundation

enum SpaceOperationLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Space Manager/space-operations.log")

    private static let queue = DispatchQueue(label: "com.smunn.SpaceManager.spaceOperationLog")
    private static let maximumBytes: UInt64 = 1_000_000

    static func write(_ message: String) {
        queue.async {
            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maximumBytes
            {
                let previousURL = fileURL.appendingPathExtension("previous")
                try? fileManager.removeItem(at: previousURL)
                try? fileManager.moveItem(at: fileURL, to: previousURL)
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(timestamp)  \(message)\n".data(using: .utf8) else { return }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        }
    }
}
