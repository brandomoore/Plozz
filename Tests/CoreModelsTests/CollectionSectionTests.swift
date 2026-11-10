import XCTest
@testable import CoreModels

final class CollectionSectionTests: XCTestCase {
    func testLegacySingularSourceMigratesWithoutChangingRowIdentityOrAppearance() throws {
        let legacy = """
        {"id":"legacy","name":"My row","source":{"accountID":"account","libraryID":"movies",
        "collectionID":"collection","title":"Collection","serverUserID":"viewer"},"cardStyle":"landscape","titleLogo":"on"}
        """
        let restored = try JSONDecoder().decode(CollectionSection.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored.id, "legacy")
        XCTAssertEqual(restored.name, "My row")
        XCTAssertEqual(restored.cardStyle, .landscape)
        XCTAssertEqual(restored.titleLogo, .on)
        XCTAssertEqual(restored.collectionSources.first?.collectionID, "collection")
        XCTAssertEqual(restored.sources.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(CollectionSection.self, from: JSONEncoder().encode(restored)), restored)
    }

    @MainActor
    func testMixedSourcesRoundTripInSelectionOrderAndRejectAnEmptyRow() throws {
        let sources = section.sources + [
            HomeContentSource(home: .watchlist),
            .init(feed: .playlist("playlist"), accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Playlist"),
            .init(feed: .library(.movie), accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Movies"),
            .init(feed: .recommendation(sectionID: "popular", kind: .movie),
                  accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Popular")
        ]
        let combined = CollectionSection(id: "combined", sources: sources + [sources[0]])
        XCTAssertEqual(combined.sources, sources)
        XCTAssertNil(combined.collectionItem)
        XCTAssertEqual(try JSONDecoder().decode(CollectionSection.self, from: JSONEncoder().encode(combined)), combined)
        let model = HomeLibraryVisibilityModel(store: MemoryHomeVisibilityStore())
        try model.saveCollectionSection(combined, catalog: .init(libraries: []))
        XCTAssertEqual(model.visibility.collectionSections, [combined])
        XCTAssertThrowsError(try model.saveCollectionSection(.init(sources: []), catalog: .init(libraries: [])))
        XCTAssertEqual(model.visibility.collectionSections, [combined])
    }

    func testSourceIdentityIncludesViewerAndFeedButNotDisplayName() {
        let first = section.sources[0]
        let renamed = HomeContentSource(
            feed: first.feed, accountID: first.accountID, serverUserID: first.serverUserID,
            libraryID: first.libraryID, title: "New server title"
        )
        XCTAssertEqual(first.id, renamed.id)
        XCTAssertEqual(HomeContentSource.normalized([first, renamed]), [first])
        XCTAssertNotEqual(first.id, HomeContentSource(
            feed: first.feed, accountID: first.accountID, serverUserID: "other-viewer",
            libraryID: first.libraryID, title: first.title
        ).id)
        XCTAssertNotEqual(first.id, HomeContentSource(
            feed: .playlist("collection"), accountID: first.accountID, serverUserID: first.serverUserID,
            libraryID: first.libraryID, title: first.title
        ).id)
    }

    private var section: CollectionSection {
        .init(id: "section", source: .init(
            accountID: "account", libraryID: "movies", collectionID: "collection",
            title: "Server collection", serverUserID: "viewer"
        ))
    }

    func testNameStyleAndProviderIdentityRoundTripWithoutChangingTheSource() throws {
        var edited = section
        edited.name = "  My movies  "
        edited.cardStyle = .landscape
        edited.titleLogo = .off
        XCTAssertEqual(edited.title, "My movies")
        XCTAssertEqual(edited.sources, section.sources)
        XCTAssertEqual(edited.rowID, .section("section"))
        XCTAssertNotEqual(edited.rowID, .server(accountID: "account", section: "section"))
        XCTAssertEqual(edited.collectionItem?.id, "collection")
        XCTAssertEqual(edited.collectionItem?.sourceAccountID, "account")
        XCTAssertEqual(edited.collectionItem?.libraryID, "movies")
        XCTAssertEqual(try JSONDecoder().decode(CollectionSection.self, from: JSONEncoder().encode(edited)), edited)
        edited.name = " \n "
        XCTAssertEqual(edited.title, "Server collection")
    }

    func testFeaturedRoundTripPreservesSourceAndOlderStyles() throws {
        XCTAssertEqual(section.cardStyle, .poster)
        for style in CollectionSection.CardStyle.allCases {
            var edited = section
            edited.cardStyle = style
            let restored = try JSONDecoder().decode(CollectionSection.self, from: JSONEncoder().encode(edited))
            XCTAssertEqual(restored, edited)
            XCTAssertEqual(restored.sources, section.sources)
            XCTAssertEqual(restored.rowID, section.rowID)
        }
    }

    func testTitleLogoDefaultsForExistingRowsAndRoundTripsEveryMode() throws {
        let encoded = try JSONEncoder().encode(section)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "titleLogo")
        let legacy = try JSONDecoder().decode(
            CollectionSection.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(section.titleLogo, .off)
        XCTAssertEqual(legacy.titleLogo, .off)
        XCTAssertEqual(legacy.sources, section.sources)
        XCTAssertEqual(LandscapeTitleLogo.allCases, [.on, .off])
        for mode in LandscapeTitleLogo.allCases {
            var edited = section
            edited.titleLogo = mode
            XCTAssertEqual(
                try JSONDecoder().decode(CollectionSection.self, from: JSONEncoder().encode(edited)), edited
            )
        }
    }

    func testRetiredAutomaticLogoModeMigratesToOffWithoutLosingTheRow() throws {
        let encoded = try JSONEncoder().encode(section)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["titleLogo"] = "automatic"
        let restored = try JSONDecoder().decode(
            CollectionSection.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(restored, section)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any]
        )
        XCTAssertEqual(saved["titleLogo"] as? String, "off")
    }

    func testUnknownLogoModeIsNotSilentlyReplacedWithOff() {
        XCTAssertThrowsError(try JSONDecoder().decode(LandscapeTitleLogo.self, from: Data("\"invalid\"".utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected a typed data-corruption error, got \(error)")
            }
        }
    }

    @MainActor
    func testAddingAndEditingPreserveArrangementAndDefaultProfileIsolation() throws {
        let suite = "CollectionSectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults)
        let model = HomeLibraryVisibilityModel(store: store)
        let catalog = HomeSectionCatalog(libraries: [])
        let old = catalog.sections(in: model.visibility).enabled
        try model.saveCollectionSection(section, catalog: catalog)
        var expected = old
        expected.insert(section.rowID, at: expected.firstIndex(of: .libraries) ?? expected.endIndex)
        XCTAssertEqual(catalog.sections(in: model.visibility).enabled, expected)
        XCTAssertEqual(model.visibility.rowCustomization?.defaults, .custom)
        XCTAssertEqual(store.load().collectionSections, [section])
        XCTAssertTrue(HomeLibraryVisibilityStore(defaults: defaults, namespace: "other").load().collectionSections.isEmpty)

        var edited = section
        edited.name = "New name"
        edited.cardStyle = .landscape
        edited.titleLogo = .on
        try model.saveCollectionSection(edited, catalog: catalog)
        XCTAssertEqual(model.visibility.collectionSections, [edited])
        XCTAssertEqual(catalog.sections(in: model.visibility).enabled, expected)
        try model.setHomeSectionVisible(false, id: section.rowID, catalog: catalog)
        XCTAssertFalse(catalog.sections(in: model.visibility).enabled.contains(section.rowID))
        XCTAssertEqual(model.visibility.collectionSections, [edited])
        try model.setHomeSectionVisible(true, id: section.rowID, catalog: catalog)
        XCTAssertTrue(catalog.sections(in: model.visibility).enabled.contains(section.rowID))

        model.useRowDefaults(.matchServer)
        XCTAssertEqual(model.visibility.collectionSections, [edited])
        XCTAssertFalse(catalog.sections(in: model.visibility).enabled.contains(section.rowID))
        let exported = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
        ProfileSettingsTransfer.apply(exported, namespace: "imported", defaults: defaults)
        XCTAssertEqual(HomeLibraryVisibilityStore(defaults: defaults, namespace: "imported").load(), model.visibility.intent)
    }

    func testLegacySettingsAndOfflineSourceIntentRemainIntact() throws {
        let legacy = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.collectionSections.isEmpty)
        XCTAssertNil(legacy.rowCustomization)
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, order: [section.rowID, .libraries],
                                    shown: [section.rowID, .libraries]),
            collectionSections: [section]
        )
        let catalog = HomeSectionCatalog(libraries: [])
        XCTAssertTrue(catalog.sections(in: visibility).enabled.contains(section.rowID))
        visibility.setEnabled(false, for: "account:movies")
        XCTAssertFalse(catalog.availableChoices(in: visibility).contains { $0.id == section.rowID })
        let reordered = try catalog.reordering(catalog.sections(in: visibility).enabled, in: visibility)
        XCTAssertEqual(reordered.collectionSections, [section])
        XCTAssertEqual(reordered.rowCustomization?.order.first, section.rowID)
    }

    @MainActor
    func testUnqualifiedNewCollectionCannotBeSaved() {
        let model = HomeLibraryVisibilityModel(store: MemoryHomeVisibilityStore())
        let invalid = CollectionSection(source: .init(accountID: "a", collectionID: "c", title: "Collection"))
        XCTAssertThrowsError(try model.saveCollectionSection(invalid, catalog: .init(libraries: [])))
        XCTAssertTrue(model.visibility.collectionSections.isEmpty)
    }

    @MainActor
    func testTwoSectionsCanUseTheSameCollectionIndependently() throws {
        let model = HomeLibraryVisibilityModel(store: MemoryHomeVisibilityStore())
        let catalog = HomeSectionCatalog(libraries: [])
        let second = CollectionSection(id: "second", name: "Featured picks", sources: section.sources, cardStyle: .landscape)
        try model.saveCollectionSection(section, catalog: catalog)
        try model.saveCollectionSection(second, catalog: catalog)
        try model.setHomeSectionVisible(false, id: section.rowID, catalog: catalog)
        XCTAssertEqual(model.visibility.collectionSections, [section, second])
        XCTAssertTrue(catalog.sections(in: model.visibility).enabled.contains(second.rowID))
        XCTAssertFalse(catalog.sections(in: model.visibility).enabled.contains(section.rowID))
    }
}

private final class MemoryHomeVisibilityStore: HomeLibraryVisibilityStoring, @unchecked Sendable {
    func load() -> HomeLibraryVisibility { .default }
    func save(_ visibility: HomeLibraryVisibility) {}
}
