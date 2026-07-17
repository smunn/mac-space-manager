//
//  SpaceLabelStore.swift
//  SpaceManager
//
//  Persists floating task labels and reusable label appearance profiles.
//

import AppKit
import Combine
import Foundation

enum SpaceLabelTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case blue
    case yellow

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

enum SpaceLabelHandleSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

struct RecentSpaceLabel: Identifiable {
    let id: String
    let label: String
    let theme: SpaceLabelTheme
}

@MainActor
final class SpaceLabelStore: ObservableObject {
    static let shared = SpaceLabelStore()

    @Published private(set) var currentSpaceID: String?
    @Published private(set) var suggestedLabel = "Current Space"
    @Published private(set) var editingSpaceID: String?

    private struct StoredSpace: Codable {
        var label: String
        var frame: String?
        var theme: SpaceLabelTheme?
        var handleSide: SpaceLabelHandleSide?
    }

    private struct StoredProfile: Codable {
        var label: String
        var frame: String?
        var theme: SpaceLabelTheme
        var handleSide: SpaceLabelHandleSide?
        var lastUsed: Date
    }

    private struct StoredState: Codable {
        var spaces: [String: StoredSpace]
        var profiles: [String: StoredProfile]
    }

    private static let storageKey = "spaceLabelState.v1"
    private static let migrationCompletedKey = "spaceLabelMigrationFromSMMenubarCompleted"
    private var spaces: [String: StoredSpace] = [:]
    private var profiles: [String: StoredProfile] = [:]

    private init() {
        load()
    }

    func updateCurrentSpace(_ space: Space?) {
        let newID = space?.spaceID
        let changed = newID != currentSpaceID
        currentSpaceID = newID
        suggestedLabel = space?.spaceName ?? "Current Space"
        if changed {
            NotificationCenter.default.post(name: .spaceLabelCurrentSpaceDidChange, object: nil)
        }
    }

    func label(for spaceID: String) -> String {
        spaces[spaceID]?.label ?? ""
    }

    func theme(for spaceID: String) -> SpaceLabelTheme {
        spaces[spaceID]?.theme ?? .system
    }

    func handleSide(for spaceID: String) -> SpaceLabelHandleSide {
        spaces[spaceID]?.handleSide ?? .left
    }

    func beginEditing(spaceID: String) {
        editingSpaceID = spaceID
    }

    func endEditing(spaceID: String) {
        guard editingSpaceID == spaceID else { return }
        editingSpaceID = nil
    }

    func updateLabel(_ value: String, for spaceID: String) {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let limited = String(singleLine.prefix(160))
        var stored = spaces[spaceID] ?? defaultSpace()
        stored.label = limited
        spaces[spaceID] = stored
        objectWillChange.send()
        save()
    }

    func commitLabel(for spaceID: String) {
        guard var space = spaces[spaceID] else { return }
        let trimmed = space.label.trimmingCharacters(in: .whitespacesAndNewlines)
        space.label = trimmed
        spaces[spaceID] = space

        if !trimmed.isEmpty {
            profiles[profileKey(for: trimmed)] = StoredProfile(
                label: trimmed,
                frame: space.frame,
                theme: space.theme ?? .system,
                handleSide: space.handleSide ?? .left,
                lastUsed: Date())
        }
        objectWillChange.send()
        save()
    }

    func recentLabels(for spaceID: String) -> [RecentSpaceLabel] {
        let currentKey = profileKey(for: label(for: spaceID))
        return profiles
            .filter { $0.key != currentKey && !$0.value.label.isEmpty }
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
            .prefix(12)
            .map { RecentSpaceLabel(id: $0.key, label: $0.value.label, theme: $0.value.theme) }
    }

    func loadRecentLabel(_ recent: RecentSpaceLabel, for spaceID: String) {
        guard var profile = profiles[recent.id] else { return }
        profile.lastUsed = Date()
        profiles[recent.id] = profile
        spaces[spaceID] = StoredSpace(
            label: profile.label,
            frame: profile.frame,
            theme: profile.theme,
            handleSide: profile.handleSide ?? .left)
        objectWillChange.send()
        save()
    }

    func setTheme(_ theme: SpaceLabelTheme, for spaceID: String) {
        var space = spaces[spaceID] ?? defaultSpace()
        space.theme = theme
        spaces[spaceID] = space
        updateProfile(for: space) { $0.theme = theme }
        objectWillChange.send()
        save()
    }

    func setHandleSide(_ side: SpaceLabelHandleSide, for spaceID: String) {
        var space = spaces[spaceID] ?? defaultSpace()
        space.handleSide = side
        spaces[spaceID] = space
        updateProfile(for: space) { $0.handleSide = side }
        objectWillChange.send()
        save()
    }

    func removeLabel(from spaceID: String) {
        var space = spaces[spaceID] ?? defaultSpace()
        space.label = ""
        spaces[spaceID] = space
        objectWillChange.send()
        save()
    }

    func frame(for spaceID: String) -> NSRect? {
        guard let value = spaces[spaceID]?.frame else { return nil }
        return NSRectFromString(value)
    }

    func saveFrame(_ frame: NSRect, for spaceID: String) {
        var space = spaces[spaceID] ?? defaultSpace()
        space.frame = NSStringFromRect(frame)
        spaces[spaceID] = space
        updateProfile(for: space) { $0.frame = space.frame }
        save()
    }

    private func updateProfile(for space: StoredSpace, mutate: (inout StoredProfile) -> Void) {
        guard !space.label.isEmpty else { return }
        let key = profileKey(for: space.label)
        guard var profile = profiles[key] else { return }
        mutate(&profile)
        profile.lastUsed = Date()
        profiles[key] = profile
    }

    private func defaultSpace() -> StoredSpace {
        StoredSpace(label: "", frame: nil, theme: .system, handleSide: .left)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(StoredState.self, from: data) {
            spaces = decoded.spaces
            profiles = decoded.profiles
            return
        }
        migrateFromSMMenubarIfNeeded()
    }

    private func migrateFromSMMenubarIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationCompletedKey) else { return }
        defaults.set(true, forKey: Self.migrationCompletedKey)

        guard let legacyDefaults = UserDefaults(suiteName: "com.scottmunn.menubar"),
              let data = legacyDefaults.data(forKey: "spaceLabels.v2"),
              let decoded = try? JSONDecoder().decode(StoredState.self, from: data) else { return }
        spaces = decoded.spaces
        profiles = decoded.profiles
        save()
    }

    private func save() {
        let state = StoredState(spaces: spaces, profiles: profiles)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func profileKey(for label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

extension Notification.Name {
    static let spaceLabelCurrentSpaceDidChange = Notification.Name("spaceLabelCurrentSpaceDidChange")
}
