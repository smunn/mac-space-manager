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
    private let backupKey = "spaceNames.backup"
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private let queue = DispatchQueue(label: "com.smunn.SpaceManager.SpaceNameStore", attributes: .concurrent)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() -> [String: SpaceNameInfo] {
        queue.sync {
            loadUnlocked()
        }
    }

    func save(_ newValue: [String: SpaceNameInfo]) {
        queue.sync(flags: .barrier) {
            saveUnlocked(newValue)
        }
    }

    func update(_ mutate: (inout [String: SpaceNameInfo]) -> Void) {
        queue.sync(flags: .barrier) {
            var names = loadUnlocked()
            mutate(&names)
            saveUnlocked(names)
        }
    }

    func remove(spaceIDs: Set<String>) {
        guard !spaceIDs.isEmpty else { return }
        queue.sync(flags: .barrier) {
            var names = loadUnlocked()
            for spaceID in spaceIDs {
                names.removeValue(forKey: spaceID)
            }
            saveUnlocked(names, synchronizeBackup: true)
        }
    }

    private func loadUnlocked() -> [String: SpaceNameInfo] {
        if let data = defaults.data(forKey: key) {
            do {
                return try decoder.decode([String: SpaceNameInfo].self, from: data)
            } catch {
                NSLog("SpaceNameStore: primary data is invalid, trying backup: \(error)")
            }
        }

        if let backup = defaults.data(forKey: backupKey) {
            do {
                return try decoder.decode([String: SpaceNameInfo].self, from: backup)
            } catch {
                NSLog("SpaceNameStore: backup data is invalid: \(error)")
            }
        }

        return [:]
    }

    private func saveUnlocked(
        _ names: [String: SpaceNameInfo],
        synchronizeBackup: Bool = false
    ) {
        do {
            let data = try encoder.encode(names)
            if let current = defaults.data(forKey: key),
               (try? decoder.decode([String: SpaceNameInfo].self, from: current)) != nil
            {
                defaults.set(current, forKey: backupKey)
            }
            defaults.set(data, forKey: key)
            if synchronizeBackup {
                defaults.set(data, forKey: backupKey)
            }
        } catch {
            NSLog("SpaceNameStore: failed to encode names: \(error)")
        }
    }
}
