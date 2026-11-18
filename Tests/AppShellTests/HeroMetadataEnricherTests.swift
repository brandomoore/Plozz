import XCTest
import Foundation
import CoreModels
import CoreNetworking
import MetadataKit
import ProviderJellyfin
import ProviderPlex
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

private actor HeroRecoveryPolicy {
    var visibility = HomeLibraryVisibility.default
    var allowsDiscovery = true

    func restrict(library: Bool) {
        if library {
            visibility.disabledKeys = ["account:movies"]
        } else {
            allowsDiscovery = false
        }
    }
}

final class HeroMetadataEnricherTests: XCTestCase {
    @MainActor
    func testLiveDiscoveryRecoveryAgainstInternalLibraries() async throws {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HERO_BROKER"] else {
            throw XCTSkip("Requires an authorized internal account and metadata credential broker.")
        }
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw AppError.invalidResponse }
        struct Configuration: Decodable {
            struct Connection: Decodable {
                let provider: ProviderKind
                let baseURL: URL
                let serverID: String
                let userID: String
                let username: String
                let deviceID: String
                let token: String
            }
            let tmdbToken: String
            let accounts: [Connection]
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(Set(configuration.accounts.map(\.provider)), [.jellyfin, .plex])
        let discovery = try await TMDbDiscoveryProvider(access: .directToken(configuration.tmdbToken))
            .discover(.init(limit: 16))
        XCTAssertFalse(discovery.isEmpty, "Use live Home Discovery, not a recorded metadata fixture.")
        XCTAssertTrue(discovery.allSatisfy { !$0.locallyValidatedPlayableSource && !$0.discoverySources.isEmpty })
        for connection in configuration.accounts {
            let session = UserSession(
                server: .init(id: connection.serverID, name: "Internal hero verification",
                              baseURL: connection.baseURL, provider: connection.provider),
                userID: connection.userID, userName: connection.username,
                deviceID: connection.deviceID, accessToken: connection.token
            )
            let http = HeroLiveReadOnlyHTTP()
            let accountID = "live-\(connection.provider.rawValue)"
            let provider: any MediaProvider = connection.provider == .plex
                ? PlexProvider(session: session, accountID: accountID, http: http)
                : JellyfinProvider(session: session, accountID: accountID, http: http)
            let account = ResolvedAccount(account: Account(id: accountID, from: session), provider: provider)
            let libraries = try await provider.libraries()
            let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isServerCollectionDirectory })
            let collections = try await provider.collections(in: library.id, page: .init(limit: 2))
            let collection = try XCTUnwrap(collections.items.first)
            let members = try await provider.collectionMembers(of: collection.id, page: .init(limit: 4))
            let collectionItems = members.items.map { $0.taggingSource(accountID).taggingLibrary(library.id) }
            XCTAssertFalse(collectionItems.isEmpty)
            let candidates = InterleaveHeroStrategy().compose([discovery, collectionItems], limit: 24)
            let baseline = await HeroMetadataEnricher(accounts: [account], targetSelector: { $0 }).enrich(discovery)
            XCTAssertTrue(baseline.allSatisfy { !$0.hasPlayableLibraryTarget() })
            let enricher = HeroMetadataEnricher(
                accounts: [account],
                targetSelector: { PlaybackSourceSelection.bestPlayItem($0, accounts: [account], identitySources: { _ in [] }) },
                libraryTargetResolver: heroLibraryTargetResolver(in: [account], identitySources: { _ in [] })
            )
            let enriched = await enricher.enrich(candidates)
            XCTAssertEqual(enriched.count, candidates.count)
            let recovered = zip(candidates, enriched).filter {
                !$0.0.locallyValidatedPlayableSource && $0.1.locallyValidatedPlayableSource
            }
            XCTAssertFalse(recovered.isEmpty, "Live Discovery must overlap this real library.")
            XCTAssertTrue(enriched.contains { !$0.locallyValidatedPlayableSource && !$0.hasPlayableLibraryTarget() },
                          "Real unavailable Discovery titles must not gain Play.")
            XCTAssertTrue(collectionItems.allSatisfy { member in
                enriched.contains { $0.id == member.id && $0.hasPlayableLibraryTarget() }
            }, "Mixing Discovery must retain real collection playback.")
            let series = try XCTUnwrap(recovered.first { $0.0.kind == .series })
            let seed = series.0
            let pinned = await enricher.enrich([seed], preservingPinnedSeries: { [seed] })
            let visible = try XCTUnwrap(HeroLiveMerge.merge(
                showing: [seed], fresh: pinned, limit: 1, pinnedItemIDs: [seed.id],
                preservesPinnedItems: true
            ).items.first)
            XCTAssertEqual(visible.id, seed.id)
            XCTAssertEqual(visible.kind, .series)
            XCTAssertEqual(visible.heroCTA(seerConnected: false), .play)
            XCTAssertNotNil(visible.productionYear)
            XCTAssertFalse(visible.genres.isEmpty)
            XCTAssertFalse(visible.ratings.isEmpty)
            let root = PlaybackSourceSelection.bestPlayItem(visible, accounts: [account], identitySources: { _ in [] })
            let native = try await provider.item(id: root.id)
            XCTAssertEqual(native.kind, .series)
            XCTAssertTrue(HeroDiscoveryIdentityVerification.matches(seed, native))
            XCTAssertTrue(Set(visible.ratings).isSuperset(of: Set(native.ratings)))
            let resolvedPlayTarget = await HeroPlayTargetResolver.playbackTarget(for: root, provider: provider)
            let playTarget = try XCTUnwrap(resolvedPlayTarget)
            let episode = try await provider.item(id: playTarget.id)
            XCTAssertEqual(episode.kind, .episode)
            XCTAssertEqual(episode.seriesID, native.id)
            XCTAssertEqual(playTarget.sourceAccountID, accountID)
            if let disabled = libraries.first(where: { $0.id != library.id && $0.kind != .series }) {
                var visibility = HomeLibraryVisibility.default
                visibility.disabledKeys = ["\(accountID):\(disabled.id)"]
                let restricted = visibility
                let resolve = try XCTUnwrap(heroLibraryTargetResolver(
                    in: [account], identitySources: { _ in [] }, visibility: { restricted }
                ))
                let scoped = await resolve(seed)
                XCTAssertEqual(scoped?.locallyValidatedPlayableSource, true)
                XCTAssertNotNil(scoped?.libraryID, "A scoped search must retain real enabled-library provenance.")
            } else {
                XCTFail("The internal fixture must expose an unrelated library for visibility verification.")
            }
            let counts = await http.counts()
            XCTAssertEqual(counts.blocked, 0)
            print("LIVE_HERO provider=\(connection.provider.rawValue) discovery=\(discovery.count) recovered=\(recovered.count) collections=\(collectionItems.count) pinnedPlay=true ratings=\(visible.ratings.count) realEpisode=true reads=\(counts.reads) blocked=\(counts.blocked)")
        }
    }

    @MainActor
    func testColdHeroRecoversLibraryShowAndRatingsWithoutAnIndexMatch() async throws {
        for kind in [ProviderKind.jellyfin, .plex, .emby] {
            let seed = MediaItem(
                id: "tmdb:series:42", title: "Hospital", kind: .series,
                overview: "A hospital drama.", providerIDs: ["Tmdb": "42"],
                discoverySources: [.tmdb],
                availability: .unknown, locallyValidatedPlayableSource: false
            )
            let series = MediaItem(
                id: "library-series", title: seed.title, kind: .series,
                overview: seed.overview, productionYear: 2025, genres: ["Drama"],
                ratings: [
                    .init(source: .community, value: 8.9, scale: .outOfTen),
                    .init(source: .rottenTomatoes, value: 96, scale: .percent)
                ],
                providerIDs: seed.providerIDs
            )
            let episode = MediaItem(
                id: "library-episode", title: "The next shift", kind: .episode,
                seasonNumber: 2, episodeNumber: 6, seriesID: series.id
            )
            let account = resolved(
                "account", details: [series.id: series, episode.id: episode],
                childrenByID: [series.id: [episode]], provider: kind,
                searchResults: [series]
            )
            let enrich = makeHeroMetadataEnricher(
                accounts: [account], identitySources: { _ in [] }
            )

            let results = await enrich([seed])
            let result = try XCTUnwrap(results.first)

            XCTAssertEqual(result.id, episode.id)
            XCTAssertEqual(result.kind, .episode)
            XCTAssertEqual(result.sourceAccountID, account.account.id)
            XCTAssertEqual(result.seriesID, series.id)
            XCTAssertEqual(result.ratings, series.ratings)
            XCTAssertEqual(result.genres, series.genres)
            XCTAssertEqual(result.heroCTA(seerConnected: false), .play)
            XCTAssertFalse(DetailOpenEnvironment.isDiscovery(result, identitySources: { _ in [] }))

            let pinned = await HeroMetadataEnricher.withPinnedSeries({ [seed] }) {
                await enrich([seed])
            }
            let merged = HeroLiveMerge.merge(
                showing: [seed], fresh: pinned, limit: 1,
                pinnedItemIDs: [seed.id], preservesPinnedItems: true
            )
            let visible = try XCTUnwrap(merged.items.first)
            XCTAssertEqual(visible.id, seed.id)
            XCTAssertEqual(visible.kind, .series)
            XCTAssertEqual(visible.productionYear, series.productionYear)
            XCTAssertEqual(Set(visible.ratings), Set(series.ratings))
            XCTAssertEqual(visible.heroCTA(seerConnected: false), .play)
            let selected = PlaybackSourceSelection.bestPlayItem(
                visible, accounts: [account], identitySources: { _ in [] }
            )
            XCTAssertEqual(selected.id, series.id)
            let nextEpisode = await HeroPlayTargetResolver.playbackTarget(
                for: selected, provider: account.provider
            )
            XCTAssertEqual(nextEpisode?.id, episode.id)
            XCTAssertEqual(nextEpisode?.sourceAccountID, account.account.id)
        }
    }

    private actor HeroLiveReadOnlyHTTP: HTTPClient {
        private let client = URLSessionHTTPClient()
        private var reads = 0
        private var blocked = 0

        func counts() -> (reads: Int, blocked: Int) { (reads, blocked) }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let path = endpoint.path.lowercased()
            guard endpoint.method == .get, endpoint.body == nil, !path.contains("/:/"),
                  !path.contains("playbackinfo"), !path.contains("transcode"), !path.contains("/sessions"),
                  reads < 350 else {
                blocked += 1
                throw AppError.invalidResponse
            }
            reads += 1
            return try await client.send(endpoint, baseURL: baseURL)
        }
    }

    func testColdHeroRecoveryVerifiesLiveRecordsAndLibraryVisibility() async throws {
        let seed = MediaItem(
            id: "tmdb:42", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"],
            discoverySources: [.tmdb], availability: .unknown, locallyValidatedPlayableSource: false
        )
        let owned = MediaItem(
            id: "physical", title: seed.title, kind: .movie, productionYear: 2025,
            ratings: [.init(source: .community, value: 8, scale: .outOfTen)],
            providerIDs: seed.providerIDs, libraryID: "movies"
        )
        for scenario in ["owned", "missing", "conflicting-id", "wrong-kind", "unvalidated", "hidden"] {
            var record = owned
            var visibility = HomeLibraryVisibility.default
            switch scenario {
            case "conflicting-id": record.providerIDs = ["Tmdb": "99"]
            case "wrong-kind": record.kind = .series
            case "unvalidated": record.locallyValidatedPlayableSource = false
            case "hidden": visibility.disabledKeys = ["account:movies"]
            default: break
            }
            let currentVisibility = visibility
            let account = resolved(
                "account", details: scenario == "missing" ? [:] : [record.id: record],
                searchResults: [owned]
            )
            let enrich = makeHeroMetadataEnricher(
                accounts: [account], identitySources: { _ in [] },
                visibility: { currentVisibility }
            )
            let results = await enrich([seed])
            let result = try XCTUnwrap(results.first)
            if scenario == "owned" {
                XCTAssertEqual(result.id, owned.id)
                XCTAssertEqual(result.sourceAccountID, account.account.id)
                XCTAssertEqual(result.productionYear, owned.productionYear)
                XCTAssertEqual(result.ratings, owned.ratings)
                XCTAssertEqual(result.heroCTA(seerConnected: false), .play)
                XCTAssertEqual(result.discoverySources, seed.discoverySources)
            } else {
                XCTAssertEqual(result, seed, scenario)
                XCTAssertFalse(result.hasPlayableLibraryTarget(), scenario)
            }
        }
    }

    func testRecoveredWatchEvidenceRemovesPinnedAndCachedSeriesBeforeEpisodeResolution() async throws {
        let seed = MediaItem(
            id: "tmdb:series:42", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"],
            discoverySources: [.tmdb], availability: .unknown, locallyValidatedPlayableSource: false
        )
        var illustratedSeed = seed
        illustratedSeed.backdropURL = URL(string: "https://artwork.invalid/hero.jpg")
        let series = MediaItem(
            id: "physical", title: seed.title, kind: .series, hasBeenPlayed: true,
            providerIDs: seed.providerIDs
        )
        let episode = MediaItem(id: "next-episode", title: "Next", kind: .episode, seriesID: series.id)
        let account = resolved(
            "account", details: [series.id: series, episode.id: episode],
            childrenByID: [series.id: [episode]], searchResults: [series]
        )
        let hidden = makeHeroMetadataEnricher(
            accounts: [account], identitySources: { _ in [] }, hideWatched: true
        )
        let hiddenResults = await hidden([illustratedSeed])
        XCTAssertEqual(hiddenResults.first?.id, series.id)
        XCTAssertEqual(hiddenResults.first?.hasBeenPlayed, true)
        var settings = HeroSettings.default
        settings.isEnabled = true
        settings.sources = [.featured]
        settings.hideWatched = true
        let curator = HeroCurator()
        let refreshed = HeroLiveMerge.merge(
            showing: [seed], fresh: hiddenResults, limit: 1,
            pinnedItemIDs: [seed.id], preservesPinnedItems: true, preservesLineup: true
        )
        XCTAssertEqual(refreshed.items.first?.id, seed.id)
        XCTAssertEqual(refreshed.items.first?.hasBeenPlayed, true)
        let fresh = curator.reconcile(hiddenResults, settings: settings, watchMutations: [])
        for previous in [illustratedSeed, episode.taggingSource("account")] {
            let showing = curator.reconcile(
                [previous], settings: settings, watchMutations: [], verifiedWatchItems: hiddenResults
            )
            let merged = HeroLiveMerge.merge(
                showing: showing, fresh: fresh, limit: 1,
                pinnedItemIDs: [previous.id], preservesPinnedItems: true
            )
            XCTAssertTrue(merged.items.isEmpty, "Pinning must not retain a watched root or its prior episode.")
        }
        let unrelated = episode.taggingSource("another-account")
        XCTAssertEqual(curator.reconcile(
            [unrelated], settings: settings, watchMutations: [], verifiedWatchItems: hiddenResults
        ), [unrelated], "Bare series IDs cannot carry exclusions across accounts.")
        let pool = HeroFreshnessCandidatePool(buckets: [.init(source: .featured, items: [illustratedSeed])])
            .updatingItems(hiddenResults)
        let restored = try JSONDecoder().decode(
            HeroFreshnessCandidatePool.self, from: JSONEncoder().encode(pool.durable())
        )
        XCTAssertEqual(restored.buckets.first?.items.first?.hasBeenPlayed, true)
        XCTAssertTrue(restored.select(settings: settings).isEmpty, "The next launch must retain the exclusion.")
        var visibleSettings = settings
        visibleSettings.hideWatched = false
        XCTAssertEqual(restored.select(settings: visibleSettings).count, 1, "Artwork must not explain the exclusion.")
        XCTAssertEqual(curator.reconcile(
            refreshed.items, settings: settings, watchMutations: [], preservesLineup: true
        ).count, 1, "Showcase retains its session lineup.")
        let visible = makeHeroMetadataEnricher(
            accounts: [account], identitySources: { _ in [] }, hideWatched: false
        )
        let visibleResults = await visible([seed])
        XCTAssertEqual(visibleResults.first?.id, episode.id)
    }

    func testHeroRecoveryRetainsHealthyAccountWhenAnotherTimesOut() async throws {
        let record = MediaItem(id: "physical", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"])
        let healthy = resolved("healthy", details: [record.id: record], searchResults: [record])
        let slow = resolved("slow", detail: record)
        let provider = HeroMetadataProvider(
            session: slow.provider.session, details: [record.id: record], searchResults: [record],
            onSearch: {
                do {
                    try await Task.sleep(for: .seconds(30))
                    XCTFail("The slow account must be cancelled.")
                } catch is CancellationError {
                } catch {
                    XCTFail("Unexpected search failure: \(error)")
                }
            }
        )
        let resolve = try XCTUnwrap(heroLibraryTargetResolver(
            in: [.init(account: slow.account, provider: provider), healthy], identitySources: { _ in [] }
        ))
        let started = ContinuousClock.now
        let result = await resolve(record.removingDiscoveryOwnership())
        XCTAssertLessThan(started.duration(to: .now), .seconds(6))
        XCTAssertEqual(result?.sourceAccountID, healthy.account.id)
        XCTAssertEqual(result?.sources.map(\.accountID), [healthy.account.id])
        XCTAssertEqual(result?.locallyValidatedPlayableSource, true)
    }

    func testHeroRecoveryUsesEnabledLibrarySearchProvenanceForSparseDetails() async throws {
        let record = MediaItem(id: "physical", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"])
        let base = resolved("account", detail: record)
        let provider = HeroMetadataProvider(
            session: base.provider.session, details: [record.id: record], searchResults: [record],
            scopedSearchResults: [record.taggingLibrary("movies")]
        )
        var visibility = HomeLibraryVisibility.default
        visibility.disabledKeys = ["account:extras"]
        let restricted = visibility
        let resolve = try XCTUnwrap(heroLibraryTargetResolver(
            in: [.init(account: base.account, provider: provider)], identitySources: { _ in [] },
            visibility: { restricted }
        ))
        let result = await resolve(record.removingDiscoveryOwnership())
        XCTAssertEqual(result?.id, record.id)
        XCTAssertEqual(result?.libraryID, "movies")
        XCTAssertEqual(result?.sources.first?.libraryID, "movies")
        XCTAssertEqual(result?.locallyValidatedPlayableSource, true)
    }

    func testHeroRecoveryDeadlineCancelsSearchAndRejectsItsLateMatch() async throws {
        let record = MediaItem(id: "physical", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"])
        let base = resolved("account", detail: record)
        let cancelled = expectation(description: "Search cancellation observed")
        let provider = HeroMetadataProvider(
            session: base.provider.session, details: [record.id: record], searchResults: [record],
            onSearch: {
                do {
                    try await Task.sleep(for: .seconds(30))
                    XCTFail("The recovery deadline must cancel the search.")
                } catch is CancellationError {
                    cancelled.fulfill()
                } catch {
                    XCTFail("Unexpected search failure: \(error)")
                }
            }
        )
        let account = ResolvedAccount(account: base.account, provider: provider)
        let resolve = try XCTUnwrap(heroLibraryTargetResolver(
            in: [account], identitySources: { _ in [] }
        ))
        let started = ContinuousClock.now
        let result = await resolve(record.removingDiscoveryOwnership())
        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: .now), .seconds(6))
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testHeroRecoveryDoesNotSearchOwnedTitleOnlyIndexedOrRestrictedCandidates() async throws {
        let owned = MediaItem(
            id: "physical", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"],
            sourceAccountID: "account"
        )
        let base = resolved("account", detail: owned)
        let provider = HeroMetadataProvider(
            session: base.provider.session, details: [owned.id: owned],
            onSearch: { XCTFail("This candidate must not start a fallback search.") }
        )
        let account = ResolvedAccount(account: base.account, provider: provider)
        var external = owned.removingDiscoveryOwnership()
        external.discoverySources = [.tmdb]
        var titleOnly = external
        titleOnly.providerIDs = [:]
        let resolve = try XCTUnwrap(heroLibraryTargetResolver(
            in: [account], identitySources: { _ in [] }
        ))
        let ownedResult = await resolve(owned)
        let titleOnlyResult = await resolve(titleOnly)
        XCTAssertNil(ownedResult)
        XCTAssertNil(titleOnlyResult)
        let indexed = try XCTUnwrap(heroLibraryTargetResolver(
            in: [account], identitySources: { _ in [
                .init(accountID: "account", itemID: "physical", kind: .movie)
            ] }
        ))
        let indexedResult = await indexed(external)
        XCTAssertNil(indexedResult, "An index verification rejection is not a cold-index miss.")
        let restricted = try XCTUnwrap(heroLibraryTargetResolver(
            in: [account], identitySources: { _ in [] }, allowsDiscovery: { false }
        ))
        let restrictedResult = await restricted(external)
        XCTAssertNil(restrictedResult)
        XCTAssertNil(heroLibraryTargetResolver(in: [], identitySources: { _ in [] }))
    }

    func testHeroRecoveryDropsResultsWhenVisibilityOrDiscoveryPolicyChangesDuringSearch() async throws {
        for changesLibrary in [false, true] {
            let record = MediaItem(
                id: "physical", title: "Film", kind: .movie, providerIDs: ["Tmdb": "42"],
                libraryID: "movies"
            )
            let base = resolved("account", detail: record)
            let policy = HeroRecoveryPolicy()
            let provider = HeroMetadataProvider(
                session: base.provider.session, details: [record.id: record], searchResults: [record],
                onSearch: { await policy.restrict(library: changesLibrary) }
            )
            let account = ResolvedAccount(account: base.account, provider: provider)
            let resolve = try XCTUnwrap(heroLibraryTargetResolver(
                in: [account], identitySources: { _ in [] },
                visibility: { await policy.visibility },
                allowsDiscovery: { await policy.allowsDiscovery }
            ))
            let result = await resolve(record.removingDiscoveryOwnership())
            XCTAssertNil(result)
        }
    }

    func testHeroRecoveryIsBoundedAndCancellationDoesNotPublishOrAdmitMoreTitles() async {
        for cancels in [false, true] {
            let firstWave = expectation(description: "Four library lookups admitted")
            let probe = HeroRequestIdentityBatchProbe(firstWave: firstWave)
            let items = (100..<112).map { id in
                MediaItem(
                    id: "\(id)", title: "Title \(id)", kind: .movie, providerIDs: ["Tmdb": "\(id)"],
                    discoverySources: [.tmdb], availability: .unknown, locallyValidatedPlayableSource: false
                )
            }
            let enricher = HeroMetadataEnricher(
                accounts: [], targetSelector: { $0 },
                libraryTargetResolver: {
                    _ = await probe.resolve($0)
                    return nil
                }
            )
            let task = Task { await enricher.enrich(items) }
            await fulfillment(of: [firstWave], timeout: 2)
            let initiallyAdmitted = await probe.calls
            if cancels { task.cancel() }
            await probe.release()
            let result = await task.value
            let calls = await probe.calls
            let maximumActive = await probe.maximumActive
            XCTAssertEqual(initiallyAdmitted, 4)
            XCTAssertEqual(calls, cancels ? 4 : items.count)
            XCTAssertLessThanOrEqual(maximumActive, 4)
            XCTAssertEqual(result, items)
        }
    }

    func testHydratedSquareArtworkKeepsItsSourceAccount() async throws {
        let square = try XCTUnwrap(URL(string: "https://selected.test/square.jpg"))
        let seed = MediaItem(id: "movie", title: "Movie", kind: .movie, sourceAccountID: "original")
        var root = seed
        root.overview = "Description"
        root.artworkSelections = [.init(placement: .squareHero, references: [.remote(square)])]
        root = root.taggingSource("selected")
        let target = root
        let enricher = HeroMetadataEnricher(
            accounts: [resolved("selected", details: [root.id: root])],
            targetSelector: { _ in target }
        )
        let items = await enricher.enrich([seed])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.artworkReferences(for: .squareHero), [.remote(square)])
        XCTAssertEqual(item.artworkSourceAccountID(for: square), "selected")
        XCTAssertEqual(item.sourceAccountID, "original")
    }

    func testHomeUsesOnlyMemoryCachedServerRatingsForSparseAndCompleteItems() async throws {
        let native = ExternalRating(source: .community, value: 7, scale: .outOfTen)
        let supplied = ExternalRating(source: .imdb, value: 8.7, scale: .outOfTen)
        for sparse in [false, true] {
            for cached in [false, true] {
                let full = MediaItem(
                    id: "movie", title: "Native title", kind: .movie, overview: "Native description",
                    productionYear: 2025, officialRating: "PG", taglines: ["Native tagline"],
                    ratings: [native], sourceAccountID: "account"
                )
                var seed = full
                if sparse { seed.overview = nil }
                let base = resolved("account", details: [full.id: full])
                let provider = ServerRatingsHeroMetadataProvider(
                    session: base.provider.session, details: [full.id: full]
                )
                provider.cached = cached ? [full.id: [supplied]] : [:]
                let enricher = HeroMetadataEnricher(
                    accounts: [ResolvedAccount(account: base.account, provider: provider)],
                    targetSelector: { $0 }
                )
                let results = await enricher.enrich([seed])
                let result = try XCTUnwrap(results.first)
                XCTAssertEqual(result.overview, full.overview)
                XCTAssertEqual(result.ratings, cached ? [supplied] : [native])
                XCTAssertEqual(result.usesProviderRatings, cached)
            }
        }
    }

    func testCompleteHeroUsesSelectedAccountsItemIDForItsMemoryCache() async throws {
        let original = MediaItem(
            id: "original", title: "Native title", kind: .movie, overview: "Native description",
            productionYear: 2025, officialRating: "PG", taglines: ["Native tagline"],
            sourceAccountID: "original-account"
        )
        var selected = original
        selected.id = "selected"
        selected.sourceAccountID = "selected-account"
        let supplied = ExternalRating(source: .imdb, value: 8.7, scale: .outOfTen)
        let base = resolved("selected-account", details: [selected.id: selected])
        let provider = ServerRatingsHeroMetadataProvider(
            session: base.provider.session, details: [selected.id: selected]
        )
        provider.cached = [selected.id: [supplied]]
        let target = selected
        let enricher = HeroMetadataEnricher(
            accounts: [ResolvedAccount(account: base.account, provider: provider)],
            targetSelector: { _ in target }
        )
        let results = await enricher.enrich([original])
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.sourceAccountID, original.sourceAccountID)
        XCTAssertEqual(result.overview, original.overview)
        XCTAssertEqual(result.ratings, [supplied])
        XCTAssertTrue(result.usesProviderRatings)
    }

    func testProviderSeriesSynopsisStaysSeparateFromEpisodeText() async throws {
        for provider in [ProviderKind.jellyfin, .emby, .plex] {
            let accountID = provider.rawValue
            let episode = MediaItem(
                id: "episode", title: "Episode", kind: .episode,
                overview: "Episode spoiler", taglines: ["Episode tagline"],
                seriesID: "series", resumePosition: 90, sourceAccountID: accountID
            )
            let series = MediaItem(
                id: "series", title: "La serie", kind: .series,
                overview: "Le synopsis choisi sur le serveur."
            )
            let account = resolved(
                accountID, details: [episode.id: episode, series.id: series], provider: provider
            )
            let enricher = HeroMetadataEnricher(accounts: [account], targetSelector: { $0 })
            let results = await enricher.enrich([episode])
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.overview, episode.overview)
            XCTAssertEqual(result.taglines, episode.taglines)
            XCTAssertEqual(result.seriesSynopsis?.overview, series.overview)
            XCTAssertEqual(result.seriesSynopsis?.sourceAccountID, accountID)
            XCTAssertEqual(result.seriesSynopsis?.matches(result), true)
            XCTAssertEqual(result.parentTitle, series.title)
            XCTAssertEqual(result.resumePosition, 90)
            XCTAssertEqual(result.id, episode.id)
        }
    }

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
        childrenByID: [String: [MediaItem]] = [:],
        provider: ProviderKind = .jellyfin,
        searchResults: [MediaItem] = []
    ) -> ResolvedAccount {
        let session = UserSession(
            server: MediaServer(
                id: "server-\(accountID)",
                name: "Server",
                baseURL: URL(string: "http://jellyfin.local")!,
                provider: provider
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
            provider: HeroMetadataProvider(
                session: session, details: details, childrenByID: childrenByID,
                searchResults: searchResults
            )
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
    var kind: ProviderKind { session.server.provider }
    let session: UserSession
    private let details: [String: MediaItem]
    private let childrenByID: [String: [MediaItem]]
    private let searchResults: [MediaItem]
    private let scopedSearchResults: [MediaItem]?
    private let onSearch: @Sendable () async -> Void

    init(
        session: UserSession, details: [String: MediaItem],
        childrenByID: [String: [MediaItem]] = [:], searchResults: [MediaItem] = [],
        scopedSearchResults: [MediaItem]? = nil,
        onSearch: @escaping @Sendable () async -> Void = {}
    ) {
        self.session = session
        self.details = details
        self.childrenByID = childrenByID
        self.searchResults = searchResults
        self.scopedSearchResults = scopedSearchResults
        self.onSearch = onSearch
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
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        await onSearch()
        return Array(searchResults.prefix(limit))
    }
    func search(query: String, limit: Int, excludingLibraries disabledLibraryIDs: [String]) async throws -> [MediaItem] {
        guard !disabledLibraryIDs.isEmpty, let scopedSearchResults else {
            return try await search(query: query, limit: limit)
        }
        return Array(scopedSearchResults.filter {
            !disabledLibraryIDs.contains($0.libraryID ?? "")
        }.prefix(limit))
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private final class ServerRatingsHeroMetadataProvider: HeroMetadataProvider, ServerRatingsProviding, @unchecked Sendable {
    var cached: [String: [ExternalRating]] = [:]

    func serverRatings(for item: MediaItem) async throws -> [ExternalRating]? {
        XCTFail("Home publication must never request optional server metadata.")
        return nil
    }

    func cachedServerRatings(for item: MediaItem) async -> [ExternalRating]? { cached[item.id] }
}

private final class GuidanceHeroMetadataProvider: HeroMetadataProvider, FamilyGuidanceProviding, @unchecked Sendable {
    func familyGuidance(for item: MediaItem, accountToken: String?) async throws -> FamilyGuidanceAvailability {
        XCTFail("Hero enrichment must not request the cloud review.")
        return .unavailable
    }
}
