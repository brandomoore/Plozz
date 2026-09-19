import CoreModels
import XCTest

final class RetiredCollectionShortcutTests: XCTestCase {
    func testOnlySyntheticPlexCollectionLibrariesAreRetired() {
        XCTAssertTrue(library(.plex, id: "plex:collections:1", kind: .collection).isRetiredCollectionShortcut)
        XCTAssertFalse(library(.plex, id: "1", kind: .movie).isRetiredCollectionShortcut)
        XCTAssertFalse(library(.plex, id: "12", kind: .collection).isRetiredCollectionShortcut)
        XCTAssertFalse(library(.jellyfin, id: "boxsets", kind: .collection).isRetiredCollectionShortcut)
        XCTAssertFalse(library(.emby, id: "boxsets", kind: .collection).isRetiredCollectionShortcut)
        XCTAssertFalse(library(.jellyfin, id: "plex:collections:1", kind: .collection).isRetiredCollectionShortcut)
    }

    func testLegacyNavigationSnapshotDropsOnlyRetiredShortcuts() throws {
        let suite = "RetiredCollections-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actual = library(.plex, id: "1", kind: .movie)
        let native = library(.jellyfin, id: "boxsets", kind: .collection)
        let retired = library(.plex, id: "plex:collections:1", kind: .collection)
        let key = SettingsKey.scoped("com.plozz.navigationLibrariesSnapshot", namespace: "viewer")
        defaults.set(try JSONEncoder().encode([actual, retired, native]), forKey: key)

        let store = NavigationLibrariesSnapshotStore(defaults: defaults, namespace: "viewer")
        XCTAssertEqual(store.load(), [actual, native])
        XCTAssertEqual(
            try JSONDecoder().decode([AggregatedLibrary].self, from: XCTUnwrap(defaults.data(forKey: key))),
            [actual, retired, native],
            "Reading the migration must not wipe the persisted snapshot."
        )
        XCTAssertTrue(NavigationLibrariesSnapshotStore(defaults: defaults, namespace: "other").load().isEmpty)
    }

    func testNavigationSnapshotDoesNotPersistRetiredShortcutsAgain() throws {
        let suite = "RetiredCollections-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actual = library(.plex, id: "1", kind: .movie)
        let retired = library(.plex, id: "plex:collections:1", kind: .collection)
        let store = NavigationLibrariesSnapshotStore(defaults: defaults)
        store.save([retired, actual])

        let data = try XCTUnwrap(defaults.data(forKey: "com.plozz.navigationLibrariesSnapshot"))
        XCTAssertEqual(try JSONDecoder().decode([AggregatedLibrary].self, from: data), [actual])
        XCTAssertEqual(store.load(), [actual])
    }

    private func library(_ provider: ProviderKind, id: String, kind: MediaItemKind) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: "account", accountName: "Viewer", serverName: "Server",
            providerKind: provider,
            library: MediaLibrary(id: id, title: "Library", kind: kind)
        )
    }
}
