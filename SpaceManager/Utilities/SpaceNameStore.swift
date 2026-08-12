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
    private let queue = DispatchQueue(label: "com.smunn.SpaceManager.SpaceNameStore", attributes: .concurrent)
    private let persistenceQueue = DispatchQueue(label: "com.smunn.SpaceManager.SpaceNameStore.Persistence")
    private var cachedNames: [String: SpaceNameInfo]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cachedNames = Self.decodeNames(from: defaults.data(forKey: key))
            ?? Self.decodeNames(from: defaults.data(forKey: backupKey))
            ?? [:]
    }

    func loadAll() -> [String: SpaceNameInfo] {
        queue.sync {
            cachedNames
        }
    }

    func save(_ newValue: [String: SpaceNameInfo]) {
        let oldValue = queue.sync(flags: .barrier) { () -> [String: SpaceNameInfo] in
            let oldValue = cachedNames
            cachedNames = newValue
            return oldValue
        }
        persist(newValue, previousValue: oldValue)
    }

    func update(_ mutate: (inout [String: SpaceNameInfo]) -> Void) {
        let values = queue.sync(flags: .barrier) { () -> ([String: SpaceNameInfo], [String: SpaceNameInfo]) in
            let oldValue = cachedNames
            var newValue = oldValue
            mutate(&newValue)
            cachedNames = newValue
            return (oldValue, newValue)
        }
        persist(values.1, previousValue: values.0)
    }

    func remove(spaceIDs: Set<String>) {
        guard !spaceIDs.isEmpty else { return }
        let values = queue.sync(flags: .barrier) { () -> ([String: SpaceNameInfo], [String: SpaceNameInfo]) in
            let oldValue = cachedNames
            var names = oldValue
            for spaceID in spaceIDs {
                names.removeValue(forKey: spaceID)
            }
            cachedNames = names
            return (oldValue, names)
        }
        persist(values.1, previousValue: values.0, synchronizeBackup: true)
    }

    private static func decodeNames(from data: Data?) -> [String: SpaceNameInfo]? {
        guard let data else { return nil }
        return try? PropertyListDecoder().decode([String: SpaceNameInfo].self, from: data)
    }

    private func persist(
        _ names: [String: SpaceNameInfo],
        previousValue: [String: SpaceNameInfo],
        synchronizeBackup: Bool = false
    ) {
        // UserDefaults posts change notifications while writing. Never perform those
        // writes while holding the state queue: a notification delivered to the main
        // thread can synchronously read this store and deadlock both queues.
        persistenceQueue.async { [defaults, key, backupKey] in
            do {
                let encoder = PropertyListEncoder()
                let data = try encoder.encode(names)
                if !previousValue.isEmpty {
                    defaults.set(try encoder.encode(previousValue), forKey: backupKey)
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
}
