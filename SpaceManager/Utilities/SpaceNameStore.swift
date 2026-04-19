//
//  SpaceNameStore.swift
//  SpaceManager
//
//  Persists space name data in UserDefaults.
//  Adapted from Spaceman by René Uittenbogaard (MIT License).
//

import Foundation

final class SpaceNameStore {
    static let shared = SpaceNameStore()

    private let defaults: UserDefaults
    private let key = "spaceNames"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private let queue = DispatchQueue(label: "com.smunn.SpaceManager.SpaceNameStore", attributes: .concurrent)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [String: SpaceNameInfo] {
        queue.sync {
            guard let data = defaults.data(forKey: key) else { return [:] }
            return (try? decoder.decode([String: SpaceNameInfo].self, from: data)) ?? [:]
        }
    }

    func save(_ newValue: [String: SpaceNameInfo]) {
        queue.sync(flags: .barrier) {
            guard let data = try? encoder.encode(newValue) else { return }
            defaults.set(data, forKey: key)
        }
    }

    func update(_ mutate: (inout [String: SpaceNameInfo]) -> Void) {
        queue.sync(flags: .barrier) {
            var names = loadUnlocked()
            mutate(&names)
            guard let data = try? encoder.encode(names) else { return }
            defaults.set(data, forKey: key)
        }
    }

    private func loadUnlocked() -> [String: SpaceNameInfo] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? decoder.decode([String: SpaceNameInfo].self, from: data)) ?? [:]
    }
}
