import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPrototypeModelTests: XCTestCase {
    func testALineupPreparedInTheBackgroundPublishesWhatAMainActorBuildWould() async throws {
        let lineup = (1...300).map { index in
            LiveTVPrototypeChannel(
                id: "c\(index)", number: 301 - index, name: "  US|  Channel \(index)  H D", category: "G\(index % 7)",
                symbol: "tv", accent: 0, source: .iptv, tagline: "", configuredSourceID: "s",
                language: index.isMultiple(of: 2) ? "en" : "fr", country: "US", groups: ["G\(index % 7)", "All"]
            )
        }
        func assertSame(_ lhs: LiveTVPrototypeModel, _ rhs: LiveTVPrototypeModel, line: UInt = #line) {
            XCTAssertEqual(lhs.channels, rhs.channels, line: line)
            XCTAssertEqual(lhs.visibleChannels, rhs.visibleChannels, line: line)
            XCTAssertEqual(lhs.guideChannels, rhs.guideChannels, line: line)
            XCTAssertEqual(lhs.guideRowIDs, rhs.guideRowIDs, line: line)
            XCTAssertEqual(lhs.browsingCategories, rhs.browsingCategories, line: line)
            XCTAssertEqual(lhs.categoryChannelCount(nil), rhs.categoryChannelCount(nil), line: line)
            XCTAssertEqual(lhs.categorySummaries, rhs.categorySummaries, line: line)
            XCTAssertEqual(lhs.hiddenChannelEntries, rhs.hiddenChannelEntries, line: line)
            XCTAssertEqual(lhs.languages, rhs.languages, line: line)
            XCTAssertEqual(lhs.countries, rhs.countries, line: line)
            XCTAssertEqual(lhs.organizationCountries, rhs.organizationCountries, line: line)
            XCTAssertEqual(lhs.favoriteIDs, rhs.favoriteIDs, line: line)
        }

        func cleaning() -> LiveTVPrototypeModel {
            let model = LiveTVPrototypeModel(channels: [])
            model.cleanChannelNames = true
            return model
        }

        let direct = cleaning()
        try direct.replaceCatalog(channels: lineup, programs: [])
        XCTAssertEqual(direct.preparedInstallCount, 0)
        XCTAssertEqual(direct.channel(id: "c1")?.name, "US | Channel 1 HD")

        let prepared = cleaning()
        await prepared.prepareCatalog(channels: lineup)
        try prepared.replaceCatalog(channels: lineup, programs: [])
        XCTAssertEqual(prepared.preparedInstallCount, 1)
        assertSame(prepared, direct)

        // A build prepared before browsing changed is not what the guide should show.
        let changed = cleaning()
        await changed.prepareCatalog(channels: lineup)
        changed.category = "G3"
        changed.sort = .name
        try changed.replaceCatalog(channels: lineup, programs: [])
        XCTAssertEqual(changed.preparedInstallCount, 0)
        let reference = cleaning()
        reference.category = "G3"
        reference.sort = .name
        try reference.replaceCatalog(channels: lineup, programs: [])
        assertSame(changed, reference)
        XCTAssertEqual(changed.visibleChannels.count, 43)

        // Nor is one prepared for a different lineup.
        let other = cleaning()
        await other.prepareCatalog(channels: Array(lineup.dropLast()))
        try other.replaceCatalog(channels: lineup, programs: [])
        XCTAssertEqual(other.preparedInstallCount, 0)
        assertSame(other, direct)
    }

    func testReturningToLiveTVWithNothingChangedKeepsTheDerivedLists() throws {
        let lineup = (1...20).map { searchChannel("c\($0)", $0, "Channel \($0)", category: "G\($0 % 3)") }
        let model = LiveTVPrototypeModel(channels: [])
        try model.replaceCatalog(channels: lineup, programs: [])
        let revision = model.catalogRevision
        let rows = model.guideChannels

        model.reloadPreferences()
        XCTAssertEqual(model.catalogRevision, revision)
        XCTAssertEqual(model.guideChannels, rows)

        // Guide-only rows follow listings, so they are always derived again.
        model.guideOnly = true
        let guideOnly = model.catalogRevision
        model.reloadPreferences()
        XCTAssertNotEqual(model.catalogRevision, guideOnly)
    }

    func testCategoryCountsIgnoreCurrentCategoryAndQueryButHonorEligibility() {
        let grouped = LiveTVPrototypeChannel(
            id: "shared", number: 1, name: "Arena", category: "Sports", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", groups: ["Sports", "News", "Spórts"]
        )
        let model = LiveTVPrototypeModel(channels: [
            grouped, searchChannel("world", 2, "World", category: "Sports"),
            searchChannel("news", 3, "Daily News", category: "News", source: .jellyfin)
        ], preferencesStore: HiddenChannelsFixtureStore())
        XCTAssertEqual(model.categoryChannelCount(nil), 3)
        XCTAssertEqual(model.categoryChannelCount("Sports"), 2)
        XCTAssertEqual(model.categoryChannelCount("Spórts"), 2)
        XCTAssertEqual(model.categoryChannelCount("News"), 2)
        model.category = "Sports"
        model.query = "arena"
        XCTAssertEqual(model.visibleChannels.count, 1)
        XCTAssertEqual(model.categoryChannelCount("Sports"), 2)
        XCTAssertEqual(model.categoryChannelCount("News"), 2)
        model.source = .jellyfin
        XCTAssertEqual(model.categoryChannelCount(nil), 1)
        XCTAssertEqual(model.browsingCategories.map(\.name), ["News"])
        model.source = nil
        model.setScanHiddenChannelIDs(["shared"])
        XCTAssertEqual(model.categoryChannelCount("Sports"), 1)
        XCTAssertEqual(model.categoryChannelCount("News"), 1)
        model.toggleFavorite("world")
        model.favoritesOnly = true
        XCTAssertEqual(model.browsingCategories.map(\.name), ["Sports"])
        XCTAssertEqual(model.categoryChannelCount(nil), 1)
    }

    func testCategoryFirstFocusDoesNotRequestGuideFocusOrPreviewPlayback() {
        let model = LiveTVPrototypeModel(channels: [searchChannel("arena", 1, "Arena", category: "Sports")])
        let preview = LiveTVPreviewController(model: model, followsFocus: true)
        XCTAssertFalse(preview.requestInitialCategoryFocus(isActive: false, hasOverlay: false))
        XCTAssertFalse(preview.requestInitialCategoryFocus(isActive: true, hasOverlay: true))
        XCTAssertTrue(preview.requestInitialCategoryFocus(isActive: true, hasOverlay: false))
        XCTAssertTrue(preview.hasRequestedInitialGuideFocus)
        XCTAssertFalse(preview.isRestoringGuideFocus)
        XCTAssertNil(preview.pendingRequest)
        XCTAssertNil(model.playingChannelID)
        XCTAssertFalse(preview.requestInitialCategoryFocus(isActive: true, hasOverlay: false))
        XCTAssertNil(preview.requestInitialGuideFocus(isActive: true, hasOverlay: false))
    }

    func testCategorySearchReturnsDistinctCategoryMatchesAlongsideChannelMatches() {
        let model = LiveTVPrototypeModel(channels: [
            searchChannel("arena", 1, "Arena", category: "Spórts"),
            searchChannel("stadium", 2, "Stadium", category: "Spórts"),
            searchChannel("world", 3, "World", category: "International Sports"),
            searchChannel("review", 4, "Sports Review", category: "Entertainment"),
            searchChannel("news", 5, "Daily News", category: "News")
        ])
        XCTAssertTrue(model.matchingCategories.isEmpty)
        model.query = " SPORT "
        XCTAssertEqual(model.matchingCategories, ["International Sports", "Spórts"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["arena", "stadium", "review", "world"])
        model.query = "arena"
        XCTAssertTrue(model.matchingCategories.isEmpty, "A channel-name match must not imply a category-name match")
        XCTAssertEqual(model.visibleChannels.map(\.id), ["arena"])
        model.query = "  "
        XCTAssertTrue(model.matchingCategories.isEmpty)
        XCTAssertEqual(model.visibleChannels.count, 5)
    }

    func testCategorySearchRespectsSourceLanguageCountryFavoritesAndHiddenChannels() {
        let model = LiveTVPrototypeModel(channels: [
            searchChannel("local", 1, "Arena", category: "Sports", sourceID: "first", language: "en", country: "US"),
            searchChannel("world", 2, "World", category: "World Sports", sourceID: "second", language: "fr", country: "FR"),
            searchChannel("server", 3, "Stadium", category: "Live Sports", source: .jellyfin, sourceID: "server")
        ], preferencesStore: HiddenChannelsFixtureStore())
        model.query = "sports"
        XCTAssertEqual(model.matchingCategories, ["Live Sports", "Sports", "World Sports"])
        model.source = .iptv
        XCTAssertEqual(model.matchingCategories, ["Sports", "World Sports"])
        model.playlistSourceID = "first"
        XCTAssertEqual(model.matchingCategories, ["Sports"])
        model.playlistSourceID = nil
        model.language = "fr"
        XCTAssertEqual(model.matchingCategories, ["World Sports"])
        model.language = nil
        model.country = "US"
        XCTAssertEqual(model.matchingCategories, ["Sports"])
        model.country = nil
        model.toggleFavorite("world")
        model.favoritesOnly = true
        XCTAssertEqual(model.matchingCategories, ["World Sports"])
        model.favoritesOnly = false
        model.setScanHiddenChannelIDs(["local"])
        XCTAssertEqual(model.matchingCategories, ["World Sports"])
        XCTAssertTrue(model.hideChannel(model.channel(id: "world")!))
        XCTAssertTrue(model.matchingCategories.isEmpty)
        model.resetFilters()
        XCTAssertTrue(model.matchingCategories.isEmpty)
    }

    func testCategorySearchHonorsSelectedCategoryAndGuideCoverage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grouped = LiveTVPrototypeChannel(
            id: "shared", number: 1, name: "Arena", category: "Sports", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", groups: ["Sports", "News", "Sports"]
        )
        let model = LiveTVPrototypeModel(now: now, channels: [
            grouped, searchChannel("world", 2, "World", category: "World Sports")
        ], preferencesStore: HiddenChannelsFixtureStore())
        model.query = "sports"
        model.category = "News"
        XCTAssertEqual(model.matchingCategories, ["Sports"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["shared"])
        model.guideOnly = true
        XCTAssertTrue(model.matchingCategories.isEmpty)
        try model.replacePrograms([
            .init(id: "program", channelID: "shared", title: "Live match", subtitle: "",
                  start: now, end: now.addingTimeInterval(3_600))
        ])
        XCTAssertEqual(model.matchingCategories, ["Sports"])
        model.guideOnly = false
        model.category = nil
        XCTAssertTrue(model.setMetadataOverride(.init(category: "Sports Classics"), channelID: "shared"))
        XCTAssertEqual(model.matchingCategories, ["Sports Classics", "World Sports"])
        try model.replaceChannels([searchChannel("news", 3, "Daily News", category: "News")])
        XCTAssertTrue(model.matchingCategories.isEmpty)
    }

    private func searchChannel(
        _ id: String, _ number: Int, _ name: String, category: String,
        source: LiveTVPrototypeSource = .iptv, sourceID: String = "sample",
        language: String? = nil, country: String? = nil
    ) -> LiveTVPrototypeChannel {
        .init(id: id, number: number, name: name, category: category, symbol: "tv", accent: 0,
              source: source, tagline: "", configuredSourceID: sourceID, language: language, country: country)
    }

    func testCategorySelectionInLargeCatalogDoesNotRescanEveryChannel() async throws {
        let channels = await Task.detached {
            (0..<100_000).map { index in
                LiveTVPrototypeChannel(
                    id: "large-\(index)", number: index, name: "Channel \(index)",
                    category: "Group \(index % 100)", symbol: "tv", accent: 0,
                    source: .iptv, tagline: ""
                )
            }
        }.value
        let model = LiveTVPrototypeModel(channels: channels)
        let start = ContinuousClock.now
        for category in 0..<20 {
            model.category = "Group \(category)"
            XCTAssertEqual(model.visibleChannels.count, 1_000)
            XCTAssertEqual(model.visibleChannels.first?.number, category)
            XCTAssertEqual(model.visibleChannels.last?.number, 99_900 + category)
        }
        let elapsed = start.duration(to: .now)
        print("Live TV category selection: channels=100000 selections=20 elapsed=\(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "Repeated category changes must use the catalogue index, not normalize every channel again")
    }

    func testHundredThousandImportedChannelsRemainBrowsableInBothSortOrders() async throws {
        let channels = await Task.detached {
            (0..<100_000).map { index in
                LiveTVPrototypeChannel(
                    id: "large-\(index)", number: index + 1,
                    name: "Channel \(100_000 - index)", category: "Group \(index % 80)",
                    symbol: "tv", accent: 0, source: .iptv, tagline: "",
                    language: "English", country: "US"
                )
            }
        }.value
        for count in [10_000, 100_000] {
            for sort in [LiveTVPrototypeSort.channelNumber, .name] {
                let model = LiveTVPrototypeModel(channels: [])
                model.sort = sort
                let input = Array(channels.prefix(count))
                try model.replaceCatalog(channels: input, programs: [])
                XCTAssertEqual(model.channels.count, count)
                XCTAssertEqual(model.visibleChannels.count, count)
                XCTAssertEqual(model.guideChannels.count, count)
                XCTAssertEqual(model.categories.count, 80)
                XCTAssertEqual(model.languages, ["English"])
                XCTAssertEqual(model.countries, ["US"])
                XCTAssertEqual(Set(model.guideRowIDs.map(\.channelID)), Set(input.map(\.id)))
                for (left, right) in zip(model.visibleChannels, model.visibleChannels.dropFirst()) {
                    if sort == .name { XCTAssertLessThan(left.name, right.name) }
                    else { XCTAssertLessThan(left.number, right.number) }
                }
            }
        }
    }

    func testPreparedBrowseKeysPreserveRelevanceTieBreaksAndMetadataFacets() throws {
        let channels = [
            LiveTVPrototypeChannel(
                id: "b", number: 7, name: "cafe", category: "Sports", symbol: "tv", accent: 0,
                source: .iptv, tagline: "", language: " English / German ", country: " CA / DE "
            ),
            LiveTVPrototypeChannel(
                id: "a", number: 7, name: " Café ", category: "International", symbol: "tv", accent: 0,
                source: .iptv, tagline: "", language: "English;Français", country: "US, CA",
                groups: ["News", "Europe"]
            ),
            LiveTVPrototypeChannel(
                id: "c", number: 1, name: "cafe 7", category: "News", symbol: "tv", accent: 0,
                source: .iptv, tagline: ""
            ),
            LiveTVPrototypeChannel(
                id: "d", number: 99, name: "7 network", category: "Sports", symbol: "tv", accent: 0,
                source: .iptv, tagline: "", language: " English / German ", country: " CA / DE "
            )
        ]
        let model = LiveTVPrototypeModel(channels: [])
        try model.replaceCatalog(channels: channels, programs: [])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["c", "a", "b", "d"])
        XCTAssertEqual(model.categories, ["Europe", "News", "Sports"])
        XCTAssertEqual(model.languages, ["English", "Français", "German"])
        XCTAssertEqual(model.countries, ["CA", "DE", "US"])

        model.sort = .name
        XCTAssertEqual(model.visibleChannels.map(\.id), ["d", "a", "b", "c"])
        model.query = "7"
        XCTAssertEqual(model.visibleChannels.map(\.id), ["a", "b", "d", "c"])
        model.query = ""
        model.language = "francais"
        XCTAssertEqual(model.visibleChannels.map(\.id), ["a"])
        model.language = nil
        model.country = " de "
        XCTAssertEqual(model.visibleChannels.map(\.id), ["d", "b"])
        model.country = nil
        XCTAssertTrue(model.hideChannel(channels[1]))
        XCTAssertEqual(model.categories, ["News", "Sports"])
        XCTAssertEqual(model.languages, ["English", "German"])
        XCTAssertEqual(model.countries, ["CA", "DE"])
    }

    func testCategoryIndexPreservesNormalizedGroupsAndTracksCatalogMutations() throws {
        let store = HiddenChannelsFixtureStore()
        let grouped = LiveTVPrototypeChannel(
            id: "grouped", number: 3, name: "Grouped", category: "Unused", symbol: "tv", accent: 0,
            source: .iptv, tagline: "", groups: ["News", " NEWS ", "Néws", "Sports"]
        )
        let model = LiveTVPrototypeModel(channels: hiddenChannelFixtures + [grouped], preferencesStore: store)
        model.category = " news "
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news", "grouped"], "Aliases must not duplicate a channel")
        model.setScanHiddenChannelIDs(["news"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["grouped"])
        model.setScanHiddenChannelIDs([])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news", "grouped"])
        XCTAssertTrue(model.hideChannel(grouped))
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news"])
        store.value = store.value.restoringAllChannels()
        model.reloadPreferences()
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news", "grouped"])
        XCTAssertTrue(model.setMetadataOverride(.init(category: "Movies"), channelID: "grouped"))
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news"])
        model.category = "movies"
        XCTAssertEqual(model.visibleChannels.map(\.id), ["grouped"])
        try model.replaceChannels(Array(hiddenChannelFixtures.reversed()))
        XCTAssertTrue(model.visibleChannels.isEmpty)
        model.category = "sports"
        XCTAssertEqual(model.visibleChannels.map(\.id), ["sports"])
        model.category = nil
        XCTAssertEqual(model.visibleChannels.map(\.id), ["news", "sports"])
    }

    func testConfiguredCatalogUsesOnlySuppliedChannelsAndListings() throws {
        let channel = LiveTVPrototypeChannel(
            id: "configured-channel", number: 1, name: "Configured channel", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: ""
        )
        let model = LiveTVPrototypeModel(channels: [channel])
        XCTAssertEqual(model.channels, [channel])
        XCTAssertTrue(model.favoriteIDs.isEmpty)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        for scenario in LiveTVPrototypeScenario.allCases {
            model.scenario = scenario
            XCTAssertTrue(model.programs(for: channel.id, from: model.now).isEmpty)
        }
        let program = LiveTVPrototypeProgram(
            id: "configured-program", channelID: channel.id, title: "Provided listing", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(1_800)
        )
        try model.replacePrograms([program])
        XCTAssertEqual(model.currentProgram(for: channel.id), program)

        let preview = LiveTVPreviewController(model: model, followsFocus: false)
        preview.focus(channel.id)
        XCTAssertNil(model.playingChannelID)
        XCTAssertNil(preview.pendingRequest)
        preview.watch(channel.id)
        XCTAssertEqual(model.playingChannelID, channel.id)
        XCTAssertTrue(preview.isExpanded)
        preview.stop()
        XCTAssertNil(model.playingChannelID)
    }

    #if !DEBUG
    func testReleaseDefaultCatalogNeverSeedsSyntheticChannelsOrFavorites() {
        let model = LiveTVPrototypeModel(isLargeCatalog: true)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(model.favoriteIDs.isEmpty)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        XCTAssertTrue(model.guideChannels.isEmpty)
    }

    func testReleaseCatalogNeverCreatesStressCopies() {
        let channel = LiveTVPrototypeChannel(
            id: "configured-channel", number: 1, name: "Configured channel", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: ""
        )
        let model = LiveTVPrototypeModel(isLargeCatalog: true, channels: [channel])
        XCTAssertEqual(model.channels, [channel])
        model.isLargeCatalog = false
        model.isLargeCatalog = true
        XCTAssertEqual(model.channels, [channel])
    }
    #endif

    #if DEBUG
    func testNoGuideCatalogRemainsSearchableAndFavoritable() throws {
        let model = LiveTVPrototypeModel(scenario: .noGuide)

        XCTAssertEqual(model.channels.count, 30)
        XCTAssertEqual(model.channel(id: model.channels[0].id), model.channels[0])
        XCTAssertEqual(model.categories, model.categories.sorted())
        XCTAssertTrue(model.channels.allSatisfy {
            model.currentProgram(for: $0.id) == nil
                && model.programs(for: $0.id, from: model.now).isEmpty
        })

        model.query = "quiet channel"
        let channel = try XCTUnwrap(model.visibleChannels.first)
        XCTAssertEqual(channel.name, "Quiet Channel")
        XCTAssertFalse(model.favoriteIDs.contains(channel.id))

        model.toggleFavorite(channel.id)
        model.favoritesOnly = true

        XCTAssertEqual(model.visibleChannels.map(\.id), [channel.id])
    }

    func testGuideCoverageMatchesScenariosAndIncludesEveryPlozzChannel() {
        let model = LiveTVPrototypeModel(scenario: .noGuide)
        let coveredCount = {
            model.channels.filter {
                model.currentProgram(for: $0.id) != nil
            }.count
        }

        XCTAssertEqual(coveredCount(), 0)
        model.scenario = .failedGuide
        XCTAssertEqual(coveredCount(), 0)

        model.scenario = .mixedGuide
        let mixedCount = coveredCount()
        XCTAssertGreaterThan(mixedCount, 10)
        XCTAssertLessThan(mixedCount, 20)
        XCTAssertTrue(
            model.channels
                .filter { $0.source == .plozz }
                .allSatisfy { model.currentProgram(for: $0.id) != nil }
        )

        model.scenario = .fullGuide
        XCTAssertEqual(coveredCount(), 30)
        model.scenario = .staleGuide
        XCTAssertEqual(coveredCount(), 30)
    }

    func testProgramsUseStableAbsoluteSlotsAndBoundedRequests() throws {
        let model = LiveTVPrototypeModel(scenario: .fullGuide)
        let channel = try XCTUnwrap(model.channels.first)
        let requestedStart = Date(timeIntervalSince1970: 1_788_719_777)
        let first = model.programs(for: channel.id, from: requestedStart, hours: 3)

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy {
            [1_800.0, 3_600.0].contains($0.end.timeIntervalSince($0.start))
        })
        XCTAssertTrue(first.allSatisfy {
            Int($0.start.timeIntervalSince1970).isMultiple(of: 1_800)
        })
        XCTAssertLessThanOrEqual(
            model.programs(for: channel.id, from: requestedStart, hours: 200).count,
            7 * 24 * 2 + 1
        )

        model.advanceClock(by: 7_200)
        let second = model.programs(for: channel.id, from: requestedStart, hours: 3)
        XCTAssertEqual(second, first)
        let freshModel = LiveTVPrototypeModel(scenario: .fullGuide)
        XCTAssertEqual(
            freshModel.programs(for: channel.id, from: requestedStart, hours: 3),
            first
        )

        let program = try XCTUnwrap(first.first)
        XCTAssertEqual(program.progress(at: program.start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(program.progress(at: program.end.addingTimeInterval(1)), 1)
        XCTAssertEqual(
            program.progress(at: program.start.addingTimeInterval(program.end.timeIntervalSince(program.start) / 2)),
            0.5,
            accuracy: 0.000_001
        )
    }

    func testFiltersCombineResetAndPreserveSort() {
        let model = LiveTVPrototypeModel()
        model.sort = .name
        model.query = "CINÉMA"
        model.category = "Movies"
        model.source = .jellyfin
        model.favoritesOnly = true

        XCTAssertEqual(model.visibleChannels.map(\.name), ["Cinema Club"])

        model.resetFilters()

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.category)
        XCTAssertNil(model.source)
        XCTAssertFalse(model.favoritesOnly)
        XCTAssertEqual(model.sort, .name)
        XCTAssertEqual(model.visibleChannels.count, 30)
        XCTAssertEqual(
            model.visibleChannels.map(\.name),
            model.visibleChannels.map(\.name).sorted {
                let locale = Locale(identifier: "en_US_POSIX")
                return $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                    < $1.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            }
        )
    }

    func testSearchIsDiacriticInsensitiveAndRanksExactNumberFirst() {
        let model = LiveTVPrototypeModel()

        model.query = "cafe"
        XCTAssertEqual(model.visibleChannels.map(\.name), ["Café Society"])

        model.sort = .name
        model.query = "2"
        XCTAssertEqual(model.visibleChannels.first?.number, 2)
        XCTAssertTrue(model.visibleChannels.dropFirst().contains { $0.number == 20 })
    }

    func testLogoMetadataSurvivesCatalogExpansionAndHasSafePublicURLs() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let original = model.channels
        XCTAssertEqual(original.compactMap(\.logoURL).count, original.count)
        XCTAssertTrue(original.compactMap(\.logoURL).allSatisfy {
            $0.scheme == "https" && $0.user == nil && $0.password == nil
        })
        model.isLargeCatalog = true
        XCTAssertEqual(Array(model.channels.prefix(original.count)), original)
        XCTAssertEqual(model.channels[original.count].logoURL, original[0].logoURL)
        XCTAssertEqual(model.channels[original.count].streamURL, original[0].streamURL)
        let tastemade = try XCTUnwrap(model.channels.first { $0.name == "Tastemade" })
        XCTAssertTrue(tastemade.logoNeedsDarkBackground)
    }

    func testRealChannelsNeverAcquireSyntheticGuidePrograms() {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        XCTAssertTrue(model.usesPublicStreams)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, model.channels.count)
        XCTAssertEqual(model.channels.map(\.number), Array(1...model.channels.count))
        XCTAssertTrue(model.channels.allSatisfy {
            $0.source == .iptv && $0.streamURL?.scheme == "https"
                && $0.streamURL?.user == nil && $0.streamURL?.password == nil
        })
        for scenario in LiveTVPrototypeScenario.allCases {
            model.scenario = scenario
            XCTAssertTrue(model.channels.allSatisfy {
                model.programs(for: $0.id, from: model.now).isEmpty
            })
        }
        model.query = "espanol"
        XCTAssertEqual(model.visibleChannels.map(\.name), ["DW Español"])
    }

    func testImportedListingsDriveGuideWithoutFillingRealGaps() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let channel = model.channels[0]
        let start = model.now.addingTimeInterval(600)
        let program = LiveTVPrototypeProgram(
            id: "real-program", channelID: channel.id, title: "Actual listing",
            subtitle: "", start: start, end: start.addingTimeInterval(1_800)
        )
        try model.replacePrograms([program])
        XCTAssertEqual(model.guideChannelCount, 1)
        XCTAssertNil(model.currentProgram(for: channel.id))
        XCTAssertEqual(model.programs(for: channel.id, from: model.now, hours: 2), [program])
        XCTAssertTrue(model.programs(for: model.channels[1].id, from: model.now).isEmpty)
        model.synchronizeClock(to: start)
        XCTAssertEqual(model.currentProgram(for: channel.id), program)
        model.synchronizeClock(to: program.end)
        XCTAssertNil(model.currentProgram(for: channel.id))
    }

    func testCatalogAndGuideRefreshPreserveIndependentFiltersAndFavorites() throws {
        let model = LiveTVPrototypeModel(channels: [])
        try model.replaceChannels(LiveTVPrototypeCatalog.channels)
        XCTAssertTrue(model.favoriteIDs.isEmpty)
        let channel = model.channels[0]
        model.query = channel.name
        model.category = channel.category
        model.sort = .name
        model.toggleFavorite(channel.id)
        model.favoritesOnly = true
        model.guideOnly = true
        XCTAssertTrue(model.visibleChannels.isEmpty)

        let program = LiveTVPrototypeProgram(
            id: "listing", channelID: channel.id, title: "Actual listing", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(3_600)
        )
        try model.replacePrograms([program])
        try model.replaceChannels(Array(LiveTVPrototypeCatalog.channels.reversed()))
        XCTAssertEqual(model.visibleChannels, [channel])
        XCTAssertEqual(model.currentProgram(for: channel.id), program)
        XCTAssertEqual(model.query, channel.name)
        XCTAssertEqual(model.category, channel.category)
        XCTAssertEqual(model.sort, .name)
        XCTAssertTrue(model.favoritesOnly)
        XCTAssertTrue(model.guideOnly)
        model.resetFilters()
        XCTAssertFalse(model.guideOnly)
        XCTAssertFalse(model.favoritesOnly)
        XCTAssertTrue(model.favoriteIDs.contains(channel.id))
    }

    func testBadImportedDataDoesNotReplaceLastGoodData() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let original = model.channels
        XCTAssertThrowsError(try model.replaceChannels([original[0], original[0]]))
        XCTAssertEqual(model.channels, original)
        let program = LiveTVPrototypeProgram(
            id: "listing", channelID: original[0].id, title: "Listing", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(1_800)
        )
        try model.replacePrograms([program])
        XCTAssertThrowsError(try model.replacePrograms([program, program]))
        XCTAssertEqual(model.currentProgram(for: original[0].id), program)
        let invalid = LiveTVPrototypeProgram(
            id: "invalid", channelID: original[0].id, title: "Invalid", subtitle: "",
            start: model.now, end: model.now
        )
        XCTAssertThrowsError(try model.replacePrograms([invalid]))
        XCTAssertEqual(model.currentProgram(for: original[0].id), program)
        try model.replaceChannels(Array(original.dropFirst()))
        XCTAssertEqual(model.guideChannelCount, 0)
    }

    func testImportedGuideMetadataAndHeadersSurviveStressCopies() {
        let channel = LiveTVPrototypeChannel(
            id: "source-stream", number: 1, name: "Station", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: "provider.id", guideName: "Station HD",
            httpHeaders: ["User-Agent": "Test"]
        )
        let model = LiveTVPrototypeModel(isLargeCatalog: true, channels: [channel])
        XCTAssertEqual(model.channels[1].guideID, channel.guideID)
        XCTAssertEqual(model.channels[1].guideName, channel.guideName)
        XCTAssertEqual(model.channels[1].httpHeaders, channel.httpHeaders)
    }

    func testPrototypeLaunchPersistenceIsExplicitAndReversible() throws {
        let suite = "LiveTVPrototypeLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: ["--live-tv-prototype"], defaults: defaults))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: ["--live-tv-prototype-remember"], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(
            arguments: ["--live-tv-prototype-off", "--live-tv-prototype-remember", "--live-tv-prototype"],
            defaults: defaults
        ))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
    }

    func testLargeCatalogKeepsBaseIDsAndOffCatalogFavorites() throws {
        let model = LiveTVPrototypeModel()
        let baseIDs = model.channels.map(\.id)
        let baseFavoriteIDs = model.favoriteIDs

        model.isLargeCatalog = true

        XCTAssertEqual(model.channels.count, 5_000)
        XCTAssertEqual(Array(model.channels.prefix(30).map(\.id)), baseIDs)
        XCTAssertTrue(baseFavoriteIDs.isSubset(of: model.favoriteIDs))
        let largeOnlyID = try XCTUnwrap(model.channels.last?.id)
        model.toggleFavorite(largeOnlyID)

        model.isLargeCatalog = false
        XCTAssertTrue(model.favoriteIDs.contains(largeOnlyID))
        XCTAssertEqual(model.channels.count, 30)

        model.isLargeCatalog = true
        model.favoritesOnly = true
        XCTAssertTrue(model.visibleChannels.contains { $0.id == largeOnlyID })
    }

    func testShrinkingCatalogReleasesUnavailableDemoChannel() throws {
        let model = LiveTVPrototypeModel(isLargeCatalog: true)
        let largeOnlyID = try XCTUnwrap(model.channels.last?.id)
        model.tune(largeOnlyID)
        model.togglePause()
        model.advanceClock(by: 30)

        model.isLargeCatalog = false

        XCTAssertNil(model.playingChannelID)
        XCTAssertNil(model.previousChannelID)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)
    }

    func testTunePausePreviousBusyAndStopBehavior() throws {
        let model = LiveTVPrototypeModel()
        let first = try XCTUnwrap(model.channels.first?.id)
        let second = try XCTUnwrap(model.channels.dropFirst().first?.id)

        model.tune("not-a-fixture-channel")
        XCTAssertTrue(model.tuneFailed)
        XCTAssertNil(model.playingChannelID)
        model.clearTuneFailure()

        model.tune(first)
        XCTAssertEqual(model.playingChannelID, first)
        XCTAssertNil(model.previousChannelID)

        model.simulateTunerBusy = true
        model.tune(first)
        XCTAssertFalse(model.tuneFailed)
        model.tune(second)
        XCTAssertTrue(model.tuneFailed)
        XCTAssertEqual(model.playingChannelID, first)

        model.simulateTunerBusy = false
        model.tune(second)
        XCTAssertEqual(model.playingChannelID, second)
        XCTAssertEqual(model.previousChannelID, first)

        model.togglePause()
        model.advanceClock(by: 45)
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 45)
        model.togglePause()
        model.advanceClock(by: 15)
        XCTAssertEqual(model.behindLiveSeconds, 45)
        model.goLive()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)

        model.tunePrevious()
        XCTAssertEqual(model.playingChannelID, first)
        XCTAssertEqual(model.previousChannelID, second)
        model.tunePrevious()
        XCTAssertEqual(model.playingChannelID, second)
        XCTAssertEqual(model.previousChannelID, first)

        model.stop()
        XCTAssertNil(model.playingChannelID)
        XCTAssertNil(model.previousChannelID)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)
        XCTAssertFalse(model.tuneFailed)
    }

    #endif

    func testHidingChannelFiltersEverySectionWithoutErasingStateOrPlayback() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let hidden = channels[0]

        model.toggleFavorite(hidden.id)
        model.tune(hidden.id)
        XCTAssertTrue(model.recordWatched(hidden.id))
        XCTAssertTrue(model.hideChannel(hidden))

        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(model.channel(id: hidden.id), hidden)
        XCTAssertEqual(model.playingChannelID, hidden.id)
        XCTAssertTrue(model.favoriteIDs.contains(hidden.id))
        XCTAssertTrue(model.recentChannelIDs.contains(hidden.id))
        XCTAssertEqual(model.hiddenChannels, [
            LiveTVHiddenChannel(id: hidden.id, name: hidden.name),
        ])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertFalse(model.guideChannels.contains { $0.channel.id == hidden.id })
        XCTAssertFalse(model.categories.contains(hidden.category))

        model.query = hidden.name
        XCTAssertTrue(model.visibleChannels.isEmpty)
        model.resetFilters()
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertEqual(store.value.favoriteIDs, [hidden.id])
        XCTAssertEqual(store.value.recentChannelIDs, [hidden.id])
    }

    func testFavoriteAndRecentWritesPreserveHiddenMetadata() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)

        XCTAssertTrue(model.hideChannel(channels[0]))
        model.toggleFavorite(channels[1].id)
        model.tune(channels[1].id)
        XCTAssertTrue(model.recordWatched(channels[1].id))

        XCTAssertEqual(store.value.hiddenChannels, [
            LiveTVHiddenChannel(id: channels[0].id, name: channels[0].name),
        ])
        XCTAssertEqual(store.value.favoriteIDs, [channels[1].id])
        XCTAssertEqual(store.value.recentChannelIDs, [channels[1].id])
    }

    func testHiddenMissingSourceSurvivesCatalogReplacementAndReloadedRestore() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let hidden = channels[0]
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)

        XCTAssertTrue(model.hideChannel(hidden))
        try model.replaceChannels(Array(channels.dropFirst()))
        XCTAssertEqual(model.hiddenChannels.map(\.id), [hidden.id])
        XCTAssertEqual(store.value.hiddenChannels.map(\.id), [hidden.id])

        try store.save(store.value.restoringChannel(id: hidden.id))
        model.reloadPreferences()
        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })

        try model.replaceChannels(channels)
        XCTAssertTrue(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertTrue(model.categories.contains(hidden.category))
    }

    func testReloadRestoresHiddenChannelSubjectToCurrentFilters() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let hidden = channels[0]
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        model.category = hidden.category

        XCTAssertTrue(model.hideChannel(hidden))
        XCTAssertTrue(model.visibleChannels.isEmpty)
        try store.save(store.value.restoringAllChannels())

        model.reloadPreferences()

        XCTAssertEqual(model.category, hidden.category)
        XCTAssertEqual(model.visibleChannels, [hidden])
    }

    func testHiddenPreferenceSaveFailureRetriesWithoutLosingMutation() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        store.failSave = true

        XCTAssertFalse(model.hideChannel(channels[0]))
        XCTAssertEqual(model.preferencesIssue, .saveFailed)
        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertTrue(model.visibleChannels.contains { $0.id == channels[0].id })

        store.failSave = false
        model.reloadPreferences()

        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.hiddenChannels.map(\.id), [channels[0].id])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == channels[0].id })
    }

    func testReloadFailurePreservesLastKnownHiddenChannels() {
        let store = HiddenChannelsFixtureStore()
        store.value = LiveTVPreferences(
            hiddenChannels: [
                LiveTVHiddenChannel(id: hiddenChannelFixtures[0].id, name: "Saved Name"),
            ]
        )
        let model = LiveTVPrototypeModel(
            channels: hiddenChannelFixtures,
            preferencesStore: store
        )
        store.value = .empty
        store.failLoad = true

        model.reloadPreferences()

        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        XCTAssertEqual(model.hiddenChannels.map(\.id), [hiddenChannelFixtures[0].id])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hiddenChannelFixtures[0].id })
    }

    func testRetryingAFavoriteDoesNotUndoSettingsRestoration() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertTrue(model.hideChannel(channels[0]))
        store.failSave = true
        model.toggleFavorite(channels[1].id)
        store.value = store.value.restoringAllChannels()

        model.reloadPreferences()
        XCTAssertEqual(model.preferencesIssue, .saveFailed)
        store.failSave = false
        model.reloadPreferences()

        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertTrue(store.value.hiddenChannels.isEmpty)
        XCTAssertEqual(store.value.favoriteIDs, [channels[1].id])
    }

    func testRetryingHidePreservesNewFavoritesAndRecentsSavedElsewhere() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        store.failSave = true
        XCTAssertFalse(model.hideChannel(channels[0]))
        store.value = LiveTVPreferences(favoriteIDs: [channels[1].id], recentChannelIDs: [channels[1].id])
        store.failLoad = true
        model.reloadPreferences()
        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        store.failLoad = false
        store.failSave = false
        model.reloadPreferences()

        XCTAssertEqual(model.hiddenChannelIDs, [channels[0].id])
        XCTAssertEqual(model.favoriteIDs, [channels[1].id])
        XCTAssertEqual(model.recentChannelIDs, [channels[1].id])
    }

    func testMultiviewFavoritesSurviveOrdinaryChannelPreferenceChanges() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let favorite = LiveTVMultiviewFavorite(
            id: "saved", name: "My channels", channelIDs: channels.map(\.id), layout: .mainAndStack)
        XCTAssertTrue(model.saveMultiviewFavorite(favorite))
        model.toggleFavorite(channels[0].id)
        model.tune(channels[0].id)
        XCTAssertTrue(model.recordWatched(channels[0].id))
        XCTAssertTrue(model.hideChannel(channels[1]))
        model.category = channels[0].category
        XCTAssertEqual(store.value.favoriteMultiviews, [favorite])
        model.reloadPreferences()
        XCTAssertEqual(model.favoriteMultiviews, [favorite])
        XCTAssertTrue(model.removeMultiviewFavorite(favorite.id))
        XCTAssertTrue(model.favoriteMultiviews.isEmpty)
        XCTAssertEqual(model.favoriteIDs, [channels[0].id])
    }

    func testGuideIdentityIndexTracksFiltersFavoritesRecentsAndHiddenChannels() throws {
        let model = LiveTVPrototypeModel(channels: hiddenChannelFixtures)
        func assertIndex() {
            XCTAssertEqual(model.guideRowIDs, model.guideChannels.map(\.id))
            for (index, entry) in model.guideChannels.enumerated() {
                XCTAssertEqual(model.guideEntry(for: entry.id), entry)
                XCTAssertEqual(model.guideRowIndex(near: entry.id), index)
                XCTAssertEqual(
                    model.guideRow(for: entry.channel.id, preferring: entry.section), entry.id)
            }
        }
        assertIndex()
        let first = hiddenChannelFixtures[0]
        model.toggleFavorite(first.id)
        model.tune(first.id)
        XCTAssertTrue(model.recordWatched(first.id))
        assertIndex()
        XCTAssertNotNil(model.guideEntry(for: .init(channelID: first.id, section: .recent)))
        model.query = "no-matches"
        assertIndex()
        XCTAssertTrue(model.guideRowIDs.isEmpty)
        XCTAssertNil(model.guideEntry(for: .init(channelID: first.id, section: .recent)))
        model.query = ""
        assertIndex()
        XCTAssertTrue(model.hideChannel(first))
        assertIndex()
        XCTAssertNil(model.guideRow(for: first.id))
        model.sort = .name
        assertIndex()
        try model.replaceChannels(Array(model.channels.reversed()))
        assertIndex()
        try model.replaceChannels([])
        assertIndex()
        XCTAssertTrue(model.guideRowIDs.isEmpty)
        XCTAssertNil(model.channel(id: first.id))
        XCTAssertNil(model.guideEntry(for: .init(channelID: first.id)))
        XCTAssertNil(model.guideRowIndex(near: .init(channelID: first.id)))
    }

    func testRemovedGuideSectionIndexUsesTheFirstRemainingOccurrence() {
        let model = LiveTVPrototypeModel(channels: hiddenChannelFixtures)
        let id = hiddenChannelFixtures[0].id
        model.toggleFavorite(id)
        model.tune(id)
        XCTAssertTrue(model.recordWatched(id))
        let recent = LiveTVGuideRowID(channelID: id, section: .recent)
        let favorite = LiveTVGuideRowID(channelID: id, section: .favorites)
        XCTAssertEqual(model.guideRowIndex(near: recent), 0)
        XCTAssertEqual(model.guideRowIndex(near: favorite), 1)
        model.showsRecentChannels = false
        XCTAssertEqual(model.guideRowIndex(near: recent), model.guideRowIndex(near: favorite))
        model.toggleFavorite(id)
        XCTAssertEqual(model.guideRowIndex(near: favorite), model.guideRowIndex(near: .init(channelID: id)))
        model.query = "no-matches"
        XCTAssertNil(model.guideRowIndex(near: recent))
        XCTAssertNil(model.guideRowIndex(near: nil))
    }

    func testCatalogIndicesPreservePayloadsAndRejectInvalidReplacementsAtomically() throws {
        let original = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: original)
        let replacement = LiveTVPrototypeChannel(
            id: original[1].id, number: 3, name: "Replacement channel", category: "Movies",
            symbol: "film", accent: 2, source: .plex, tagline: "Replacement",
            logoURL: URL(string: "https://example.test/logo.png"),
            streamURL: URL(string: "https://example.test/stream.m3u8"),
            guideID: "replacement-guide", guideName: "Replacement guide",
            httpHeaders: ["User-Agent": "Plozz-Test"], playlistSourceID: "replacement-source",
            language: "French", country: "CA", groups: ["Movies", "International"]
        )
        let channels = [replacement, original[0]]
        try model.replaceCatalog(channels: channels, programs: [])
        for sort in [LiveTVPrototypeSort.channelNumber, .name] {
            model.sort = sort
            XCTAssertEqual(model.visibleChannels, [original[0], replacement])
            for channel in channels {
                XCTAssertEqual(model.channel(id: channel.id), channel)
                XCTAssertEqual(model.guideEntry(for: .init(channelID: channel.id))?.channel, channel)
            }
        }

        let rows = model.guideChannels
        let revision = model.catalogRevision
        XCTAssertThrowsError(try model.replaceCatalog(channels: [replacement, replacement], programs: []))
        XCTAssertThrowsError(try model.replaceCatalog(channels: [original[0]], programs: [
            .init(id: "orphan", channelID: replacement.id, title: "Orphan", subtitle: "",
                  start: model.now, end: model.now.addingTimeInterval(1_800))
        ]))
        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(model.catalogRevision, revision)
        XCTAssertEqual(model.guideChannels, rows)
        XCTAssertEqual(model.channel(id: replacement.id), replacement)
        XCTAssertEqual(model.guideEntry(for: .init(channelID: replacement.id))?.channel, replacement)

        try model.replaceCatalog(channels: [original[0]], programs: [])
        XCTAssertNil(model.channel(id: replacement.id))
        XCTAssertNil(model.guideEntry(for: .init(channelID: replacement.id)))
        XCTAssertEqual(model.channel(id: original[0].id), original[0])
    }

    func testFailedMultiviewSaveRetriesWithoutErasingConcurrentFavorites() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let requested = LiveTVMultiviewFavorite(
            id: "requested", name: "My channels", channelIDs: channels.map(\.id), layout: .sideBySide)
        let concurrent = LiveTVMultiviewFavorite(
            id: "concurrent", name: "Another setup", channelIDs: channels.map(\.id), layout: .mainAndStack)
        store.failSave = true
        XCTAssertFalse(model.saveMultiviewFavorite(requested))
        XCTAssertTrue(model.favoriteMultiviews.isEmpty)
        store.value = LiveTVPreferences(favoriteIDs: [channels[0].id], favoriteMultiviews: [concurrent])
        store.failSave = false
        model.retryPreferences()
        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.favoriteMultiviews, [concurrent, requested])
        XCTAssertEqual(model.favoriteIDs, [channels[0].id])
    }

    private var hiddenChannelFixtures: [LiveTVPrototypeChannel] {
        [
            LiveTVPrototypeChannel(
                id: "news", number: 1, name: "News Channel", category: "News",
                symbol: "newspaper", accent: 0, source: .iptv, tagline: ""
            ),
            LiveTVPrototypeChannel(
                id: "sports", number: 2, name: "Sports Channel", category: "Sports",
                symbol: "sportscourt", accent: 1, source: .iptv, tagline: ""
            ),
        ]
    }
}

private final class HiddenChannelsFixtureStore: LiveTVPreferencesStoring, @unchecked Sendable {
    enum Failure: Error {
        case unavailable
    }

    var value = LiveTVPreferences.empty
    var failLoad = false
    var failSave = false

    func load() throws -> LiveTVPreferences {
        if failLoad {
            throw Failure.unavailable
        }
        return value
    }

    func save(_ preferences: LiveTVPreferences) throws {
        if failSave {
            throw Failure.unavailable
        }
        value = preferences
    }
}
