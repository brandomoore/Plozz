import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class WatchlistBrowseModelTests: XCTestCase {
    func testChoicesSurviveRemountWithoutLeakingIntoAnotherProfile() throws {
        let suite = "WatchlistBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistBrowsePreferencesStore(namespace: "first", defaults: defaults)
        let model = WatchlistBrowseModel(store: store)
        model.preferences.filter = .shows
        model.preferences.sort = .init(field: .releaseDate, direction: .descending)
        XCTAssertEqual(WatchlistBrowseModel(store: store).preferences, model.preferences)
        let other = WatchlistBrowseModel(store: .init(namespace: "second", defaults: defaults))
        XCTAssertEqual(other.preferences, .default)
    }

    func testSyncedChangesAndRemovalRefreshRetainedModelsWithoutWritingBack() throws {
        for namespace in [nil, "first"] {
            let suite = "WatchlistBrowseModelTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = WatchlistBrowseModel(store: .init(namespace: namespace, defaults: defaults))
            let other = WatchlistBrowseModel(store: .init(namespace: "other", defaults: defaults))
            let synced = WatchlistBrowsePreferences(
                filter: .movies, sort: .init(field: .name, direction: .ascending)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(synced)
            let blob = try PropertyListSerialization.data(
                fromPropertyList: [data], format: .binary, options: 0
            )
            let key = SettingsKey.scoped(WatchlistBrowsePreferencesStore.storageKey, namespace: namespace)

            ProfileSettingsTransfer.applyOne(
                baseKey: WatchlistBrowsePreferencesStore.storageKey,
                blob: blob, namespace: namespace, defaults: defaults
            )
            let persisted = try XCTUnwrap(defaults.data(forKey: key))
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

            XCTAssertEqual(model.preferences, synced)
            XCTAssertEqual(other.preferences, .default)
            XCTAssertEqual(defaults.data(forKey: key), persisted)

            ProfileSettingsTransfer.removeOne(
                baseKey: WatchlistBrowsePreferencesStore.storageKey,
                namespace: namespace, defaults: defaults
            )
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

            XCTAssertEqual(model.preferences, .default)
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(other.preferences, .default)
        }
    }

    func testLocalEditsPreserveOtherSyncedChoicesBeforeNotification() throws {
        let suite = "WatchlistBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistBrowsePreferencesStore(namespace: "first", defaults: defaults)
        let model = WatchlistBrowseModel(store: store)

        store.save(.init(filter: .movies))
        model.preferences.sort = .init(field: .name, direction: .ascending)
        XCTAssertEqual(model.preferences.filter, .movies)
        XCTAssertEqual(store.load(), model.preferences)

        store.save(.init(filter: .movies, sort: .init(field: .releaseDate, direction: .ascending)))
        model.preferences.filter = .shows
        XCTAssertEqual(model.preferences.sort, .init(field: .releaseDate, direction: .ascending))
        XCTAssertEqual(store.load(), model.preferences)
    }

    func testDefaultsObservationDoesNotRetainTheModel() throws {
        let suite = "WatchlistBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var model: WatchlistBrowseModel? = WatchlistBrowseModel(store: .init(defaults: defaults))
        weak let weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }
}
