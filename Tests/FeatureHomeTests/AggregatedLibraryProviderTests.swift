import XCTest
@testable import CoreModels
@testable import FeatureHome

/// Tests the cross-server Library-browse provider (criterion 1, browse half):
/// concurrent bounded paging across servers with **no full-library scan**, the
/// shared `MediaItemMerger` collapsing the same title into one card, resilience
/// when a server is offline, and correct exhaustion/total accounting.
final class AggregatedLibraryProviderTests: XCTestCase {

    private func movie(_ id: String, title: String, year: Int, tmdb: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .movie, productionYear: year, providerIDs: ["Tmdb": tmdb])
    }

    private func source(_ account: String, _ provider: FakeMediaProvider) -> AggregatedLibrarySource {
        AggregatedLibrarySource(accountID: account, containerID: "lib-\(account)", provider: provider)
    }

    private func page(_ provider: AggregatedLibraryProvider, start: Int, limit: Int) async throws -> MediaPage {
        try await provider.items(in: "lib", kind: .movie, page: PageRequest(startIndex: start, limit: limit))
    }

    func testMergesServersInSortOrderWithoutFullScan() async throws {
        // The grid claims a sort in its own menu, so the stitched result has to
        // honour it: a k-way merge on the sort key, NOT a round-robin interleave
        // (which produced "P0, J0, P1, J1…" under a menu reading "Name A–Z").
        let plexItems = (0..<6).map { movie("p\($0)", title: "P\($0)", year: 2000 + $0, tmdb: "10\($0)") }
        let jellyItems = (0..<6).map { movie("j\($0)", title: "J\($0)", year: 2000 + $0, tmdb: "20\($0)") }
        let plex = FakeMediaProvider(allItems: plexItems)
        let jelly = FakeMediaProvider(allItems: jellyItems)
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex), source("jelly", jelly)])

        let first = try await page(provider, start: 0, limit: 4)
        XCTAssertEqual(first.items.count, 4)
        XCTAssertEqual(first.items.map(\.id), ["j0", "j1", "j2", "j3"], "Name-sorted across servers")
        XCTAssertEqual(first.totalCount, 12, "Both small libraries fully drained → exact merged total")

        // No deep paging: each server was asked for exactly one bounded chunk
        // (limit >= 20) starting at 0 — never a full-library walk.
        XCTAssertEqual(plex.requestedPages.count, 1)
        XCTAssertEqual(jelly.requestedPages.count, 1)
        XCTAssertEqual(plex.requestedPages.first?.startIndex, 0)
        XCTAssertGreaterThanOrEqual(plex.requestedPages.first?.limit ?? 0, 20)
    }

    func testDeduplicatesSameTitleAcrossServersIntoOneCard() async throws {
        let plex = FakeMediaProvider(allItems: [
            movie("dp", title: "Dune", year: 2021, tmdb: "1"),
            movie("ap", title: "Arrival", year: 2016, tmdb: "2")
        ])
        let jelly = FakeMediaProvider(allItems: [
            movie("dj", title: "Dune", year: 2021, tmdb: "1"),
            movie("hj", title: "Heat", year: 1995, tmdb: "3")
        ])
        let info: [String: SourceServerInfo] = [
            "plex": SourceServerInfo(providerKind: .plex, serverName: "Living Room"),
            "jelly": SourceServerInfo(providerKind: .jellyfin, serverName: "Den")
        ]
        let provider = AggregatedLibraryProvider(
            sources: [source("plex", plex), source("jelly", jelly)],
            serverInfo: info
        )

        let result = try await page(provider, start: 0, limit: 20)
        XCTAssertEqual(result.items.count, 3, "Dune appears once; Arrival + Heat unique")
        XCTAssertEqual(result.totalCount, 3)

        let dune = try XCTUnwrap(result.items.first { $0.title == "Dune" })
        XCTAssertEqual(dune.sources.map(\.accountID), ["plex", "jelly"], "Merged card keeps both servers")
        XCTAssertTrue(dune.hasMultipleSources)
        XCTAssertEqual(dune.sources.first?.serverName, "Living Room", "serverInfo labels flow through")
    }

    func testResilientWhenOneServerOffline() async throws {
        let plex = FakeMediaProvider(allItems: [])
        plex.alwaysFail = true
        let jelly = FakeMediaProvider(allItems: (0..<3).map {
            movie("j\($0)", title: "J\($0)", year: 2000 + $0, tmdb: "2\($0)")
        })
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex), source("jelly", jelly)])

        let result = try await page(provider, start: 0, limit: 10)
        XCTAssertEqual(result.items.map(\.id), ["j0", "j1", "j2"], "Offline server dropped; the other still browses")
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertFalse(result.hasMore)
    }

    func testCompactQueryUsesNewestWatchHistoryWithoutLosingRewatchProgress() throws {
        var old = movie("p", title: "Dune", year: 2021, tmdb: "1").taggingSource("plex")
        old.isPlayed = true
        old.lastPlayedAt = Date(timeIntervalSince1970: 100)
        old.librarySortValues = .init(watched: true)
        var recent = movie("j", title: "Dune", year: 2021, tmdb: "1").taggingSource("jelly")
        recent.runtime = 100
        recent.resumePosition = 25
        recent.playedPercentage = 0.25
        recent.lastPlayedAt = Date(timeIntervalSince1970: 200)
        recent.librarySortValues = .init(watched: true)
        let provider = AggregatedLibraryProvider(sources: [
            source("plex", FakeMediaProvider(allItems: [old])),
            source("jelly", FakeMediaProvider(allItems: [recent]))
        ])
        let merged = try XCTUnwrap(provider.libraryQueryMergeInventory([
            LibraryQueryRecord(old), LibraryQueryRecord(recent)
        ]).first)
        XCTAssertTrue(merged.completed, "A rewatch retains historical completion")
        XCTAssertFalse(merged.isPlayed)
        XCTAssertTrue(merged.matches(.init(filter: .inProgress)))
        XCTAssertFalse(merged.matches(.init(filter: .unwatched)))
        XCTAssertEqual(merged.progress, 0.25)
        recent.librarySortValues?.watched = false
        let markedUnwatched = try XCTUnwrap(provider.libraryQueryMergeInventory([
            LibraryQueryRecord(old), LibraryQueryRecord(recent)
        ]).first)
        XCTAssertFalse(markedUnwatched.completed, "Newer explicit history wins over another server's older completion")
    }

    func testHubIdentifiersDistinguishLibrariesOnTheSameAccount() async throws {
        let source = FakeMediaProvider(allItems: [])
        source.recommendationHubs = [
            LibrarySection(id: "native", title: "Recommended", items: [
                movie("movie", title: "Movie", year: 2024, tmdb: "1")
            ])
        ]
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "account", containerID: "first", provider: source),
            .init(accountID: "account", containerID: "second", provider: source)
        ])
        let hubs = try await provider.libraryHubs(libraryID: "merged", kind: .movie, limit: 10)
        XCTAssertEqual(hubs.count, 2)
        XCTAssertEqual(Set(hubs.map(\.id)).count, 2)
    }

    func testRecommendationsRetainHealthyAccountAndSourceIdentity() async throws {
        let offline = FakeMediaProvider(allItems: [])
        offline.continueWatchingError = .serverUnreachable
        offline.recommendationHubError = .serverUnreachable
        let healthy = FakeMediaProvider(allItems: [])
        healthy.continueWatchingItems = [
            movie("playing", title: "Playing", year: 2020, tmdb: "100")
                .taggingLibrary("lib-healthy")
        ]
        healthy.recommendationHubs = [
            LibrarySection(id: "native", title: "Because You Watched",
                           localizedTitle: "Recommended", localizedTitleSuffix: " · Movies", items: [
                movie("suggested", title: "Suggested", year: 2021, tmdb: "101")
            ])
        ]
        let provider = AggregatedLibraryProvider(sources: [
            source("offline", offline), source("healthy", healthy)
        ])

        let watching = try await provider.continueWatching(limit: 10, inLibraries: ["merged"])
        XCTAssertEqual(watching.map(\.id), ["playing"])
        XCTAssertEqual(watching.first?.sourceAccountID, "healthy")
        let hubs = try await provider.libraryHubs(libraryID: "merged", kind: .movie, limit: 10)
        XCTAssertEqual(hubs.map(\.id), ["healthy\u{1F}lib-healthy:native"])
        XCTAssertEqual(hubs.first?.items.first?.libraryID, "lib-healthy")
        XCTAssertEqual(hubs.first?.items.first?.sourceAccountID, "healthy")
        XCTAssertEqual(hubs.first?.localizedTitle, LocalizedStringResource("Recommended"))
        XCTAssertEqual(hubs.first?.localizedTitleSuffix, " · Movies · \(healthy.session.server.name)")

        healthy.recommendationHubError = .serverUnreachable
        do {
            _ = try await provider.libraryHubs(libraryID: "merged", kind: .movie, limit: 10)
            XCTFail("An entirely failed recommendation feed must be retryable")
        } catch AppError.serverUnreachable {
        }
    }

    func testContinueWatchingMergesSourcesAndOrdersByRecencyBeforeLimiting() async throws {
        var a = movie("a", title: "Dune", year: 2021, tmdb: "1").taggingLibrary("lib-a")
        var b = movie("b", title: "Dune", year: 2021, tmdb: "1").taggingLibrary("lib-b")
        var arrival = movie("arrival", title: "Arrival", year: 2016, tmdb: "2").taggingLibrary("lib-a")
        var heat = movie("heat", title: "Heat", year: 1995, tmdb: "3").taggingLibrary("lib-b")
        a.lastPlayedAt = Date(timeIntervalSince1970: 10)
        b.lastPlayedAt = Date(timeIntervalSince1970: 30)
        arrival.lastPlayedAt = Date(timeIntervalSince1970: 20)
        heat.lastPlayedAt = Date(timeIntervalSince1970: 40)
        b.resumePosition = 120
        let first = FakeMediaProvider(allItems: [a, arrival])
        let second = FakeMediaProvider(allItems: [b, heat])
        first.continueWatchingItems = [a, arrival]
        second.continueWatchingItems = [b, heat]
        let provider = AggregatedLibraryProvider(sources: [source("a", first), source("b", second)])
        let items = try await provider.continueWatching(limit: 2, inLibraries: ["lib-a"])
        XCTAssertEqual(items.map(\.title), ["Heat", "Dune"])
        let dune = try XCTUnwrap(items.last)
        XCTAssertEqual(Set(dune.allSourceAccountIDs), ["a", "b"])
        XCTAssertEqual(Set(dune.sources.compactMap(\.libraryID)), ["lib-a", "lib-b"])
        XCTAssertEqual(dune.lastPlayedAt, b.lastPlayedAt)
        XCTAssertEqual(dune.resumePosition, b.resumePosition)
    }

    @MainActor
    func testRecommendedContinueWatchingRetainsEveryAccountQualifiedLibrary() async throws {
        let a = movie("a", title: "First", year: 2024, tmdb: "1").taggingLibrary("lib-a")
        let b = movie("b", title: "Second", year: 2024, tmdb: "2").taggingLibrary("lib-b")
        let first = FakeMediaProvider(allItems: [a])
        let second = FakeMediaProvider(allItems: [b])
        first.continueWatchingItems = [a, b]
        second.continueWatchingItems = [b, a]
        let provider = AggregatedLibraryProvider(sources: [source("a", first), source("b", second)])
        let model = LibraryBrowseViewModel(provider: provider, containerID: "lib-a", containerKind: .movie)
        await model.loadFirstPageIfNeeded()
        let sections = try XCTUnwrap(model.recommendationState.value)
        let watching = try XCTUnwrap(sections.first { $0.id == "continueWatching" }).items
        XCTAssertEqual(watching.map(\.id), ["a", "b"])
        XCTAssertEqual(watching.map(\.sourceAccountID), ["a", "b"])
        XCTAssertEqual(watching.map(\.libraryID), ["lib-a", "lib-b"])
        XCTAssertFalse(provider.contains(b.taggingSource("a"), inLibrary: "lib-a"))
        XCTAssertFalse(provider.contains(a.taggingSource("foreign"), inLibrary: "lib-a"))
    }

    func testTransientFailureDoesNotPermanentlyExhaustSource() async throws {
        // r8-agg-transient-exhaust: a one-off network blip on a healthy server used
        // to trip the one-way `markExhausted` latch, silencing that server for the
        // whole browse session. A nil page must now mean "skip this batch, retry
        // later" — only a genuine end-of-list (empty / total-reached page) exhausts.
        // Here Jelly throws once on its first page then recovers; within the same
        // fill loop Plex drains and Jelly is re-fetched, so every title still lands.
        let plex = FakeMediaProvider(allItems: (0..<3).map {
            movie("p\($0)", title: "P\($0)", year: 2000 + $0, tmdb: "1\($0)")
        })
        let jelly = FakeMediaProvider(allItems: (0..<3).map {
            movie("j\($0)", title: "J\($0)", year: 2010 + $0, tmdb: "2\($0)")
        })
        jelly.failAtStartIndex = 0   // first page request throws once, then succeeds
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex), source("jelly", jelly)])

        let result = try await page(provider, start: 0, limit: 10)

        XCTAssertEqual(
            Set(result.items.map(\.id)),
            ["p0", "p1", "p2", "j0", "j1", "j2"],
            "A transient blip must not drop the healthy server — its items surface once it recovers"
        )
        XCTAssertEqual(result.totalCount, 6)
        XCTAssertFalse(result.hasMore)
        XCTAssertGreaterThanOrEqual(
            jelly.requestedPages.count, 2,
            "Jelly was retried after its transient failure rather than being permanently exhausted"
        )
    }

    func testTotalCountIsExactOnlyOnceExhausted() async throws {
        let small = FakeMediaProvider(allItems: (0..<5).map {
            movie("s\($0)", title: "S\($0)", year: 2000 + $0, tmdb: "5\($0)")
        })
        let provider = AggregatedLibraryProvider(sources: [source("solo", small)])

        let result = try await page(provider, start: 0, limit: 10)
        XCTAssertEqual(result.items.count, 5)
        XCTAssertEqual(result.totalCount, 5)
        XCTAssertFalse(result.hasMore)
    }

    func testSequentialPagingCoversEveryItemExactlyOnce() async throws {
        let plex = FakeMediaProvider(allItems: (0..<30).map {
            movie("p\($0)", title: "P\($0)", year: 1980 + $0, tmdb: "1\($0)")
        })
        let jelly = FakeMediaProvider(allItems: (0..<30).map {
            movie("j\($0)", title: "J\($0)", year: 1900 + $0, tmdb: "9\($0)")
        })
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex), source("jelly", jelly)])

        var collected: [String] = []
        var start = 0
        let limit = 10
        // Drain page by page, exactly as a scrolling grid would.
        while true {
            let result = try await page(provider, start: start, limit: limit)
            collected.append(contentsOf: result.items.map(\.id))
            if !result.hasMore { break }
            start += limit
            if start > 200 { XCTFail("Paging did not terminate"); break }
        }

        XCTAssertEqual(collected.count, 60, "Every unique title surfaced")
        XCTAssertEqual(Set(collected).count, 60, "No duplicates across pages")
        // Bounded fetching: 30 items at chunk 20 ⇒ at most 2 requests per server.
        XCTAssertLessThanOrEqual(plex.requestedPages.count, 2)
        XCTAssertLessThanOrEqual(jelly.requestedPages.count, 2)
    }

    func testItemAndChildrenProbeSourcesAndTagOwner() async throws {
        let plex = FakeMediaProvider(allItems: [movie("p1", title: "OnlyPlex", year: 2001, tmdb: "1")])
        plex.childrenByParent = [:]
        let jelly = FakeMediaProvider(allItems: [movie("j1", title: "OnlyJelly", year: 2002, tmdb: "2")])
        jelly.childrenByParent = ["j1": [movie("j1e1", title: "Child", year: 2002, tmdb: "20")]]
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex), source("jelly", jelly)])

        let found = try await provider.item(id: "j1")
        XCTAssertEqual(found.id, "j1")
        XCTAssertEqual(found.sourceAccountID, "jelly", "Resolved item is tagged with its owning server")

        let children = try await provider.children(of: "j1")
        XCTAssertEqual(children.map(\.id), ["j1e1"])
        XCTAssertEqual(children.first?.sourceAccountID, "jelly")
    }

    func testUnknownItemThrowsNotFound() async {
        let plex = FakeMediaProvider(allItems: [])
        let provider = AggregatedLibraryProvider(sources: [source("plex", plex)])
        do {
            _ = try await provider.item(id: "missing")
            XCTFail("Expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
