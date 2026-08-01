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

    static func contrastingTextColor(for backgroundColor: NSColor) -> NSColor {
        guard let color = backgroundColor.usingColorSpace(.sRGB) else { return .white }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linearized(color.redComponent)
            + 0.7152 * linearized(color.greenComponent)
            + 0.0722 * linearized(color.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
}
