//
//  WallpaperResetter.swift
//  SpaceManager
//
//  Restores a Space to an unbranded wallpaper selected from a user folder.
//

import AppKit

enum WallpaperResetter {
    static let folderDefaultsKey = "defaultWallpaperFolder"
    static let defaultFolderPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/* MAC */Wallpapers/Current Mac Wallpapers")
        .path

    private static let supportedExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    static func resetWallpaper(on displayID: String) throws -> URL {
        let configuredPath = UserDefaults.standard.string(forKey: folderDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = configuredPath?.isEmpty == false ? configuredPath! : defaultFolderPath
        let folderURL = URL(fileURLWithPath: NSString(string: folderPath).expandingTildeInPath)

        let imageURLs = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            supportedExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        guard !imageURLs.isEmpty else {
            throw ResetError.noImages(folderURL)
        }
        guard let screen = DisplayGeometryUtilities.screen(for: displayID) else {
            throw ResetError.displayUnavailable
        }

        let currentURL = NSWorkspace.shared.desktopImageURL(for: screen)
        let alternatives = imageURLs.filter { $0.standardizedFileURL != currentURL?.standardizedFileURL }
        guard let wallpaperURL = (alternatives.isEmpty ? imageURLs : alternatives).randomElement() else {
            throw ResetError.noImages(folderURL)
        }

        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        try NSWorkspace.shared.setDesktopImageURL(wallpaperURL, for: screen, options: options)
        return wallpaperURL
    }

    enum ResetError: LocalizedError {
        case displayUnavailable
        case noImages(URL)

        var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                return "The current display is unavailable."
            case .noImages(let folderURL):
                return "No supported images were found in \(folderURL.path)."
            }
        }
    }
}
