//
//  RepositoryColor.swift
//  SpaceManager
//
//  Matches the deterministic repository color algorithm used by SMT Dash web.
//

import AppKit

enum RepositoryColor {
    static func color(for repositoryName: String) -> NSColor {
        var hash: Int32 = 0
        for scalar in repositoryName.unicodeScalars {
            hash = Int32(truncatingIfNeeded:
                Int64(scalar.value) + (Int64(hash) << 5) - Int64(hash))
        }

        let bits = UInt32(bitPattern: hash)
        let red = CGFloat((bits & 0xFF0000) >> 16) / 255
        let green = CGFloat((bits & 0x00FF00) >> 8) / 255
        let blue = CGFloat(bits & 0x0000FF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
