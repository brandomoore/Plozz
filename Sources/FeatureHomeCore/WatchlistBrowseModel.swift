import CoreModels
import Observation

@MainActor
@Observable
public final class WatchlistBrowseModel {
    public var preferences: WatchlistBrowsePreferences {
        get { storedPreferences }
        set {
            let saved = store.load()
            var updated = saved
            // Preserve other synced choices even before their notification arrives.
            if newValue.filter != storedPreferences.filter { updated.filter = newValue.filter }
            if newValue.sort != storedPreferences.sort { updated.sort = newValue.sort }
            apply(updated)
            if updated != saved { store.save(updated) }
        }
    }
    private var storedPreferences: WatchlistBrowsePreferences
    @ObservationIgnored private let store: WatchlistBrowsePreferencesStore
    @ObservationIgnored private var observation: UserDefaultsObservation?

    public init(store: WatchlistBrowsePreferencesStore) {
        self.store = store
        storedPreferences = store.load()
        observation = UserDefaultsObservation { [weak self] in self?.reload() }
    }

    public func reload() {
        apply(store.load())
    }

    private func apply(_ preferences: WatchlistBrowsePreferences) {
        guard storedPreferences != preferences else { return }
        storedPreferences = preferences
    }
}
