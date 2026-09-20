import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

final class HeroFreshnessTests: XCTestCase {
    private func item(_ id: String, account: String? = nil) -> MediaItem {
        MediaItem(
            id: id, title: id, kind: .movie,
            backdropURL: URL(string: "https://example.com/\(id).jpg"),
            sourceAccountID: account
        )
    }

    private func settings(_ sources: [HeroSourceKind] = [.featured], limit: Int = 8) -> HeroSettings {
        var settings = HeroSettings.default
        settings.sources = sources
        settings.maxItems = limit
        return settings
    }

    private func pool(_ items: [MediaItem], source: HeroSourceKind = .featured) -> HeroFreshnessCandidatePool {
        HeroFreshnessCandidatePool(buckets: [.init(source: source, items: items)])
    }

    func testDiscoveryPrefersUnseenThenLeastRecentlySeen() {
        let items = [item("recent"), item("unseen"), item("older")]
        var history = HeroExposureHistory()
        history.record(items[0], at: Date(timeIntervalSince1970: 20))
        history.record(items[2], at: Date(timeIntervalSince1970: 10))
        let selected = pool(items).select(
            settings: settings(),
            freshness: .init(history: history, sessionSeed: 1)
        )
        XCTAssertEqual(selected.map(\.id), ["unseen", "older", "recent"])
    }

    func testEqualRankShuffleIsStableWithinSessionButVariesAcrossSeeds() {
        let candidates = pool((0..<12).map { item("candidate-\($0)") })
        let first = candidates.select(settings: settings(), freshness: .init(sessionSeed: 1))
        XCTAssertEqual(
            candidates.select(settings: settings(), freshness: .init(sessionSeed: 1)), first
        )
        let openers = Set((1...12).compactMap {
            candidates.select(settings: settings(), freshness: .init(sessionSeed: UInt64($0))).first?.id
        })
        XCTAssertGreaterThan(openers.count, 1)
    }

    func testOneSlideCacheHasAlternativesAndDoesNotRepeatExposedOpener() {
        let candidates = pool([item("a"), item("b"), item("c")])
        let config = settings(limit: 1)
        let initial = candidates.select(settings: config, freshness: .init(sessionSeed: 1))
        var history = HeroExposureHistory()
        history.record(initial[0])
        let next = candidates.select(
            settings: config, freshness: .init(history: history, sessionSeed: 1)
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertNotEqual(initial[0].id, next[0].id)
        XCTAssertEqual(candidates.buckets[0].items.count, 3)
    }

    func testExhaustedAndSingleCandidatePoolsStillReturnContent() {
        let only = item("only")
        var history = HeroExposureHistory()
        history.record(only)
        XCTAssertEqual(
            pool([only]).select(settings: settings(), freshness: .init(history: history, sessionSeed: 4)),
            [only]
        )
        XCTAssertTrue(HeroFreshnessCandidatePool.empty.select(
            settings: settings(), freshness: .init(history: history, sessionSeed: 4)
        ).isEmpty)
    }

    func testChronologicalSourcesKeepInputOrderAndConfiguredInterleave() {
        let candidates = HeroFreshnessCandidatePool(buckets: [
            .init(source: .continueWatching, items: [item("cw1"), item("cw2")]),
            .init(source: .recentlyAdded, items: [item("r1"), item("r2")]),
            .init(source: .watchlist, items: [item("w1"), item("w2")])
        ])
        var history = HeroExposureHistory()
        [item("cw1"), item("r1"), item("w1")].forEach { history.record($0) }
        let config = settings([.watchlist, .continueWatching, .recentlyAdded])
        XCTAssertEqual(candidates.select(
            settings: config, freshness: .init(history: history, sessionSeed: 91)
        ).map(\.id), ["w1", "cw1", "r1", "w2", "cw2", "r2"])
    }

    func testWatchlistDiscoveryIsOptInAndDisabledSnapshotPreservesLegacyOrder() {
        let items = [item("seen"), item("unseen")]
        var history = HeroExposureHistory()
        history.record(items[0])
        var config = settings([.watchlist])
        let candidates = pool(items, source: .watchlist)
        let freshness = HeroFreshnessSnapshot(history: history, sessionSeed: 1)
        XCTAssertEqual(candidates.select(settings: config, freshness: freshness), items)
        config.watchlistDiscoveryEnabled = true
        XCTAssertEqual(
            candidates.select(settings: config, freshness: freshness).map(\.id),
            ["unseen", "seen"]
        )
        XCTAssertEqual(candidates.select(settings: config), items)
    }

    func testHistoryFollowsProviderAliasesWithoutMixingKinds() {
        var first = item("plex-a", account: "plex")
        first.providerIDs = ["Tmdb": "42"]
        var second = item("jellyfin-b", account: "jellyfin")
        second.providerIDs = ["Tmdb": "42"]
        var history = HeroExposureHistory()
        let date = Date(timeIntervalSince1970: 42)
        history.record(first, at: date)
        XCTAssertEqual(history.lastSeenAt(for: second), date)
        var series = second
        series.kind = .series
        XCTAssertNil(history.lastSeenAt(for: series))
        XCTAssertEqual(pool([second, item("fresh")], source: .randomFromLibrary).select(
            settings: settings([.randomFromLibrary]),
            freshness: .init(history: history, sessionSeed: 1)
        ).first?.id, "fresh")
    }

    func testHydrationBridgesPreviouslySeparateHistoryEntries() {
        var first = item("a")
        first.providerIDs = ["Tmdb": "42"]
        var second = item("b")
        second.providerIDs = ["Imdb": "tt0042"]
        var history = HeroExposureHistory()
        history.record(first, at: Date(timeIntervalSince1970: 1))
        history.record(second, at: Date(timeIntervalSince1970: 2))
        var bridge = item("bridge")
        bridge.providerIDs = ["Tmdb": "42", "Imdb": "tt0042"]
        let newest = Date(timeIntervalSince1970: 3)
        history.record(bridge, at: newest)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.lastSeenAt(for: first), newest)
        XCTAssertEqual(history.lastSeenAt(for: second), newest)
    }

    func testHistoryRecognizesValidatedSourceAliasesWithoutExternalIDs() {
        var merged = item("plex-id", account: "plex")
        merged.sources = [
            MediaSourceRef(accountID: "jellyfin", itemID: "jellyfin-id", kind: .movie)
        ]
        let alternate = item("jellyfin-id", account: "jellyfin")
        var history = HeroExposureHistory()
        history.record(merged)
        XCTAssertNotNil(history.lastSeenAt(for: alternate))
        var unrelated = item("jellyfin-id", account: "other-server")
        unrelated.title = "A Different Film"
        XCTAssertNil(history.lastSeenAt(for: unrelated))
    }

    func testHistoryContainsOnlyBoundedDigestsNotMediaMetadata() throws {
        var history = HeroExposureHistory()
        for index in 0..<(HeroExposureHistory.maximumEntries + 8) {
            history.record(item("secret-title-\(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(history.entries.count, HeroExposureHistory.maximumEntries)
        XCTAssertNil(history.lastSeenAt(for: item("secret-title-0")))
        XCTAssertTrue(history.entries.allSatisfy { $0.aliases.count <= HeroExposureHistory.maximumAliases })
        let data = try JSONEncoder().encode(history)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-title"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("https"))
        XCTAssertEqual(try JSONDecoder().decode(HeroExposureHistory.self, from: data), history)
    }

    func testSelectionHonorsWatchedVisibilityArtworkAndCrossSourceDedupe() {
        var watched = item("watched")
        watched.hasBeenPlayed = true
        var noArtwork = item("no-art")
        noArtwork.backdropURL = nil
        let shared = item("shared")
        let candidates = HeroFreshnessCandidatePool(buckets: [
            .init(source: .featured, items: [watched, noArtwork, shared]),
            .init(source: .randomFromLibrary, items: [item("hidden"), shared, item("other")])
        ])
        let result = candidates.select(
            settings: settings([.featured, .randomFromLibrary]),
            freshness: .init(sessionSeed: 1),
            isEligible: { _, item in item.id != "hidden" }
        )
        XCTAssertEqual(Set(result.map(\.id)), ["shared", "other"])
        XCTAssertEqual(result.count, 2)
    }

    func testDurablePoolExcludesResumeAndContinueWatchingAndPreservesSource() {
        var resume = item("resume")
        resume.resumePosition = 10
        let candidates = HeroFreshnessCandidatePool(buckets: [
            .init(source: .continueWatching, items: [item("cw")]),
            .init(source: .featured, items: [resume, item("safe")])
        ]).durable()
        XCTAssertEqual(candidates.buckets.map(\.source), [.featured])
        XCTAssertEqual(candidates.buckets[0].items.map(\.id), ["safe"])
        var enriched = item("safe")
        enriched.overview = "Hydrated"
        let updated = candidates.updatingItems([enriched])
        XCTAssertEqual(updated.buckets[0].source, .featured)
        XCTAssertEqual(updated.buckets[0].items.first?.overview, "Hydrated")
    }

    func testHydratedReplacementPreservesValidatedArtworkAndSourceOrigin() {
        var original = item("old", account: "a")
        original.providerIDs = ["Tmdb": "42"]
        var replacement = item("new", account: "b")
        replacement.providerIDs = ["Tmdb": "42"]
        replacement.backdropURL = nil
        let updated = pool([original], source: .randomFromLibrary).updatingItems([replacement])
        XCTAssertEqual(updated.buckets.first?.source, .randomFromLibrary)
        XCTAssertEqual(updated.buckets.first?.items.first?.id, "new")
        XCTAssertEqual(updated.buckets.first?.items.first?.backdropURL, original.backdropURL)
    }

    func testCandidatePoolBoundsAlsoApplyWhenDecoding() throws {
        struct Payload: Encodable { let buckets: [HeroFreshnessCandidatePool.Bucket] }
        let data = try JSONEncoder().encode(Payload(buckets: [
            .init(source: .featured, items: (0..<100).map { item("\($0)") }),
            .init(source: .featured, items: [item("duplicate-bucket")])
        ]))
        let decoded = try JSONDecoder().decode(HeroFreshnessCandidatePool.self, from: data)
        XCTAssertEqual(decoded.buckets.count, 1)
        XCTAssertEqual(decoded.buckets[0].items.count, HeroFreshnessCandidatePool.maximumItemsPerSource)
    }

    func testHistoryDecodeRejectsNonIdentityDataAndBoundsEntriesAndAliases() throws {
        struct Payload: Encodable { var entries: [HeroExposureHistory.Entry] }
        let aliases = (0..<80).map { HeroExposureHistory.digest("alias-\($0)") }
        let records = (0..<300).map {
            HeroExposureHistory.Entry(aliases: aliases, lastSeenAt: Date(timeIntervalSince1970: Double($0)))
        }
        let payload = Payload(entries: records + [
            .init(aliases: ["https://example.com/?token=secret"], lastSeenAt: Date())
        ])
        let decoded = try JSONDecoder().decode(
            HeroExposureHistory.self, from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded.entries.count, HeroExposureHistory.maximumEntries)
        XCTAssertTrue(decoded.entries.allSatisfy { $0.aliases.count == HeroExposureHistory.maximumAliases })
    }

    func testSynchronousCurationUsesTheSameDiscoveryRanking() {
        let items = [item("seen"), item("fresh")]
        var history = HeroExposureHistory()
        history.record(items[0])
        XCTAssertEqual(HeroCurator().curateSync(
            settings: settings(limit: 1),
            featured: items,
            continueWatching: [],
            watchlist: [],
            freshness: .init(history: history, sessionSeed: 1)
        ).map(\.id), ["fresh"])
    }

    func testCurationRequestsLargerPoolAndRetainsValidatedSingleSlideAlternatives() async {
        let request = IntRecorder()
        let candidates = (0..<48).map { item("candidate-\($0)") }
        let result = await HeroCurator().curateResult(
            settings: settings(limit: 1), continueWatching: [], watchlist: [],
            freshness: .init(sessionSeed: 1),
            featuredProvider: { limit in
                await request.append(limit)
                return candidates
            }
        )
        let limits = await request.values
        XCTAssertEqual(limits, [48])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.candidatePool.buckets.first?.items.count, 12)
    }

    func testRankingPrecedesBoundedArtworkValidation() async {
        let candidates = (0..<24).map { item("candidate-\($0)") }
        var history = HeroExposureHistory()
        candidates.prefix(12).forEach { history.record($0) }
        let checks = StringRecorder()
        let result = await HeroCurator().curateResult(
            settings: settings(limit: 1), continueWatching: [], watchlist: [],
            freshness: .init(history: history, sessionSeed: 1),
            featuredProvider: { _ in candidates },
            artworkValidator: { urls in
                guard let url = urls.first else { return false }
                await checks.append(url.deletingPathExtension().lastPathComponent)
                return true
            }
        )
        let checked = await checks.values
        XCTAssertEqual(checked.count, 12)
        XCTAssertTrue(Set(checked).isDisjoint(with: candidates.prefix(12).map(\.id)))
        XCTAssertFalse(candidates.prefix(12).map(\.id).contains(result.items[0].id))
    }

    func testRejectedArtworkCannotEnterAlternativeCache() async {
        let candidates = (0..<24).map { item("candidate-\($0)") }
        let allowed = Set(candidates.suffix(8).map(\.id))
        let result = await HeroCurator().curateResult(
            settings: settings(limit: 1), continueWatching: [], watchlist: [],
            freshness: .init(sessionSeed: 4),
            featuredProvider: { _ in candidates },
            artworkValidator: { urls in
                urls.first.map { allowed.contains($0.deletingPathExtension().lastPathComponent) } ?? false
            }
        )
        XCTAssertEqual(result.candidatePool.buckets[0].items.count, 8)
        XCTAssertTrue(result.candidatePool.buckets[0].items.allSatisfy { allowed.contains($0.id) })
    }

    func testFreshnessMergeNeverDisplacesPinnedSlideButAdmitsOtherTitles() {
        var showing = [item("watching"), item("old")]
        var misses: [String: Int] = [:]
        for index in 0..<10 {
            let result = HeroLiveMerge.merge(
                showing: showing, fresh: [item("new-\(index)"), item("other-\(index)")],
                limit: 2, pinnedItemIDs: ["watching"], misses: misses,
                preservesPinnedItems: true
            )
            showing = result.items
            misses = result.misses
            XCTAssertEqual(showing.first?.id, "watching")
            XCTAssertEqual(showing.count, 2)
        }
        XCTAssertNotEqual(showing.last?.id, "old")
        let unpinned = HeroLiveMerge.merge(
            showing: showing, fresh: [item("new")], limit: 2, misses: misses,
            preservesPinnedItems: true
        )
        XCTAssertFalse(unpinned.items.contains { $0.id == "watching" })
    }
}

private actor IntRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private actor StringRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
