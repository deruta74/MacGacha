// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation

@MainActor protocol BackgroundSelectionStore: AnyObject {
    func lastShownID(for gameID: String) -> String?
    func setLastShownID(_ id: String, for gameID: String)
}

@MainActor final class UserDefaultsBackgroundSelectionStore: BackgroundSelectionStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func lastShownID(for gameID: String) -> String? { defaults.string(forKey: "lastBackgroundID." + gameID) }
    func setLastShownID(_ id: String, for gameID: String) { defaults.set(id, forKey: "lastBackgroundID." + gameID) }
}

/// Shared across view lifetimes, but not across app launches. Persistence uses
/// the API's slide ID, which survives local cache-path changes and is already UI identity.
@MainActor final class BackgroundSelectionSession {
    static let shared = BackgroundSelectionSession(store: UserDefaultsBackgroundSelectionStore())
    private let store: any BackgroundSelectionStore
    private var selected: [String: String] = [:]
    init(store: any BackgroundSelectionStore) { self.store = store }

    func selection(for gameID: String, availableIDs: [String]) -> String? {
        guard let first = availableIDs.first else { return nil }
        if let current = selected[gameID], availableIDs.contains(current) { return current }
        let id: String
        if selected[gameID] == nil, let saved = store.lastShownID(for: gameID), let index = availableIDs.firstIndex(of: saved) {
            id = availableIDs[(index + 1) % availableIDs.count]
        } else { id = first }
        select(id, for: gameID)
        return id
    }
    func select(_ id: String, for gameID: String) {
        guard selected[gameID] != id else { return }
        selected[gameID] = id
        store.setLastShownID(id, for: gameID)
    }
}
