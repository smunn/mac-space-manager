//
//  AppBuildInfo.swift
//  SpaceManager
//

import Foundation

struct AppBuildInfo: Equatable {
    let releaseVersion: String
    let buildDate: Date?

    static let current = from(bundle: .main)

    var menuLabel: String {
        guard let buildDate else { return "v\(releaseVersion)" }
        return "v\(releaseVersion) · \(Self.dateText(buildDate))"
    }

    static func from(bundle: Bundle) -> AppBuildInfo {
        let releaseVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let buildURL = bundle.executableURL ?? bundle.bundleURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: buildURL.path)
        return AppBuildInfo(
            releaseVersion: releaseVersion,
            buildDate: attributes?[.modificationDate] as? Date)
    }

    static func dateText(
        _ date: Date,
        timeZone: TimeZone = TimeZone(identifier: "America/Chicago")!
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy.MM.dd.HH.mm.ss"
        return formatter.string(from: date)
    }
}
