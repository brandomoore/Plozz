import XCTest
import CoreModels
import Synchronization
@testable import FeatureHome

/// Verifies the unmerged Home aggregation: global Continue Watching / Watchlist
/// stay at the top, the full inventory feeds the Libraries tiles, and only the
/// per-library rows the user **opted in** (Recently Added / discovery hubs) build
/// a block — Home stays lean by default.
@MainActor
final class HomeAggregatorUnmergedTests: XCTestCase {
    func testCollectionDirectoryStaysInLibrariesButNeverWidensScopedMediaFeeds() async {
        let directory = MediaLibrary(
            id: "jellyfin:collections", title: "Collections", kind: .collection, synthesizedName: .collections
        )
        let stub = UnmergedStub(libraries: [
            lib("L1", "Movies", .movie), lib("hidden", "Hidden", .movie), directory
        ])
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: stub)],
            visibility: vis([("acct:\(directory.id)", .recentlyAdded)], disabled: ["acct:hidden"])
        )
        XCTAssertTrue(content.libraries.contains { $0.library == directory.taggingSource("acct") })
        XCTAssertTrue(content.librarySections.isEmpty)
        XCTAssertFalse(stub.itemsRequested)
        XCTAssertFalse(stub.scopedLibraryRequests.isEmpty)
        XCTAssertTrue(stub.scopedLibraryRequests.allSatisfy { $0 == ["L1"] })
    }


    /// Enables the given per-library row kinds for `libraryKey` on top of a base.
    private func vis(_ rows: [(String, LibraryHomeRowKind)],
                     merge: Bool = false,
                     disabled: Set<String> = [],
                     excluded: Set<String> = []) -> HomeLibraryVisibility {
        var v = HomeLibraryVisibility(mergeLibrariesOnHome: merge, disabledKeys: disabled.union(excluded))
        for (key, kind) in rows { v.setLibraryRowEnabled(true, libraryKey: key, kind: kind) }
        return v
    }

    func testBuildsOptedInRowsInOrder() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie), lib("L2", "Shows", .series)],
            itemsByContainer: ["L1": [item("m1")], "L2": [item("s1")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "genre", title: "More in Drama", style: .poster, items: [item("h1")])]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // L1 opts into both rows; L2 opts into Recently Added only.
        let visibility = vis([
            ("acct:L1", .recentlyAdded), ("acct:L1", .hubs),
            ("acct:L2", .recentlyAdded)
        ])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1", "acct:L2"])
        // L1: Recently Added (titled per-library) + the discovery hub. No per-library
        // Continue Watching — that's always the single global row.
        XCTAssertEqual(content.librarySections[0].sections.map(\.title),
                       ["Recently Added in Movies", "More in Drama"])
        // L2: just its opted-in Recently Added row.
        XCTAssertEqual(content.librarySections[1].sections.map(\.title),
                       ["Recently Added in Shows"])
        // Items tagged with the owning account for routing.
        XCTAssertEqual(content.librarySections[0].sections[0].items.first?.sourceAccountID, "acct")
        // Full inventory still available for the Libraries tiles.
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1", "L2"])
    }

    func testNoOptedInRowsYieldsNoSectionsButKeepsTiles() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]

        // Default: nothing opted in → lean Home (tiles only, no row blocks).
        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false))

        XCTAssertTrue(content.librarySections.isEmpty, "No rows opted in → no per-library blocks")
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"], "Libraries tiles still available")
    }

    func testLibraryDiscoveryPreservesFailureCausesAndRetriesAfterRecovery() async {
        let aggregator = HomeAggregator()
        let failed = await aggregator.libraryDiscovery(from: [
            resolved("offline", provider: UnmergedStub(libraryError: .serverUnreachable)),
            resolved("expired", provider: UnmergedStub(libraryError: .unauthorized))
        ])
        XCTAssertEqual(failed.failures["offline"], .serverUnreachable)
        XCTAssertEqual(failed.failures["expired"], .unauthorized)
        let recovered = await aggregator.libraryDiscovery(from: [
            resolved("offline", provider: UnmergedStub(libraries: [lib("movies", "Movies", .movie)]))
        ])
        XCTAssertEqual(recovered.libraries.count, 1)
        XCTAssertTrue(recovered.failures.isEmpty)
        XCTAssertTrue(recovered.unreachableAccountIDs.isEmpty)
    }

    func testLibraryDiscoveryDoesNotCallUnresolvedAccountsEmptyLibraries() async {
        let aggregator = HomeAggregator()
        let unresolved = await aggregator.libraryDiscovery(from: [], expectedAccountIDs: ["plex"])
        XCTAssertTrue(unresolved.libraries.isEmpty)
        XCTAssertEqual(unresolved.failures, ["plex": .unauthorized])
        XCTAssertEqual(unresolved.unreachableAccountIDs, ["plex"])

        let partial = await aggregator.libraryDiscovery(
            from: [resolved("ready", provider: UnmergedStub(libraries: [lib("movies", "Movies", .movie)]))],
            expectedAccountIDs: ["ready", "plex"]
        )
        XCTAssertEqual(partial.libraries.map(\.library.id), ["movies"])
        XCTAssertEqual(partial.failures, ["plex": .unauthorized])

        let authenticatedEmpty = await aggregator.libraryDiscovery(
            from: [resolved("plex", provider: UnmergedStub(libraries: []))],
            expectedAccountIDs: ["plex"]
        )
        XCTAssertTrue(authenticatedEmpty.libraries.isEmpty)
        XCTAssertTrue(authenticatedEmpty.failures.isEmpty)
        XCTAssertTrue(authenticatedEmpty.unreachableAccountIDs.isEmpty)
    }

    func testOnlyEnabledRowsAreFetchedAndShown() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "genre", title: "More in Drama", style: .poster, items: [item("h1")])]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Opt into hubs ONLY — Recently Added must not appear or be fetched.
        let visibility = vis([("acct:L1", .hubs)])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.first?.sections.map(\.title), ["More in Drama"])
        XCTAssertFalse(stub.itemsRequested, "Recently Added (items(in:)) must not be fetched when not opted in")
    }

    func testDisabledLibraryContributesNoSection() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Row opted in, but the library is disabled app-wide → excluded.
        let visibility = vis([("acct:L1", .recentlyAdded)], disabled: ["acct:L1"])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertTrue(content.librarySections.isEmpty, "A disabled library contributes no block")
    }

    func testProviderDefaultsDoNotRequestMediaBrowserRecommendations() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("latest")]],
            hubsByLibrary: ["L1": [LibrarySection(id: "optional", title: "Optional", items: [item("suggestion")])]]
        )
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: stub)], visibility: .default
        )
        XCTAssertEqual(content.librarySections.first?.sections.map(\.id), ["recentlyAdded"])
        XCTAssertFalse(stub.hubsRequested)
    }

    func testExplicitRecommendationRequestsOnlyTheSelectedRowsOnHome() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            hubsByLibrary: ["L1": [
                LibrarySection(id: "one", title: "One", items: [item("first")]),
                LibrarySection(id: "two", title: "Two", items: [item("second")])
            ]]
        )
        let visibility = HomeLibraryVisibility(rowCustomization: .init(
            hidden: [.library("acct:L1", kind: .recentlyAdded)],
            shown: [.library(key: "acct:L1", section: "two")]
        ))
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: stub)], visibility: visibility
        )
        XCTAssertEqual(content.librarySections.first?.sections.map(\.id), ["two"])
        XCTAssertFalse(stub.itemsRequested)
        XCTAssertTrue(stub.hubsRequested)
    }

    func testGlobalRecentlyAddedSurvivesInUnmergedMode() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            latest: [cw("newMovie", library: "L1")],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Nothing opted into per-library rows, but the global Recently Added feed
        // must still be carried so the (checked) global row can render.
        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false))

        XCTAssertEqual(content.latest.map(\.id), ["newMovie"],
                       "Unmerged content must carry the global Recently Added feed for the global row")
    }

    func testNativeServerRowsFetchOnlyVisibleAuthorizedSectionsAndKeepProviderIDs() async {
        let account = resolved("acct", provider: UnmergedStub())
        let definitions = ["shown", "hidden", "disabled"].map {
            HomeServerRowDefinition(
                accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                section: .init(id: $0, kind: .recommendations,
                               libraryID: $0 == "disabled" ? "L2" : "L1")
            )
        }
        let provider = UnmergedStub(
            nativeItems: ["shown": [
                cw("original-provider-id", library: "L1"), cw("excluded", library: "L2")
            ]]
        )
        let visibility = HomeLibraryVisibility(
            disabledKeys: ["acct:L2"],
            rowCustomization: .init(
                defaults: .custom, order: definitions.map(\.id),
                shown: [definitions[0].id, definitions[2].id], serverRows: definitions
            )
        )
        let content = await HomeAggregator().unmergedContent(
            from: [ResolvedAccount(account: account.account, provider: provider)],
            visibility: visibility
        )
        XCTAssertEqual(provider.nativeRequests, ["shown"])
        XCTAssertEqual(content.serverRows.map(\.definition.id), [definitions[0].id])
        XCTAssertEqual(content.serverRows.first?.items.first?.id, "original-provider-id")
        XCTAssertEqual(content.serverRows.first?.items.map(\.id), ["original-provider-id"])
        XCTAssertEqual(content.serverRows.first?.items.first?.sourceAccountID, "acct")
        XCTAssertFalse(provider.hubsRequested)
        XCTAssertFalse(provider.itemsRequested)
    }

    func testNativeRowsBatchByAccountAndLibraryWithoutChangingRowOrder() async {
        let definitions = ["one", "two", "three"].enumerated().map { index, id in
            HomeServerRowDefinition(
                accountID: "acct", serverName: "Server", providerKind: .plex,
                section: .init(id: id, kind: .recommendations, libraryID: index < 2 ? "L1" : "L2")
            )
        }
        let provider = UnmergedStub(nativeItems: [
            "one": [item("1")], "two": [item("2")], "three": [item("3")]
        ])
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: provider)],
            visibility: .init(rowCustomization: .init(
                defaults: .custom, shown: Set(definitions.map(\.id)), serverRows: definitions
            ))
        )
        XCTAssertEqual(provider.nativeBatchRequests.map { $0.joined(separator: ",") }.sorted(), ["one,two", "three"])
        XCTAssertEqual(content.serverRows.map(\.definition.id), definitions.map(\.id))
        XCTAssertEqual(content.serverRows.flatMap(\.items).map(\.libraryID), ["L1", "L1", "L2"])
    }

    func testAdaptiveCombinedLayoutFetchesBothServersNativeDefaultsAlongsideCommonRows() async {
        let definitions = ["a", "b"].map { account in
            HomeServerRowDefinition(
                accountID: account, serverName: account, providerKind: .jellyfin,
                section: .init(id: "picks", kind: .recommendations, libraryID: "L1")
            )
        }
        let a = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)], continueWatching: [cw("resume-a", library: "L1")],
            nativeItems: ["picks": [item("pick-a")]]
        )
        let b = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)], continueWatching: [cw("resume-b", library: "L1")],
            nativeItems: ["picks": [item("pick-b")]]
        )
        var customization = HomeRowCustomization(defaults: .matchServer)
        customization.resolvedDefaults = .init(
            mode: .combined, order: HomeRowChoice.shared.map(\.id) + definitions.map(\.id),
            serverRows: definitions
        )
        let visibility = HomeLibraryVisibility(rowCustomization: customization)
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("a", provider: a), resolved("b", provider: b)], visibility: visibility
        )
        XCTAssertEqual(Set(content.continueWatching.map(\.id)), ["resume-a", "resume-b"])
        XCTAssertEqual(content.serverRows.map(\.definition.id), definitions.map(\.id))
        XCTAssertEqual(content.serverRows.flatMap(\.items).map(\.id), ["pick-a", "pick-b"])
        XCTAssertEqual(a.nativeRequests, ["picks"])
        XCTAssertEqual(b.nativeRequests, ["picks"])
        XCTAssertFalse(a.itemsRequested || b.itemsRequested, "Do not fetch additional unselected provider rows.")
    }

    func testNativeSectionFailureIsNotASuccessfulEmptyRow() async {
        let definition = HomeServerRowDefinition(
            accountID: "acct", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "offline", kind: .recommendations)
        )
        let provider = UnmergedStub(nativeError: .serverUnreachable)
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: provider)],
            visibility: .init(rowCustomization: .init(
                defaults: .custom, shown: [definition.id], serverRows: [definition]
            ))
        )
        XCTAssertEqual(content.serverRows.first?.failure, .serverUnreachable)
        XCTAssertEqual(content.serverRows.first?.isLoading, false)
    }

    func testHomeLoadDiagnosticsIncludeLibraryRowFailures() async throws {
        try await checkRowFailureDiagnostics(serverRow: false)
    }

    func testHomeLoadDiagnosticsIncludeServerRowFailures() async throws {
        try await checkRowFailureDiagnostics(serverRow: true)
    }

    private func checkRowFailureDiagnostics(serverRow: Bool) async throws {
        let cases: [(AppError?, PerformanceDiagnostics.Outcome)] = [
            (.serverUnreachable, .failed), (.cancelled, .cancelled), (nil, .succeeded)
        ]
        for (failure, outcome) in cases {
            let definition = HomeServerRowDefinition(
                accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                section: .init(id: "picks", kind: .recommendations, libraryID: "L1")
            )
            let visibility: HomeLibraryVisibility
            if serverRow {
                visibility = .init(rowCustomization: .init(
                    defaults: .custom,
                    shown: [definition.id, .global(.continueWatching), .global(.recentlyAdded)],
                    serverRows: [definition]
                ))
            } else {
                visibility = vis([("acct:L1", .recentlyAdded)])
            }
            let provider = UnmergedStub(
                libraries: [lib("L1", "Movies", .movie)],
                continueWatching: [cw("resume", library: "L1")],
                latest: [cw("latest", library: "L1")],
                itemsByContainer: ["L1": [item("library-pick")]],
                itemsError: serverRow ? nil : failure,
                nativeItems: ["picks": [item("server-pick")]],
                nativeError: serverRow ? failure : nil
            )
            let model = HomeViewModel(
                accounts: [resolved("acct", provider: provider)],
                layoutStore: InMemoryHomeLayoutStore(),
                contentStore: InMemoryHomeContentStore(),
                currentVisibility: { visibility }
            )
            PerformanceDiagnostics.shared.start()
            defer { PerformanceDiagnostics.shared.stop() }
            await model.load()
            let content = try XCTUnwrap(model.state.value)
            XCTAssertEqual(content.continueWatching.map(\.id), ["resume"])
            XCTAssertEqual(content.latest.map(\.id), ["latest"])
            XCTAssertTrue(model.rowFailures.isEmpty, "Global feeds remain healthy.")
            if serverRow {
                XCTAssertEqual(content.serverRows.first?.failure, failure)
                XCTAssertEqual(content.serverRows.first?.isLoading, false)
            } else {
                XCTAssertEqual(content.librarySections.first?.failures[.recentlyAdded], failure)
                XCTAssertTrue(content.librarySections.first?.loadingRows.isEmpty == true)
            }
            let snapshot = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
            let load = try XCTUnwrap((snapshot.recent + snapshot.slow).last { $0.operation == .homeLoad })
            XCTAssertEqual(load.outcome, outcome)
            XCTAssertTrue(snapshot.active.isEmpty)
        }
    }

    func testNativeNextUpSuppliesDetailHintsAndRespondsToWatchMutations() async {
        let definition = HomeServerRowDefinition(
            accountID: "acct", serverName: "Server", providerKind: .jellyfin,
            section: .init(id: "next", kind: .nextUp)
        )
        let episode = MediaItem(id: "episode", title: "Next episode", kind: .episode, seriesID: "show")
        let provider = UnmergedStub(nativeItems: ["next": [episode]])
        let visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, shown: [definition.id], serverRows: [definition]),
            mergeNextUpIntoContinueWatching: false
        )
        let model = HomeViewModel(
            accounts: [resolved("acct", provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility }
        )
        await model.load()
        XCTAssertEqual(model.continueWatchingForDetail.map(\.id), ["episode"])
        model.applyWatchedState(.init(itemIDs: ["episode"], scopedItemIDs: ["acct:episode"], played: true))
        XCTAssertTrue(model.state.value?.serverRows.first?.items.isEmpty == true)
        XCTAssertTrue(model.continueWatchingForDetail.isEmpty)
    }

    func testDefaultMergeUsesCombinedFeedAndStopsSeparateRequestsAcrossLayouts() async {
        let resume = MediaItem(id: "resume", title: "Resume", kind: .movie, resumePosition: 60, libraryID: "shows")
        let next = MediaItem(id: "next", title: "Next episode", kind: .episode, libraryID: "shows")
        let blocked = MediaItem(id: "blocked", title: "Excluded", kind: .episode, libraryID: "blocked")
        let definitions: [HomeServerRowDefinition] = [
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "resume", kind: .continueWatching)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "nextUp", kind: .nextUp)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "picks", kind: .recommendations))
        ]
        for preset in HomeRowCustomization.Defaults.allCases {
            let provider = UnmergedStub(
                libraries: [lib("shows", "Shows", .series), lib("blocked", "Blocked", .series)],
                continueWatching: [resume, next, blocked],
                nativeItems: ["resume": [resume], "nextUp": [next], "picks": [item("pick")]]
            )
            var customization = HomeRowCustomization(
                defaults: preset, order: definitions.map(\.id),
                shown: Set(definitions.map(\.id)), serverRows: definitions
            )
            if preset == .matchServer {
                customization.resolvedDefaults = .init(
                    mode: .server, order: definitions.map(\.id), serverRows: definitions
                )
            }
            let visibility = HomeLibraryVisibility(
                disabledKeys: ["acct:blocked"], rowCustomization: customization
            )
            let content = await HomeAggregator().unmergedContent(
                from: [resolved("acct", provider: provider)], visibility: visibility
            )
            XCTAssertEqual(Set(content.continueWatching.map(\.id)), ["resume", "next", "blocked"], preset.rawValue)
            XCTAssertEqual(content.continueWatching.first { $0.id == "resume" }?.resumePosition, 60)
            XCTAssertEqual(provider.nativeRequests, ["picks"])
            XCTAssertTrue(provider.nextUpRequests.isEmpty)
            XCTAssertEqual(provider.continueWatchingScopes, [nil])
            XCTAssertEqual(content.serverRows.map(\.definition.section.id), ["picks"])
            XCTAssertTrue(content.librarySections.flatMap(\.sections).allSatisfy { $0.id != "nextUp" })
        }
    }

    func testChangingMergePreferenceReloadsFeedAndRestoresNativeRows() async {
        let resume = item("resume")
        let next = MediaItem(id: "next", title: "Next episode", kind: .episode)
        let definitions: [HomeServerRowDefinition] = [
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "resume", kind: .continueWatching)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "nextUp", kind: .nextUp))
        ]
        let provider = UnmergedStub(
            continueWatching: [resume, next],
            nativeItems: ["resume": [resume], "nextUp": [next]]
        )
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, shown: Set(definitions.map(\.id)), serverRows: definitions),
            mergeNextUpIntoContinueWatching: false
        )
        let model = HomeViewModel(
            accounts: [resolved("acct", provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility }
        )
        await model.load()
        XCTAssertEqual(model.state.value?.continueWatching.map(\.id), ["resume"])
        XCTAssertEqual(model.state.value?.serverRows.map(\.definition.section.kind), [.nextUp])
        visibility.mergeNextUpIntoContinueWatching = true
        await model.loadIfNeeded(for: visibility)
        XCTAssertEqual(Set(model.state.value?.continueWatching.map(\.id) ?? []), ["resume", "next"])
        XCTAssertTrue(model.state.value?.serverRows.isEmpty == true)
        visibility.mergeNextUpIntoContinueWatching = false
        await model.loadIfNeeded(for: visibility)
        XCTAssertEqual(model.state.value?.continueWatching.map(\.id), ["resume"])
        XCTAssertEqual(model.state.value?.serverRows.map(\.definition.section.kind), [.nextUp])
    }

    func testNativeHistoryKeepsAccountScopeThroughRenderingDetailAndTopShelf() async throws {
        let resume = MediaItem(id: "resume", title: "Resume", kind: .movie, resumePosition: 60, libraryID: "hidden")
        let next = MediaItem(id: "next", title: "Next", kind: .episode, libraryID: "hidden")
        let definitions: [HomeServerRowDefinition] = [
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "resume", kind: .continueWatching)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "next", kind: .nextUp)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "picks", kind: .recommendations)),
            .init(accountID: "acct", serverName: "Server", providerKind: .jellyfin,
                  section: .init(id: "scoped-next", kind: .nextUp, libraryID: "hidden"))
        ]
        let provider = UnmergedStub(
            libraries: [lib("hidden", "Hidden", .series)],
            nativeItems: ["resume": [resume], "next": [next], "picks": [resume], "scoped-next": [next]]
        )
        let visibility = HomeLibraryVisibility(
            disabledKeys: ["acct:hidden"],
            rowCustomization: .init(
                defaults: .custom, shown: Set(definitions.map(\.id)), serverRows: definitions
            ),
            mergeNextUpIntoContinueWatching: false
        )
        let published = expectation(description: "Account-wide history published")
        let publishedIDs = Mutex<[String]>([])
        let model = HomeViewModel(
            accounts: [resolved("acct", provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility },
            contentPublisher: { history, _ in
                publishedIDs.withLock { $0 = history.map(\.id) }
                published.fulfill()
            }
        )
        await model.load()
        await fulfillment(of: [published], timeout: 2)
        let content = try XCTUnwrap(model.state.value)
        XCTAssertEqual(content.continueWatching.map(\.id), ["resume"])
        XCTAssertEqual(Set(model.continueWatchingForDetail.map(\.id)), ["resume", "next"])
        XCTAssertEqual(publishedIDs.withLock { $0 }, ["resume"])
        XCTAssertEqual(provider.nativeLibraryExclusions["resume"], [])
        XCTAssertEqual(provider.nativeLibraryExclusions["next"], [])
        XCTAssertEqual(provider.nativeLibraryExclusions["picks"], ["hidden"])
        XCTAssertNil(provider.nativeLibraryExclusions["scoped-next"])
        XCTAssertEqual(provider.nativeBatchRequests.map { $0.joined(separator: ",") }.sorted(), ["next", "picks"])
        let rows = HomeRow.rows(for: content, isLibraryVisible: visibility.isEnabled)
        let presented = HomePresentationRow.resolve(rows: rows, content: content, visibility: visibility)
        XCTAssertEqual(Set(presented.map(\.id)), Set(definitions.prefix(3).map(\.id)))
        guard case let .library(nextRow) = presented.first(where: { $0.id == definitions[1].id })?.source else {
            return XCTFail("Missing account-wide Next Up")
        }
        XCTAssertEqual(nextRow.section.items.map(\.id), ["next"])
        guard case let .library(discoveryRow) = presented.first(where: { $0.id == definitions[2].id })?.source else {
            return XCTFail("Missing empty discovery-row explanation")
        }
        XCTAssertTrue(discoveryRow.section.items.isEmpty)
        XCTAssertEqual(discoveryRow.issue?.reason, .empty)
    }

    // MARK: - Music exclusion

    func testMusicLibraryGetsNoUnmergedSection() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie),
                        MediaLibrary(id: "M1", title: "Music", kind: .folder, isMusic: true)],
            itemsByContainer: ["L1": [item("m1")], "M1": [item("album1")]]
        )
        let accounts = [resolved("acct", provider: stub)]
        // Even if the user somehow opted a music row in, music never sections.
        let visibility = vis([("acct:L1", .recentlyAdded), ("acct:M1", .recentlyAdded)])

        let content = await HomeAggregator().unmergedContent(from: accounts, visibility: visibility)

        XCTAssertEqual(content.librarySections.map(\.library.key), ["acct:L1"],
                       "A music library must not get a Home section — it lives in the Music tab")
        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"],
                       "Music library tiles are excluded from Home too")
    }

    func testMergedContentExcludesMusicLibraryTilesAndItems() async {
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie),
                        MediaLibrary(id: "M1", title: "Music", kind: .folder, isMusic: true)],
            continueWatching: [cw("cw1", library: "L1")],
            latest: [cw("newMovie", library: "L1"), cw("newAlbum", library: "M1")]
        )
        let accounts = [resolved("acct", provider: stub)]

        let content = await HomeAggregator().content(from: accounts, visibility: .default)

        XCTAssertEqual(content.libraries.map(\.library.id), ["L1"],
                       "Music library tiles are excluded from Home")
        XCTAssertEqual(content.latest.map(\.id), ["newMovie"],
                       "A music item must not leak into the Recently Added row")
    }

    // MARK: - In-place mutations reach the unmerged per-library rows

    func testApplyWatchedStateAlsoUpdatesUnmergedLibraryRows() async {
        // Regression: marking a title watched must update its card in the unmerged
        // per-library row too, not just the global rows — otherwise the same title
        // reads watched in the global "Recently Added" but unwatched in "Recently
        // Added in Movies" on the same screen until relaunch.
        let stub = UnmergedStub(
            libraries: [lib("L1", "Movies", .movie)],
            itemsByContainer: ["L1": [item("m1")]]
        )
        let vm = HomeViewModel(
            accounts: [resolved("acct", provider: stub)],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { self.vis([("acct:L1", .recentlyAdded)]) }
        )
        await vm.load()

        let before = vm.state.value?.librarySections.first?.sections.first?.items.first
        XCTAssertEqual(before?.id, "m1")
        XCTAssertNotEqual(before?.isPlayed, true)

        vm.applyWatchedState(MediaItemMutation(itemIDs: ["m1"], scopedItemIDs: ["acct:m1"], played: true))

        let after = vm.state.value?.librarySections.first?.sections.first?.items.first
        XCTAssertEqual(after?.id, "m1")
        XCTAssertEqual(after?.isPlayed, true,
                       "in-place mark-watched must update the unmerged per-library row too")
    }

    // MARK: - Helpers

    private func item(_ id: String) -> MediaItem { MediaItem(id: id, title: id, kind: .movie) }
    private func cw(_ id: String, library: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie, libraryID: library)
    }
    private func lib(_ id: String, _ title: String, _ kind: MediaItemKind) -> MediaLibrary {
        MediaLibrary(id: id, title: title, kind: kind)
    }
    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(id: "srv-\(id)", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: "U", deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }
}

/// `MediaProvider` stub for the unmerged tests: returns configurable libraries,
/// a global Continue Watching feed, per-container Recently Added items, and
/// per-library discovery hubs. `continueWatchingByLibrary` models a Jellyfin-style
/// provider whose Continue Watching items are attributed to a library **only** on
/// the scoped fetch path; when it's empty the stub behaves Plex-style (the flat
/// `continueWatching` feed already carries `libraryID`).
private final class UnmergedStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let stubbedLibraries: [MediaLibrary]
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedLatest: [MediaItem]
    private let itemsByContainer: [String: [MediaItem]]
    private let hubsByLibrary: [String: [LibrarySection]]
    private let libraryError: AppError?
    private let itemsError: AppError?
    private let nativeItems: [String: [MediaItem]]
    private let nativeError: AppError?
    private let nativeCalls = Mutex<[String]>([])
    private let nativeExclusions = Mutex<[String: Set<String>]>([:])
    var nativeLibraryExclusions: [String: Set<String>] { nativeExclusions.withLock { $0 } }
    private let scopedFeedCalls = Mutex<[[String]]>([])
    var scopedLibraryRequests: [[String]] { scopedFeedCalls.withLock { $0 } }
    var nativeRequests: [String] { nativeCalls.withLock { $0 } }
    private let nativeBatches = Mutex<[[String]]>([])
    var nativeBatchRequests: [[String]] { nativeBatches.withLock { $0 } }
    private let scopedCalls = Mutex<[[String]?]>([])
    var continueWatchingScopes: [[String]?] { scopedCalls.withLock { $0 } }
    private let nextUpCalls = Mutex<[String]>([])
    var nextUpRequests: [String] { nextUpCalls.withLock { $0 } }
    /// Whether `items(in:)` (Recently Added) was requested — lets a test prove a
    /// non-opted-in row is never fetched.
    private(set) var itemsRequested = false
    private let hubCalls = Mutex(0)
    var hubsRequested: Bool { hubCalls.withLock { $0 > 0 } }

    init(
        libraries: [MediaLibrary] = [],
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        itemsByContainer: [String: [MediaItem]] = [:],
        hubsByLibrary: [String: [LibrarySection]] = [:],
        libraryError: AppError? = nil,
        itemsError: AppError? = nil,
        nativeItems: [String: [MediaItem]] = [:],
        nativeError: AppError? = nil
    ) {
        self.stubbedLibraries = libraries
        self.stubbedContinueWatching = continueWatching
        self.stubbedLatest = latest
        self.itemsByContainer = itemsByContainer
        self.hubsByLibrary = hubsByLibrary
        self.libraryError = libraryError
        self.itemsError = itemsError
        self.nativeItems = nativeItems
        self.nativeError = nativeError
        self.session = UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        if let libraryError { throw libraryError }
        return stubbedLibraries
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { stubbedContinueWatching }
    func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        if let libraryIDs { scopedFeedCalls.withLock { $0.append(libraryIDs) } }
        scopedCalls.withLock { $0.append(libraryIDs) }
        return stubbedContinueWatching.filter { item in
            guard let libraryIDs else { return true }
            return item.libraryID.map(libraryIDs.contains) ?? true
        }
    }
    func latest(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        if let libraryIDs { scopedFeedCalls.withLock { $0.append(libraryIDs) } }
        return stubbedLatest
    }
    func homeNextUp(libraryID: String, limit: Int) async throws -> [MediaItem] {
        nextUpCalls.withLock { $0.append(libraryID) }
        return []
    }
    func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        nativeCalls.withLock { $0.append(section.id) }
        nativeExclusions.withLock { $0[section.id] = excludingLibraryIDs }
        if let nativeError { throw nativeError }
        return (nativeItems[section.id] ?? []).filter {
            $0.libraryID.map { !excludingLibraryIDs.contains($0) } ?? true
        }
    }
    func serverHomeItems(
        sections: [ServerHomeSection], limit: Int, excludingLibraryIDs: Set<String>
    ) async -> [String: Result<[MediaItem], AppError>] {
        nativeBatches.withLock { $0.append(sections.map(\.id)) }
        var result: [String: Result<[MediaItem], AppError>] = [:]
        for section in sections {
            do {
                result[section.id] = .success(try await serverHomeItems(
                    section: section, limit: limit, excludingLibraryIDs: excludingLibraryIDs
                ))
            } catch {
                result[section.id] = .failure((error as? AppError) ?? .unknown(""))
            }
        }
        return result
    }
    func latest(limit: Int) async throws -> [MediaItem] { stubbedLatest }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        itemsRequested = true
        if let itemsError { throw itemsError }
        let items = itemsByContainer[containerID] ?? []
        return MediaPage(items: items, startIndex: 0, totalCount: items.count)
    }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        hubCalls.withLock { $0 += 1 }
        return hubsByLibrary[libraryID] ?? []
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
