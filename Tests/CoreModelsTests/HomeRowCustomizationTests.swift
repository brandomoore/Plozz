import XCTest
@testable import CoreModels

final class HomeRowCustomizationTests: XCTestCase {
    func testNativeShelfLocatorRoundTripsAndOldRowsRemainDecodable() throws {
        let old = Data(#"{"id":"plex:1:movie.recentlyadded.1","kind":"recentlyAdded","libraryID":"1","includesNextUp":false}"#.utf8)
        var section = try JSONDecoder().decode(ServerHomeSection.self, from: old)
        XCTAssertNil(section.contentKey)
        section.contentKey = "/library/sections/1/all?sort=addedAt:desc"
        let definition = HomeServerRowDefinition(
            accountID: "plex", serverName: "Server", providerKind: .plex, section: section
        )
        let settings = HomeRowCustomization(defaults: .custom, serverRows: [definition])
        let restored = try JSONDecoder().decode(
            HomeRowCustomization.self, from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.serverRows, settings.serverRows)
        XCTAssertEqual(restored.serverRows.first?.section.contentKey, section.contentKey)
    }

    func testSectionCatalogPreservesEveryProviderAndDeduplicatesNativeRows() {
        let kinds: [ProviderKind] = [.jellyfin, .emby, .plex, .silo, .mediaShare]
        let libraries = kinds.flatMap { kind in
            [library(kind.rawValue, "movies", provider: kind),
             library(kind.rawValue, "shows", provider: kind, kind: .series)]
        }
        let native = HomeServerRowDefinition(
            accountID: "silo", serverName: "Silo", providerKind: .silo,
            section: .init(id: "native", kind: .nextUp)
        )
        let catalog = HomeSectionCatalog(libraries: libraries, serverRows: [native, native])
        XCTAssertEqual(Set(catalog.choices.map(\.id)).count, catalog.choices.count)
        XCTAssertEqual(catalog.choices.filter { $0.id == native.id }.count, 1)
        for source in libraries {
            XCTAssertTrue(catalog.choices.contains { $0.id == .library(source.key, kind: .recentlyAdded) })
            XCTAssertEqual(
                catalog.choices.contains { $0.id == .library(source.key, kind: .nextUp) },
                [.jellyfin, .emby].contains(source.providerKind) && source.library.kind == .series
            )
        }
        XCTAssertTrue(catalog.choices.contains { $0.id == .liveTV })
        XCTAssertTrue(catalog.choices.contains { $0.id == .libraries })
        XCTAssertFalse(catalog.choices.contains { $0.id == .library("mediaShare:shows", kind: .nextUp) })
    }

    func testSectionEditsPreservePresetsUntilARealChangeAndDoNotDisableLibraries() throws {
        let source = library("a", "movies")
        let catalog = HomeSectionCatalog(libraries: [source])
        for preset: HomeRowCustomization.Defaults in [.combined, .provider, .legacy, .custom, .matchServer] {
            var original = HomeLibraryVisibility(rowCustomization: .init(defaults: preset))
            if preset == .custom {
                original.rowCustomization = .init(
                    defaults: .custom, order: [.global(.continueWatching)],
                    shown: [.global(.continueWatching)]
                )
            }
            original.continueWatchingShowsSeriesArtwork = false
            let sections = catalog.sections(in: original)
            XCTAssertEqual(try catalog.reordering(sections.enabled, in: original), original)
            let target = try XCTUnwrap(sections.enabled.first)
            XCTAssertEqual(try catalog.settingVisible(true, id: target, in: original), original)
            let removed = try catalog.settingVisible(false, id: target, in: original)
            XCTAssertFalse(catalog.sections(in: removed).enabled.contains(target))
            XCTAssertTrue(removed.isEnabled(source.key))
            XCTAssertFalse(removed.continueWatchingShowsSeriesArtwork)
            let restored = try catalog.settingVisible(true, id: target, in: removed)
            XCTAssertEqual(catalog.sections(in: restored).enabled.last, target)
            XCTAssertFalse(restored.continueWatchingShowsSeriesArtwork)
        }
    }

    func testSectionEditsPreserveOfflineAndMergedRowsAndRejectStaleOrders() throws {
        let source = library("a", "shows")
        let nextID = HomeRowID.library(source.key, kind: .nextUp)
        let offlineID = HomeRowID.library("offline:shows", kind: .recentlyAdded)
        let catalog = HomeSectionCatalog(libraries: [library("a", "shows", kind: .series)])
        let original = HomeLibraryVisibility(
            rowCustomization: .init(
                defaults: .custom,
                order: [offlineID, nextID, .global(.continueWatching), .libraries],
                shown: [offlineID, nextID, .global(.continueWatching), .libraries]
            ),
            mergeNextUpIntoContinueWatching: true
        )
        let visible = catalog.sections(in: original).enabled
        let reordered = try catalog.reordering(Array(visible.reversed()), in: original)
        XCTAssertEqual(reordered.rowCustomization?.order.first, offlineID)
        XCTAssertEqual(reordered.rowCustomization?.order[1], nextID)
        XCTAssertTrue(reordered.rowCustomization?.shown.contains(offlineID) == true)
        XCTAssertTrue(reordered.rowCustomization?.shown.contains(nextID) == true)
        XCTAssertThrowsError(try catalog.settingVisible(true, id: nextID, in: reordered))
        XCTAssertThrowsError(try catalog.reordering(visible + [visible[0]], in: original))
        XCTAssertThrowsError(try catalog.reordering(Array(visible.dropFirst()), in: original))
        let hiddenContinue = try catalog.settingVisible(false, id: .global(.continueWatching), in: original)
        XCTAssertTrue(catalog.sections(in: hiddenContinue).enabled.contains(nextID))
    }

    func testSectionCatalogExcludesDisabledLibraryAndRetiredChoices() {
        let source = library("a", "movies")
        let native = HomeServerRowDefinition(
            accountID: "a", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "latest", kind: .recentlyAdded, libraryID: "movies")
        )
        let catalog = HomeSectionCatalog(libraries: [source], serverRows: [native])
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: source.key)
        XCTAssertFalse(catalog.availableChoices(in: visibility).contains { $0.library != nil || $0.id == native.id })
        XCTAssertThrowsError(try catalog.settingVisible(true, id: native.id, in: visibility))
    }

    private func library(
        _ account: String, _ id: String, provider: ProviderKind = .emby, kind: MediaItemKind = .movie
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account, accountName: account, serverName: "Server",
            providerKind: provider, library: MediaLibrary(id: id, title: id, kind: kind)
        )
    }

    func testBothPresetsPlaceLibrariesAfterLiveTVAndDiscoveredFallbackRows() {
        let fallback = library("a", "movies")
        let fallbackID = HomeRowID.library(fallback.key, kind: .recentlyAdded)
        let choices = HomeRowChoice.shared + HomeRowChoice.baseRows(for: fallback)
        var single = HomeRowCustomization(defaults: .matchServer)
        single.resolvedDefaults = .init(
            mode: .server, order: [.libraries, .global(.continueWatching), .liveTV]
        )
        var multiple = HomeRowCustomization(defaults: .matchServer)
        multiple.resolvedDefaults = .init(
            mode: .combined, order: HomeRowChoice.shared.map(\.id), fallbackAccountIDs: ["a"]
        )
        var unsupported = HomeRowCustomization(defaults: .matchServer)
        unsupported.resolvedDefaults = .init(mode: .providerFallback)
        let common: [HomeRowID] = [
            .global(.continueWatching), .global(.watchlist), .global(.recentlyAdded), .liveTV
        ]
        let cases: [(HomeRowCustomization, [HomeRowID])] = [
            (.init(defaults: .combined), common + [.libraries]),
            (single, [.global(.continueWatching), .liveTV, .libraries]),
            (multiple, common + [fallbackID, .libraries]),
            (unsupported, [.global(.continueWatching), .global(.watchlist), fallbackID, .libraries]),
            (.init(defaults: .matchServer),
             [.global(.continueWatching), .global(.watchlist), fallbackID, .libraries])
        ]
        for (customization, expected) in cases {
            let visibility = HomeLibraryVisibility(rowCustomization: customization)
            XCTAssertEqual(visibility.rowSections(choices: choices).enabled, expected)
            XCTAssertEqual(customization.sections(choices: choices).enabled, expected)
        }
    }

    func testLibrariesCanBeMovedOrHiddenAfterEitherPresetAndKeepThatChoice() throws {
        for preset: HomeRowCustomization.Defaults in [.matchServer, .combined] {
            var visibility = HomeLibraryVisibility(rowCustomization: .init(defaults: preset))
            let choices = HomeRowChoice.shared
            var sections = visibility.rowSections(choices: choices)
            XCTAssertEqual(sections.enabled.last, .libraries)
            sections.enabled.removeAll { $0 == .libraries }
            sections.enabled.insert(.libraries, at: 0)
            visibility.applyRows(sections, choices: choices)
            XCTAssertEqual(visibility.rowCustomization?.defaults, .custom)
            let restored = try JSONDecoder().decode(
                HomeLibraryVisibility.self, from: JSONEncoder().encode(visibility)
            )
            XCTAssertEqual(restored.rowSections(choices: choices).enabled, sections.enabled)
            sections.enabled.removeFirst()
            sections.disabled.append(.libraries)
            visibility.applyRows(sections, choices: choices)
            XCTAssertEqual(visibility.rowSections(choices: choices), sections)
        }
    }

    func testVisibilityEditFreezesThePresentedPresetOrderInsteadOfServerLibraryPosition() {
        var customization = HomeRowCustomization(defaults: .matchServer)
        customization.resolvedDefaults = .init(
            mode: .server, order: [.libraries, .global(.continueWatching), .liveTV]
        )
        customization.setVisible(false, for: .global(.continueWatching))
        XCTAssertEqual(customization.defaults, .custom)
        XCTAssertEqual(customization.sections(choices: HomeRowChoice.shared).enabled, [.liveTV, .libraries])
    }

    func testDefaultLibraryPositionDoesNotEnableAServerHiddenLibraryRowOrRewriteOldOrders() {
        var matched = HomeRowCustomization(defaults: .matchServer)
        matched.resolvedDefaults = .init(mode: .server, order: [.global(.continueWatching)])
        XCTAssertEqual(matched.sections(choices: HomeRowChoice.shared).enabled, [.global(.continueWatching)])
        for preset: HomeRowCustomization.Defaults in [.custom, .combined, .legacy, .provider] {
            let saved = HomeRowCustomization(
                defaults: preset, order: [.libraries, .global(.continueWatching)],
                shown: [.libraries, .global(.continueWatching)]
            )
            XCTAssertEqual(saved.sections(choices: HomeRowChoice.shared).enabled.first, .libraries)
        }
    }

    func testProviderDefaultsMergeNextUpAndOfferLatestButNotMediaBrowserRecommendations() {
        let visibility = HomeLibraryVisibility.default
        let movies = library("a", "movies")
        let shows = library("a", "shows", kind: .series)
        XCTAssertEqual(visibility.requestedRowKinds(for: movies), [.recentlyAdded])
        XCTAssertEqual(visibility.requestedRowKinds(for: shows), [.recentlyAdded])
        XCTAssertEqual(
            visibility.requestedRowKinds(for: library("b", "movies", provider: .plex)),
            [.recentlyAdded, .hubs]
        )
        XCTAssertEqual(
            LibraryHomeRowKind.available(for: library("a", "files", provider: .mediaShare)),
            [.recentlyAdded]
        )
        XCTAssertFalse(visibility.isGlobalRowEnabled(.recentlyAdded))
        XCTAssertFalse(visibility.separatesNextUp)
        var separate = visibility
        separate.mergeNextUpIntoContinueWatching = false
        XCTAssertEqual(separate.requestedRowKinds(for: shows), [.nextUp, .recentlyAdded])
        XCTAssertTrue(separate.separatesNextUp)
    }

    func testNextUpMergeWorksWithEveryPresetAndRestoresSavedRows() throws {
        let shows = library("a", "shows", kind: .series)
        let next = HomeServerRowDefinition(
            accountID: "a", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "native-next", kind: .nextUp)
        )
        let choices = HomeRowChoice.shared + HomeRowChoice.baseRows(for: shows)
            + [HomeRowChoice(serverRow: next)]
        for preset in HomeRowCustomization.Defaults.allCases {
            var customization = HomeRowCustomization(
                defaults: preset, order: [next.id, .global(.continueWatching), .libraries],
                shown: [next.id, .global(.continueWatching)],
                serverRows: [next]
            )
            if preset == .matchServer {
                customization.resolvedDefaults = .init(
                    mode: .server, order: customization.order, serverRows: [next]
                )
            }
            var visibility = HomeLibraryVisibility(
                rowCustomization: customization, mergeNextUpIntoContinueWatching: false
            )
            let before = visibility.rowSections(choices: choices)
            let requests = visibility.requestedRowKinds(for: shows)
            visibility.mergeNextUpIntoContinueWatching = true
            XCTAssertFalse(visibility.separatesNextUp, preset.rawValue)
            XCTAssertFalse(visibility.requestedRowKinds(for: shows).contains(.nextUp))
            XCTAssertFalse(visibility.rowSections(choices: choices).enabled.contains(next.id))
            XCTAssertEqual(visibility.rowCustomization, customization, "Merging must not replace the preset")
            XCTAssertEqual(
                visibility.rowSections(choices: choices).enabled,
                before.enabled.filter { $0 != next.id && $0.libraryKind != .nextUp }
            )
            let decoded = try JSONDecoder().decode(
                HomeLibraryVisibility.self, from: JSONEncoder().encode(visibility)
            )
            XCTAssertTrue(decoded.mergeNextUpIntoContinueWatching)
            visibility.mergeNextUpIntoContinueWatching = false
            XCTAssertEqual(visibility.rowSections(choices: choices), before)
            XCTAssertEqual(visibility.requestedRowKinds(for: shows), requests)
        }
    }

    func testEditingWhileMergedPreservesNativeAndLibraryNextUpPositionsAndHiddenChoices() {
        let shows = library("a", "shows", kind: .series)
        let next = HomeServerRowDefinition(
            accountID: "a", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "native-next", kind: .nextUp)
        )
        let libraryNext = HomeRowID.library(shows.key, kind: .nextUp)
        let latest = HomeRowID.library(shows.key, kind: .recentlyAdded)
        let choices = HomeRowChoice.shared + HomeRowChoice.baseRows(for: shows)
            + [HomeRowChoice(serverRow: next)]
        for preset: HomeRowCustomization.Defaults in [.matchServer, .custom] {
            var customization = HomeRowCustomization(
                defaults: preset,
                order: [.global(.continueWatching), next.id, latest, .libraries, libraryNext],
                hidden: [libraryNext, .global(.watchlist), .global(.recentlyAdded), .liveTV],
                shown: [.global(.continueWatching), next.id, latest, .libraries], serverRows: [next]
            )
            if preset == .matchServer {
                customization.resolvedDefaults = .init(
                    mode: .server, order: customization.order, serverRows: [next]
                )
            }
            var visibility = HomeLibraryVisibility(
                rowCustomization: customization, mergeNextUpIntoContinueWatching: true
            )
            let editable = choices.filter { !visibility.isMergedHomeRow($0) }
            var edited = visibility.rowSections(choices: editable)
            edited.enabled = [.libraries, latest, .global(.continueWatching)]
            visibility.applyRows(edited, choices: choices)
            XCTAssertEqual(visibility.rowSections(choices: editable).enabled, edited.enabled)
            visibility.mergeNextUpIntoContinueWatching = false
            let restored = visibility.rowSections(choices: choices)
            XCTAssertEqual(restored.enabled, [.libraries, next.id, latest, .global(.continueWatching)])
            XCTAssertTrue(restored.disabled.contains(libraryNext))
            XCTAssertEqual(visibility.rowCustomization?.serverRows, [next])
        }
    }

    func testHidingContinueWatchingSuspendsMergeWithoutLosingThePreference() {
        let shows = library("a", "shows", kind: .series)
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .provider), mergeNextUpIntoContinueWatching: true
        )
        XCTAssertFalse(visibility.requestedRowKinds(for: shows).contains(.nextUp))
        visibility.setGlobalRowEnabled(false, for: .continueWatching)
        XCTAssertTrue(visibility.mergeNextUpIntoContinueWatching)
        XCTAssertFalse(visibility.mergesNextUpRows)
        XCTAssertTrue(visibility.requestedRowKinds(for: shows).contains(.nextUp))
        visibility.setGlobalRowEnabled(true, for: .continueWatching)
        XCTAssertTrue(visibility.mergesNextUpRows)
    }

    @MainActor
    func testNextUpMergeIsProfileScopedAndSurvivesPresetChanges() throws {
        let suite = "HomeNextUp.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = HomeLibraryVisibilityStore(defaults: defaults)
        let other = HomeLibraryVisibilityStore(defaults: defaults, namespace: "other")
        let model = HomeLibraryVisibilityModel(store: primary)
        XCTAssertTrue(model.visibility.mergeNextUpIntoContinueWatching)
        model.setMergeNextUpIntoContinueWatching(false)
        for preset in HomeRowCustomization.Defaults.allCases {
            model.useRowDefaults(preset)
            XCTAssertFalse(model.visibility.mergeNextUpIntoContinueWatching)
            XCTAssertFalse(HomeLibraryVisibilityModel(store: primary).visibility.mergeNextUpIntoContinueWatching)
        }
        XCTAssertTrue(HomeLibraryVisibilityModel(store: other).visibility.mergeNextUpIntoContinueWatching)
        let legacy = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.mergeNextUpIntoContinueWatching)
        XCTAssertFalse(legacy.separatesNextUp)
    }

    func testNextUpDefaultsOnForEveryPresetAndPreservesEncodedChoices() throws {
        for preset in HomeRowCustomization.Defaults.allCases {
            var visibility = HomeLibraryVisibility(rowCustomization: .init(defaults: preset))
            XCTAssertTrue(visibility.mergeNextUpIntoContinueWatching, preset.rawValue)
            for enabled in [true, false] {
                visibility.mergeNextUpIntoContinueWatching = enabled
                let decoded = try JSONDecoder().decode(
                    HomeLibraryVisibility.self, from: JSONEncoder().encode(visibility)
                )
                XCTAssertEqual(decoded.mergeNextUpIntoContinueWatching, enabled, preset.rawValue)
            }
        }
    }

    func testOneOrderFreelyMixesSharedAndIndividualRowsAcrossLibraries() {
        let a = library("a", "movies")
        let b = library("b", "shows", kind: .series)
        let choices = HomeRowChoice.shared + HomeRowChoice.baseRows(for: a) + HomeRowChoice.baseRows(for: b)
        let order: [HomeRowID] = [
            .library(b.key, kind: .recentlyAdded), .global(.continueWatching),
            .library(a.key, kind: .recentlyAdded), .libraries, .library(b.key, kind: .nextUp),
            .global(.watchlist)
        ]
        var visibility = HomeLibraryVisibility.default
        visibility.mergeNextUpIntoContinueWatching = false
        visibility.applyRows(.init(enabled: order, disabled: [.global(.recentlyAdded)]), choices: choices)
        XCTAssertEqual(visibility.rowSections(choices: choices).enabled, order)
    }

    func testHiddenRecommendationSurvivesAChangedHeading() {
        let source = library("a", "movies")
        let id = HomeRowID.library(key: source.key, section: "recommendation:similar:0")
        var visibility = HomeLibraryVisibility.default
        visibility.rowCustomization?.setVisible(false, for: id)
        let renamed = HomeRowChoice(
            id: id, title: "A new recommendation", library: source, isProviderDefault: true
        )
        XCTAssertFalse(visibility.isHomeRowVisible(renamed))
    }

    func testOfflineRowsKeepPositionAndVisibilityWhenAnotherDeviceEditsItsAvailableRows() {
        let a = library("a", "movies")
        let b = library("b", "movies")
        let aID = HomeRowID.library(a.key, kind: .recentlyAdded)
        let bID = HomeRowID.library(b.key, kind: .recentlyAdded)
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(order: [aID, bID, .libraries], hidden: [bID])
        )
        let online = HomeRowChoice.baseRows(for: a) + HomeRowChoice.shared.filter { $0.id == .libraries }
        visibility.applyRows(.init(enabled: [.libraries, aID], disabled: []), choices: online)
        XCTAssertEqual(visibility.rowCustomization?.order, [.libraries, bID, aID])
        XCTAssertEqual(visibility.rowCustomization?.hidden, [bID])
        let reconnected = online + HomeRowChoice.baseRows(for: b)
        XCTAssertEqual(visibility.rowSections(choices: reconnected).disabled, [bID])
    }

    func testLegacyAllOffAndOfflineFamilyChoicesSurviveFirstFlatEdit() throws {
        let data = Data("""
        {"mergeLibrariesOnHome":false,"disabledKeys":[],
         "disabledGlobalHomeRows":["continueWatching","watchlist","recentlyAdded"],
         "enabledLibraryHomeRows":["offline:movies:recentlyAdded"],"hasSeededLibraryRows":true}
        """.utf8)
        var visibility = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)
        XCTAssertNil(visibility.rowCustomization)
        let choices = HomeRowChoice.shared
        visibility.applyRows(.init(enabled: [], disabled: choices.map(\.id)), choices: choices)
        XCTAssertEqual(visibility.rowCustomization?.defaults, .legacy)
        XCTAssertTrue(visibility.rowSections(choices: choices).enabled.isEmpty)
        XCTAssertEqual(
            visibility.requestedRowKinds(for: library("offline", "movies")),
            [.recentlyAdded]
        )
    }

    func testExplicitlyShowingOneEmbyRecommendationDoesNotEnableItsSiblings() {
        let source = library("a", "movies")
        let one = HomeRowChoice(
            id: .library(key: source.key, section: "one"), title: "One",
            library: source, isProviderDefault: false
        )
        let two = HomeRowChoice(
            id: .library(key: source.key, section: "two"), title: "Two",
            library: source, isProviderDefault: false
        )
        var visibility = HomeLibraryVisibility.default
        let base = HomeRowChoice.baseRows(for: source)
        let defaults = visibility.rowSections(choices: base)
        visibility.applyRows(
            .init(enabled: defaults.enabled + [one.id], disabled: defaults.disabled + [two.id]),
            choices: base + [one, two]
        )
        XCTAssertTrue(visibility.isHomeRowVisible(one))
        XCTAssertFalse(visibility.isHomeRowVisible(two))
        XCTAssertEqual(visibility.requestedRowKinds(for: source), [.recentlyAdded, .hubs])
    }

    func testHidingEveryKnownPlexRecommendationStopsItsRequests() {
        let source = library("a", "movies", provider: .plex)
        let ids = ["one", "two"].map { HomeRowID.library(key: source.key, section: $0) }
        let visibility = HomeLibraryVisibility(
            rowCustomization: .init(order: ids, hidden: Set(ids))
        )
        XCTAssertEqual(visibility.requestedRowKinds(for: source), [.recentlyAdded])
    }

    func testDisabledLibraryNeverFetchesEvenAnExplicitlyShownRow() {
        let source = library("a", "movies")
        let visibility = HomeLibraryVisibility(
            disabledKeys: [source.key],
            rowCustomization: .init(shown: [.library(key: source.key, section: "suggested")])
        )
        XCTAssertTrue(visibility.requestedRowKinds(for: source).isEmpty)
    }

    func testTypedIdentitiesCannotCollideWhenServerIDsContainSeparators() {
        let a = HomeRowID.library(key: "a-b", section: "c")
        let b = HomeRowID.library(key: "a", section: "b-c")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.presentationID, b.presentationID)
    }

    func testSavedVisibilityEncodesDeterministicallyAfterEveryDecode() throws {
        let ids: [HomeRowID] = [
            .libraries, .global(.watchlist), .library(key: "a:movies", section: "one"),
            .library(key: "b:movies", section: "two")
        ]
        let value = HomeLibraryVisibility(
            disabledKeys: ["x", "y", "z"],
            rowCustomization: .init(order: ids, hidden: Set(ids))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let expected = try encoder.encode(value)
        for _ in 0..<20 {
            let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: expected)
            XCTAssertEqual(try encoder.encode(decoded), expected)
        }
    }

    @MainActor
    func testArrangementPersistsAndTransfersOnlyWithItsProfile() throws {
        let sourceSuite = "HomeRows-source-\(UUID())"
        let targetSuite = "HomeRows-target-\(UUID())"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let target = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }
        let model = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: source, namespace: "one"))
        model.setContinueWatchingAction(.play)
        let choices = HomeRowChoice.shared
        model.applyRows(
            .init(enabled: [.libraries, .global(.continueWatching)],
                  disabled: [.global(.watchlist), .global(.recentlyAdded)]),
            choices: choices
        )
        let entries = ProfileSettingsTransfer.capture(namespace: "one", defaults: source)
        ProfileSettingsTransfer.apply(entries, namespace: "one", defaults: target)
        let restored = HomeLibraryVisibilityStore(defaults: target, namespace: "one").load()
        XCTAssertEqual(restored, model.visibility)
        XCTAssertEqual(restored.continueWatchingAction, .play)
        XCTAssertEqual(HomeLibraryVisibilityStore(defaults: target, namespace: "two").load(), .default)
        XCTAssertEqual(
            ProfileSettingsTransfer.capture(namespace: "one", defaults: target), entries
        )
    }
}
