import XCTest
import Foundation
import CoreModels
import RatingsService
import AppRuntime
import FeatureHomeCore
import SeerService
@testable import AppShell

private actor HeroRequestIdentityGate {
    private var continuation: CheckedContinuation<String?, Never>?

    func resolve(started: XCTestExpectation) async -> String? {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume(returning: "42")
        continuation = nil
    }
}

private actor HeroRequestIdentityBatchProbe {
    private let firstWave: XCTestExpectation
    private var active = 0
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    private(set) var maximumActive = 0

    init(firstWave: XCTestExpectation) {
        self.firstWave = firstWave
    }

    func resolve(_ item: MediaItem) async -> String? {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        if !released {
            await withCheckedContinuation {
                pending.append($0)
                if pending.count == 4 { firstWave.fulfill() }
            }
        }
        active -= 1
        return item.id
    }

    func release() {
        released = true
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private final class PinnedSeriesTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MediaItem] = []
    var items: [MediaItem] { lock.withLock { stored } }
    func set(_ items: [MediaItem]) { lock.withLock { stored = items } }
}

final class HeroMetadataEnricherTests: XCTestCase {
    @MainActor
    func testExternalMoviesAndSeriesHaveARequestCTAWithoutOpeningDetailFirst() async throws {
        let seer = SeerService(connectionStore: InMemorySeerConnectionStore(connection: .init(
            baseURL: URL(string: "https://requests.example.test")!, apiKey: "fixture"
        )))
        for kind in [MediaItemKind.movie, .series] {
            let item = MediaItem(
                id: "external-\(kind.rawValue)", title: "A title", kind: kind,
                posterURL: URL(string: "https://images.example.test/poster.jpg"),
                providerIDs: ["Tvdb": "17"], discoverySources: [.tvdb],
                availability: .unknown, locallyValidatedPlayableSource: false
            )
            XCTAssertEqual(item.heroCTA(
                seerConnected: seer.isConfigured && seer.hasRequestIdentity(for: item)
            ), .unavailable)
            let enricher = HeroMetadataEnricher(
                accounts: [],
                targetSelector: {
                    XCTFail("Request identity must not authorize library retargeting.")
                    return $0
                },
                requestIdentityResolver: { source in
                    XCTAssertEqual(source.providerID(.tvdb), "17")
                    return "42"
                }
            )
            let result = await enricher.enrich([item])
            let ready = try XCTUnwrap(result.first)
            XCTAssertTrue(seer.hasRequestIdentity(for: ready))
            XCTAssertEqual(ready.heroCTA(
                seerConnected: seer.isConfigured && seer.hasRequestIdentity(for: ready)
            ), .request)
            XCTAssertEqual(ready.id, item.id)
            XCTAssertEqual(ready.kind, kind)
            XCTAssertEqual(ready.providerID(.tvdb), "17")
            XCTAssertEqual(ready.posterURL, item.posterURL)
            XCTAssertEqual(ready.discoverySources, item.discoverySources)
            XCTAssertEqual(ready.availability, .unknown)
            XCTAssertFalse(ready.hasPlayableLibraryTarget())
            XCTAssertTrue(ready.sources.isEmpty)
            XCTAssertNil(ready.sourceAccountID)
        }
    }

    func testRequestIdentityLookupSkipsOwnedKnownUnsupportedAndPersonalTitles() async {
        var personal = MediaItem(
            id: "personal", title: "Personal", kind: .movie,
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        personal.allowsTitleBasedMetadataMatching = false
        let items = [
            MediaItem(id: "owned", title: "Owned", kind: .movie),
            MediaItem(
                id: "known", title: "Known", kind: .series,
                providerIDs: ["tmdb": "42"], discoverySources: [.tvdb],
                availability: .unknown, locallyValidatedPlayableSource: false
            ),
            MediaItem(
                id: "episode", title: "Episode", kind: .episode,
                availability: .unknown, locallyValidatedPlayableSource: false
            ),
            personal
        ]
        let enricher = HeroMetadataEnricher(
            accounts: [], targetSelector: { $0 },
            requestIdentityResolver: { _ in
                XCTFail("These records must not start request-identity work.")
                return "99"
            }
        )
        let result = await enricher.enrich(items)
        XCTAssertEqual(result, items)
    }

    func testUnresolvedRequestIdentityDoesNotInventAnIDOrOwnership() async {
        let item = MediaItem(
            id: "external", title: "Title", kind: .movie,
            discoverySources: [.tvdb], availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        for value in [nil, "0", "-1", "invalid"] as [String?] {
            let enricher = HeroMetadataEnricher(
                accounts: [], targetSelector: { $0 },
                requestIdentityResolver: { _ in value }
            )
            let result = await enricher.enrich([item])
            XCTAssertEqual(result, [item])
        }
    }

    func testCancelledIdentityResolutionCannotPublishLateResults() async {
        let started = expectation(description: "Request identity lookup started")
        let gate = HeroRequestIdentityGate()
        let item = MediaItem(
            id: "external", title: "Title", kind: .series,
            discoverySources: [.tvmaze], availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        let enricher = HeroMetadataEnricher(
            accounts: [], targetSelector: { $0 },
            requestIdentityResolver: { _ in await gate.resolve(started: started) }
        )
        let task = Task { await enricher.enrich([item]) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result, [item])
    }

    func testRequestIdentityWorkIsBoundedAndKeepsCarouselOrder() async {
        let firstWave = expectation(description: "Four identity lookups admitted")
        let probe = HeroRequestIdentityBatchProbe(firstWave: firstWave)
        let items = (100..<112).map { id in
            MediaItem(
                id: "\(id)", title: "Title \(id)", kind: .movie,
                discoverySources: [.tvdb], availability: .unknown,
                locallyValidatedPlayableSource: false
            )
        }
        let enricher = HeroMetadataEnricher(
            accounts: [], targetSelector: { $0 },
            requestIdentityResolver: { await probe.resolve($0) }
        )
        let task = Task { await enricher.enrich(items) }
        await fulfillment(of: [firstWave], timeout: 2)
        let initiallyAdmitted = await probe.calls
        await probe.release()
        let result = await task.value
        let maximumActive = await probe.maximumActive
        let calls = await probe.calls
        XCTAssertEqual(initiallyAdmitted, 4)
        XCTAssertLessThanOrEqual(maximumActive, 4)
        XCTAssertEqual(calls, items.count)
        XCTAssertEqual(result.map(\.id), items.map(\.id))
        XCTAssertEqual(result.compactMap { $0.providerID(.tmdb) }, items.map(\.id))
    }

    func testPinnedExternalSeriesKeepsVerifiedSeriesThroughEnrichmentMergeAndPlaybackResolution() async throws {
        let scenario = pinnedSeriesScenario()
        let accounts = [scenario.account]
        let enricher = HeroMetadataEnricher(
            accounts: accounts,
            targetSelector: { PlaybackSourceSelection.bestPlayItem($0, accounts: accounts, identitySources: { _ in [] }) }
        )
        let fresh = await enricher.enrich(
            [scenario.verified], preservingPinnedSeries: { [scenario.external] }
        )
        let series = try XCTUnwrap(fresh.first)
        XCTAssertEqual(series.kind, .series)
        XCTAssertEqual(series.id, scenario.verified.id)
        XCTAssertEqual(series.providerID(.tmdb), "42")
        XCTAssertNil(series.providerID(.seriesTmdb))
        XCTAssertEqual(series.sources, scenario.verified.sources)
        XCTAssertEqual(series.taglines, ["Series tagline"])
        XCTAssertEqual(series.discoverySources, [.tmdb])

        let merge = HeroLiveMerge.merge(
            showing: [scenario.external], fresh: fresh, limit: 1,
            pinnedItemIDs: [scenario.external.id], preservesPinnedItems: true
        )
        let visible = try XCTUnwrap(merge.items.first)
        XCTAssertEqual(visible.id, scenario.external.id)
        XCTAssertEqual(visible.kind, .series)
        XCTAssertTrue(visible.hasPlayableLibraryTarget())
        XCTAssertNil(visible.sourceAccountID)
        XCTAssertEqual(visible.sources.map(\.itemID), [scenario.verified.id])
        XCTAssertTrue(visible.sources.allSatisfy { $0.kind == .series })
        XCTAssertFalse(visible.sources.contains { $0.itemID == scenario.episode.id })

        let scope = NSObject()
        let externalResolution = HeroPlaybackResolutionKey(
            item: scenario.external, scopeID: ObjectIdentifier(scope), identityIndexRevision: 1
        )
        let ownedResolution = HeroPlaybackResolutionKey(
            item: visible, scopeID: ObjectIdentifier(scope), identityIndexRevision: 1
        )
        XCTAssertNotEqual(externalResolution, ownedResolution,
                          "The carousel must restart episode resolution without paging away.")
        let physicalSeries = PlaybackSourceSelection.bestPlayItem(
            visible, accounts: accounts, identitySources: { _ in [] }
        )
        XCTAssertEqual(physicalSeries.id, scenario.verified.id)
        XCTAssertEqual(physicalSeries.sourceAccountID, scenario.account.account.id)
        let target = await HeroPlayTargetResolver.playbackTarget(
            for: physicalSeries, provider: scenario.account.provider
        )
        let episode = try XCTUnwrap(target)
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(episode.id, scenario.episode.id)
        XCTAssertEqual(episode.sourceAccountID, scenario.account.account.id)
        let projected = try XCTUnwrap(HeroDiscoveryPlaybackTarget.project(
            resolved: episode, original: visible, selected: physicalSeries
        ))
        let routed = PlaybackSourceSelection.bestPlayItem(
            projected, accounts: accounts,
            identitySources: { _ in
                XCTFail("Resolving an episode must not lose discovery's verified-source boundary.")
                return []
            }
        )
        XCTAssertEqual(routed.id, episode.id)
        XCTAssertEqual(routed.sourceAccountID, scenario.account.account.id)
        XCTAssertEqual(projected.discoverySources, visible.discoverySources)
        let cache = HeroResolutionCacheEntry(key: ownedResolution, item: projected)
        XCTAssertEqual(cache.value(for: ownedResolution)?.kind, .episode)
        XCTAssertNil(cache.value(for: externalResolution))
    }

    func testTVClosureContextPreservesPinnedSeriesAndUnpinnedEnrichmentStillFindsNextEpisode() async throws {
        let scenario = pinnedSeriesScenario()
        let enrich = makeHeroMetadataEnricher(
            accounts: [scenario.account], identitySources: { _ in [] }
        )
        let pinned = await HeroMetadataEnricher.withPinnedSeries({ [scenario.external] }) {
            await enrich([scenario.verified])
        }
        XCTAssertEqual(pinned.first?.kind, .series)
        XCTAssertEqual(pinned.first?.id, scenario.verified.id)
        let unpinned = await enrich([scenario.verified])
        let episode = try XCTUnwrap(unpinned.first)
        XCTAssertEqual(episode.kind, .episode)
        XCTAssertEqual(episode.id, scenario.episode.id)
        XCTAssertEqual(episode.seriesID, scenario.verified.id)
        XCTAssertEqual(episode.providerID(.tmdb), "episode-42-2")
        XCTAssertEqual(episode.providerID(.seriesTmdb), "42")
        XCTAssertEqual(episode.discoverySources, [.tmdb])
        let merge = HeroLiveMerge.merge(
            showing: pinned, fresh: unpinned, limit: 1,
            pinnedItemIDs: [], preservesPinnedItems: true
        )
        XCTAssertEqual(merge.items.first?.kind, .episode)
        XCTAssertEqual(merge.items.first?.id, scenario.episode.id)
    }

    func testPinnedSeriesPreservationDoesNotApplyToDifferentOrWeaklyMatchedTitles() async {
        let scenario = pinnedSeriesScenario()
        let accounts = [scenario.account]
        let enricher = HeroMetadataEnricher(
            accounts: accounts,
            targetSelector: { PlaybackSourceSelection.bestPlayItem($0, accounts: accounts, identitySources: { _ in [] }) }
        )
        var unrelated = scenario.external
        unrelated.providerIDs = ["Tmdb": "99"]
        let unrelatedSeries = unrelated
        let otherPinned = await enricher.enrich([scenario.verified], preservingPinnedSeries: { [unrelatedSeries] })
        XCTAssertEqual(otherPinned.first?.kind, .episode)
        var titleOnly = scenario.external
        titleOnly.title = scenario.verified.title
        titleOnly.providerIDs = [:]
        let titleOnlySeries = titleOnly
        let weaklyPinned = await enricher.enrich([scenario.verified], preservingPinnedSeries: { [titleOnlySeries] })
        XCTAssertEqual(weaklyPinned.first?.kind, .episode)
    }

    func testSeriesPinnedAfterEnrichmentStartsStillGetsPlayableSeriesProof() async throws {
        let scenario = pinnedSeriesScenario()
        let pins = PinnedSeriesTestState()
        let accounts = [scenario.account]
        let enricher = HeroMetadataEnricher(
            accounts: accounts,
            targetSelector: { item in
                pins.set([scenario.external])
                return PlaybackSourceSelection.bestPlayItem(item, accounts: accounts, identitySources: { _ in [] })
            }
        )
        let fresh = await enricher.enrich(
            [scenario.verified], preservingPinnedSeries: { pins.items }
        )
        XCTAssertEqual(fresh.first?.kind, .series)
        let merged = HeroLiveMerge.merge(
            showing: [scenario.external], fresh: fresh, limit: 1,
            pinnedItemIDs: [scenario.external.id], preservesPinnedItems: true
        )
        let visible = try XCTUnwrap(merged.items.first)
        XCTAssertEqual(visible.id, scenario.external.id)
        XCTAssertTrue(visible.hasPlayableLibraryTarget())
    }

    private func pinnedSeriesScenario() -> (
        external: MediaItem, verified: MediaItem, episode: MediaItem, account: ResolvedAccount
    ) {
        let accountID = "series-account"
        let seriesID = "library-series"
        let external = MediaItem(
            id: "tmdb:series:42", title: "Visible series", kind: .series,
            backdropURL: URL(string: "https://public.example/series.jpg"),
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let verified = MediaItem(
            id: seriesID, title: "Library series", kind: .series,
            backdropURL: URL(string: "https://server.example/series.jpg"),
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: accountID,
            sources: [.init(accountID: accountID, itemID: seriesID, kind: .series)]
        )
        var hydrated = verified
        hydrated.taglines = ["Series tagline"]
        hydrated.overview = "Series overview"
        let episode = MediaItem(
            id: "library-episode", title: "Next episode", kind: .episode,
            seasonNumber: 1, episodeNumber: 2, seriesID: seriesID,
            runtime: 1_200, resumePosition: 100,
            providerIDs: ["Tmdb": "episode-42-2"]
        )
        let account = resolved(
            accountID, details: [seriesID: hydrated, episode.id: episode],
            childrenByID: [seriesID: [episode]]
        )
        return (external, verified, episode, account)
    }

    func testBasicGuidanceEnrichesAnOtherwiseCompleteHeroWithoutFetchingACloudReview() async {
        let sparse = MediaItem(
            id: "movie", title: "Movie", kind: .movie, overview: "Overview",
            productionYear: 2026, officialRating: "PG", taglines: ["Tagline"],
            sourceAccountID: "account"
        )
        var detail = sparse
        detail.familyGuidance = .init(recommendedAge: 10, qualityRating: 4)
        let account = resolved("account", detail: detail)
        let provider = GuidanceHeroMetadataProvider(session: account.provider.session, details: [detail.id: detail])
        let enriched = await makeHeroMetadataEnricher(
            accounts: [.init(account: account.account, provider: provider)],
            identitySources: { _ in [] }
        )([sparse])
        XCTAssertEqual(enriched.first?.familyGuidance, detail.familyGuidance)
    }

    func testFillsOverviewAndTaglinesWhenOtherHeroMetadataIsAlreadyPresent() async throws {
        let accountID = "jellyfin-account"
        let sparse = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            productionYear: 2004,
            officialRating: "PG-13",
            genres: ["Comedy"],
            sourceAccountID: accountID
        )
        var detail = sparse
        detail.overview = "A complete Jellyfin overview."
        detail.taglines = ["For some, 13 feels like it was just yesterday."]
        detail.familyGuidance = .init(recommendedAge: 13, qualityRating: nil)
        let account = resolved(accountID, detail: detail)

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([sparse])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].overview, detail.overview)
        XCTAssertEqual(result[0].taglines, detail.taglines)
        XCTAssertEqual(result[0].familyGuidance, detail.familyGuidance)
        XCTAssertEqual(result[0].id, sparse.id)
        XCTAssertEqual(result[0].sourceAccountID, sparse.sourceAccountID)
    }

    func testPreservesExistingOverviewAndTaglinesWhileFillingOtherMissingFields() async throws {
        let accountID = "jellyfin-account"
        let sparse = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            overview: "Server-selected overview.",
            taglines: ["Server-selected tagline."],
            sourceAccountID: accountID
        )
        var detail = sparse
        detail.overview = "Replacement overview."
        detail.taglines = ["Replacement tagline."]
        detail.productionYear = 2004
        detail.officialRating = "PG-13"
        detail.genres = ["Comedy"]
        let account = resolved(accountID, detail: detail)

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([sparse])

        XCTAssertEqual(result[0].overview, sparse.overview)
        XCTAssertEqual(result[0].taglines, sparse.taglines)
        XCTAssertEqual(result[0].productionYear, 2004)
        XCTAssertEqual(result[0].officialRating, "PG-13")
        XCTAssertEqual(result[0].genres, ["Comedy"])
    }

    func testEpisodeHydrationPreservesSelectedSourceAccountAndHierarchy() async throws {
        let accountID = "jellyfin-account"
        let original = MediaItem(
            id: "plex-discover-episode",
            title: "The Getaway",
            kind: .episode,
            seriesID: "plex-series",
            providerIDs: ["SeriesTmdb": "125988"],
            discoverySources: [.tvdb],
            discoveryURLs: ["tvdb": URL(string: "https://thetvdb.com/tv/42/show")!],
            sourceAccountID: "plex-account",
            sources: [
                MediaSourceRef(
                    accountID: accountID,
                    itemID: "jellyfin-episode",
                    kind: .episode
                )
            ]
        )
        let hydratedEpisode = MediaItem(
            id: "jellyfin-episode",
            title: "The Getaway",
            kind: .episode,
            seasonNumber: 1,
            episodeNumber: 4,
            seriesID: "jellyfin-series",
            seasonID: "jellyfin-season",
            providerIDs: ["Tmdb": "episode-4"]
        )
        let series = MediaItem(
            id: "jellyfin-series",
            title: "Silo",
            kind: .series,
            familyGuidance: .init(recommendedAge: 14, qualityRating: nil),
            genres: ["Science Fiction"],
            providerIDs: ["Tmdb": "125988", "Tvdb": "403245"]
        )
        let account = resolved(
            accountID,
            details: [
                hydratedEpisode.id: hydratedEpisode,
                series.id: series
            ]
        )

        let enrich = makeHeroMetadataEnricher(
            accounts: [account],
            identitySources: { _ in [] }
        )
        let result = await enrich([original])

        XCTAssertEqual(result[0].id, hydratedEpisode.id)
        XCTAssertEqual(result[0].sourceAccountID, accountID)
        XCTAssertEqual(result[0].seriesID, series.id)
        XCTAssertEqual(result[0].seasonID, hydratedEpisode.seasonID)
        XCTAssertEqual(result[0].providerID(.tmdb), "episode-4")
        XCTAssertEqual(result[0].providerID(.seriesTmdb), "125988")
        XCTAssertEqual(result[0].providerID(.seriesTvdb), "403245")
        XCTAssertEqual(result[0].discoverySources, [.tvdb])
        XCTAssertEqual(result[0].discoveryURLs, original.discoveryURLs)
        XCTAssertEqual(result[0].familyGuidance, series.familyGuidance,
                       "The Home slide represents the series while retaining the episode play target.")
    }

    func testMergesSharedCachedRatingsWithoutStartingProviderWork() async {
        let accountID = "plex-account"
        let item = MediaItem(
            id: "arrietty",
            title: "The Secret World of Arrietty",
            kind: .movie,
            overview: "A tiny family lives beneath the floorboards.",
            productionYear: 2010,
            officialRating: "G",
            taglines: ["Discover a secret world."],
            ratings: [
                ExternalRating(source: .imdb, value: 7.6, scale: .outOfTen)
            ],
            sourceAccountID: accountID
        )
        let cached = CachedHeroRatingsProvider(
            ratings: [
                ExternalRating(source: .imdb, value: 7.6, scale: .outOfTen),
                ExternalRating(source: .tmdb, value: 7.7, scale: .outOfTen),
                ExternalRating(source: .anilist, value: 79, scale: .percent),
            ]
        )
        let enrich = makeHeroMetadataEnricher(
            accounts: [resolved(accountID, detail: item)],
            identitySources: { _ in [] },
            ratingsProvider: cached
        )

        let result = await enrich([item])

        XCTAssertEqual(
            Set<RatingSource>(result[0].ratings.map { $0.source }),
            [.imdb, .tmdb, .anilist]
        )
        XCTAssertEqual(cached.fetchCount, 0)
        XCTAssertEqual(cached.cacheReadCount, 1)
    }

    private func resolved(_ accountID: String, detail: MediaItem) -> ResolvedAccount {
        resolved(accountID, details: [detail.id: detail])
    }

    private func resolved(
        _ accountID: String,
        details: [String: MediaItem],
        childrenByID: [String: [MediaItem]] = [:]
    ) -> ResolvedAccount {
        let session = UserSession(
            server: MediaServer(
                id: "server-\(accountID)",
                name: "Server",
                baseURL: URL(string: "http://jellyfin.local")!,
                provider: .jellyfin
            ),
            userID: "user",
            userName: "User",
            deviceID: "device",
            accessToken: "token"
        )
        let account = Account(
            id: accountID,
            server: session.server,
            userID: session.userID,
            userName: session.userName,
            deviceID: session.deviceID
        )
        return ResolvedAccount(
            account: account,
            provider: HeroMetadataProvider(session: session, details: details, childrenByID: childrenByID)
        )
    }
}

private final class CachedHeroRatingsProvider:
    CachedExternalRatingsProviding,
    @unchecked Sendable {
    private let lock = NSLock()
    private let stored: [ExternalRating]
    private var _fetchCount = 0
    private var _cacheReadCount = 0

    init(ratings: [ExternalRating]) {
        stored = ratings
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var fetchCount: Int {
        withLock { _fetchCount }
    }

    var cacheReadCount: Int {
        withLock { _cacheReadCount }
    }

    func ratings(for item: MediaItem) async -> [ExternalRating] {
        withLock { _fetchCount += 1 }
        return stored
    }

    func cachedRatings(for item: MediaItem) async -> [ExternalRating]? {
        withLock { _cacheReadCount += 1 }
        return stored
    }
}

private class HeroMetadataProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session: UserSession
    private let details: [String: MediaItem]
    private let childrenByID: [String: [MediaItem]]

    init(session: UserSession, details: [String: MediaItem], childrenByID: [String: [MediaItem]] = [:]) {
        self.session = session
        self.details = details
        self.childrenByID = childrenByID
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func item(id: String) async throws -> MediaItem {
        guard let detail = details[id] else { throw AppError.notFound }
        return detail
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { childrenByID[itemID] ?? [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private final class GuidanceHeroMetadataProvider: HeroMetadataProvider, FamilyGuidanceProviding, @unchecked Sendable {
    func familyGuidance(for item: MediaItem, accountToken: String?) async throws -> FamilyGuidanceAvailability {
        XCTFail("Hero enrichment must not request the cloud review.")
        return .unavailable
    }
}
