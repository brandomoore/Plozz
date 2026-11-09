import CoreModels
import Foundation
import MetadataKit
import XCTest
@testable import FeatureHomeCore

@MainActor
final class RelatedTitlesLoaderTests: XCTestCase {
    private let seed = MediaItem(id: "seed", title: "Seed", kind: .movie, providerIDs: ["Tmdb": "999"])

    private func title(_ index: Int) -> RelatedTitle {
        RelatedTitle(title: "Candidate \(index)", kind: .movie,
                     providerIDs: ["Tmdb": "\(index + 1)"], source: .tmdb)
    }

    private func native(_ index: Int) -> MediaItem {
        var item = MediaItem(
            id: "native-\(index)", title: "Curated \(index)", kind: .movie,
            posterURL: URL(string: "https://artwork.test/\(index).jpg"),
            providerIDs: ["Tmdb": "\(index + 1)"], sourceAccountID: "account"
        )
        item.isPlayed = true
        item.resumePosition = 37
        return item
    }

    private func loader(
        titles: [RelatedTitle],
        sources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        fetch: (@Sendable (MediaSourceRef) async -> MediaItem?)? = nil,
        batches: [String: @Sendable ([String]) async -> [MediaItem]] = [:],
        search: @escaping @Sendable (String, Int) async -> [MediaItem] = { _, _ in [] }
    ) -> RelatedTitlesLoader {
        RelatedTitlesLoader(
            resolver: .init(providers: [Titles(titles: titles)]),
            store: RelatedTitlesStore(directory: nil), search: search,
            indexedLibrarySources: sources, loadIndexedItem: fetch, loadIndexedBatches: batches
        )
    }

    func testIndexedRowsPreserveNativeMetadataAndStopAtTwelve() async {
        let titles = (0..<30).map(title)
        let copies = (0..<30).map(native)
        let calls = Calls()
        let loader = loader(
            titles: titles,
            sources: { item in
                guard let id = item.providerIDs["Tmdb"], let number = Int(id) else { return [] }
                return [.init(accountID: "account", itemID: "native-\(number - 1)", kind: .movie)]
            },
            fetch: { source in await calls.fetch(source, from: copies) },
            search: { query, _ in await calls.search(query); return [] }
        )
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item), Array(copies.prefix(12)))
        XCTAssertTrue(loader.hasResolved)
        XCTAssertFalse(loader.isLoading)
        let fetched = await calls.fetched
        let searches = await calls.searched
        let peak = await calls.peak
        XCTAssertEqual(Set(fetched), Set(copies.prefix(12).map(\.id)))
        XCTAssertEqual(fetched.count, 12)
        XCTAssertTrue(searches.isEmpty)
        XCTAssertLessThanOrEqual(peak, RelatedTitlesLoader.concurrentLookups)
        await loader.load(for: seed)
        let revisited = await calls.fetched
        XCTAssertEqual(revisited.count, 12, "A completed loader must not repeat native lookups.")
    }

    func testColdIndexUsesSearchAndStopsAfterEarliestTwelveMatches() async {
        let copies = (0..<24).map(native)
        let calls = Calls()
        let loader = loader(
            titles: (0..<24).map(title),
            fetch: { _ in XCTFail("No source in the cold index"); return nil },
            search: { query, _ in
                await calls.search(query)
                guard let n = Int(query.split(separator: " ").last ?? "") else { return [] }
                return [copies[n]]
            }
        )
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item.id), copies.prefix(12).map(\.id))
        let searches = await calls.searched
        XCTAssertGreaterThanOrEqual(searches.count, 12)
        XCTAssertLessThanOrEqual(searches.count, 12 + RelatedTitlesLoader.concurrentLookups - 1)
    }

    func testMissesAndDuplicateCopiesReleaseSlotsWithoutChangingOrder() async {
        var titles = (0..<24).map(title)
        titles[1] = RelatedTitle(title: "Alias", kind: .movie, providerIDs: ["Imdb": "tt1"], source: .trakt)
        var duplicate = native(0)
        duplicate.providerIDs["Imdb"] = "tt1"
        let first = duplicate
        let copies = (0..<24).map(native)
        let calls = Calls()
        let loader = loader(titles: titles, search: { query, _ in
            await calls.search(query)
            if query == "Alias" { return [first] }
            guard let n = Int(query.split(separator: " ").last ?? ""), n != 2 else { return [] }
            return [n == 0 ? first : copies[n]]
        })
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item.id), [first.id] + copies[3..<14].map(\.id))
        let searches = await calls.searched
        XCTAssertGreaterThanOrEqual(searches.count, 14)
        XCTAssertLessThanOrEqual(searches.count, 14 + RelatedTitlesLoader.concurrentLookups - 1)
    }

    func testSlowColdIndexSearchDoesNotHoldBackAFullRow() async throws {
        let started = expectation(description: "Slow first search started")
        let release = Gate()
        let copies = (0..<24).map(native)
        let loader = loader(titles: (0..<24).map(title), search: { query, _ in
            guard let n = Int(query.split(separator: " ").last ?? "") else { return [] }
            if n == 0 {
                started.fulfill()
                await release.wait()
            }
            return [copies[n]]
        })
        let task = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 1)
        let deadline = ContinuousClock.now + .seconds(1)
        while loader.entries.count < 12, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let earlyIDs = loader.entries.map(\.item.id)
        await release.open()
        await task.value
        XCTAssertEqual(earlyIDs, copies[1...12].map(\.id))
        XCTAssertEqual(loader.entries.map(\.item.id), copies.prefix(12).map(\.id))
    }

    func testMissingCopiesExhaustOnlyTheTwentyFourCandidateBudget() async {
        let calls = Calls()
        let loader = loader(titles: (0..<40).map(title), search: { query, _ in
            await calls.search(query)
            return []
        })
        await loader.load(for: seed)
        XCTAssertTrue(loader.entries.isEmpty)
        XCTAssertTrue(loader.hasResolved)
        let searches = await calls.searched
        XCTAssertEqual(searches.count, 24)
    }

    func testStaleIndexedCopiesFallBackWithoutPublishingUnverifiedMetadata() async {
        let recommendation = RelatedTitle(
            title: "Candidate 0", kind: .movie,
            providerIDs: ["Tmdb": "1", "Imdb": "tt1"], source: .tmdb
        )
        let correct = native(0)
        var wrongID = correct
        wrongID.id = "reused-id"
        var wrongAccount = correct
        wrongAccount.sourceAccountID = "another-profile-account"
        var wrongKind = correct
        wrongKind.kind = .series
        var wrongIdentity = correct
        wrongIdentity.providerIDs = ["Tmdb": "9999"]
        var conflictingIdentity = correct
        conflictingIdentity.providerIDs["Imdb"] = "tt2"
        var unplayable = correct
        unplayable.locallyValidatedPlayableSource = false
        let stale: [MediaItem?] = [nil, wrongID, wrongAccount, wrongKind, wrongIdentity, conflictingIdentity, unplayable]
        for copy in stale {
            let calls = Calls()
            let loader = loader(
                titles: [recommendation],
                sources: { _ in [.init(accountID: "account", itemID: correct.id, kind: .movie)] },
                fetch: { _ in copy },
                search: { query, _ in await calls.search(query); return [correct] }
            )
            await loader.load(for: seed)
            XCTAssertEqual(loader.entries.map(\.item), [correct])
            let searches = await calls.searched
            XCTAssertEqual(searches.count, 1)
        }
    }

    func testWrongKindIndexAndTitleOnlyRecommendationsDoNotFetchNativeItems() async {
        for related in [title(0), RelatedTitle(title: "No identity", kind: .movie, source: .tmdb)] {
            let loader = loader(
                titles: [related],
                sources: { _ in [.init(accountID: "account", itemID: "wrong", kind: .series)] },
                fetch: { _ in XCTFail("Cannot use wrong-kind or weak index evidence"); return nil }
            )
            await loader.load(for: seed)
            XCTAssertTrue(loader.entries.isEmpty)
        }
    }

    func testExternalModeRemainsNetworkFreeAfterRecommendations() async {
        let loader = loader(
            titles: [title(0)],
            sources: { _ in [.init(accountID: "account", itemID: "owned", kind: .movie)] },
            fetch: { _ in XCTFail("External mode must not fetch native metadata"); return nil },
            search: { _, _ in XCTFail("External mode must not search"); return [] }
        )
        await loader.load(for: seed, displayMode: .includeExternal)
        XCTAssertEqual(loader.entries.first?.item.id, "owned")
        XCTAssertTrue(loader.entries.first?.isInLibrary == true)
    }

    func testCancellationStopsFallbackAndAllowsRetry() async {
        let started = expectation(description: "Native request started")
        let cancelled = expectation(description: "Native request cancelled")
        let calls = Calls()
        let copy = native(0)
        let loader = loader(
            titles: [title(0)],
            sources: { _ in [.init(accountID: "account", itemID: copy.id, kind: .movie)] },
            fetch: { _ in
                if await calls.beginAttempt() == 1 {
                    started.fulfill()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancelled.fulfill(); return nil }
                }
                return copy
            },
            search: { _, _ in XCTFail("Cancelled indexed request must not start a search"); return [] }
        )
        let task = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        loader.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await task.value
        XCTAssertFalse(loader.hasResolved)
        XCTAssertFalse(loader.isLoading)
        XCTAssertTrue(loader.entries.isEmpty)
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item), [copy])
        XCTAssertTrue(loader.hasResolved)
    }

    func testCancelledRecommendationsDoNotPoisonSharedCache() async {
        let started = expectation(description: "Recommendations started")
        let calls = Calls()
        let title = title(0)
        let provider = CallbackTitles {
            if await calls.beginAttempt() == 1 {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return [] }
            }
            return [title]
        }
        let store = RelatedTitlesStore(directory: nil)
        let copy = native(0)
        let loader = RelatedTitlesLoader(
            resolver: .init(providers: [provider]), store: store, search: { _, _ in [copy] }
        )
        let task = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await task.value
        let cached = await store.record(for: MetadataQuery(seed).seriesScoped.enrichmentCacheKey)
        XCTAssertNil(cached)
        XCTAssertFalse(loader.hasResolved)
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item), [copy])
    }

    func testLateCancelledAttemptCannotReplaceResumedSameSeed() async {
        let started = expectation(description: "Old request started")
        let gate = Gate()
        let calls = Calls()
        let old = native(0)
        var freshCopy = old
        freshCopy.title = "Fresh native metadata"
        let fresh = freshCopy
        let loader = loader(
            titles: [title(0)],
            sources: { _ in [.init(accountID: "account", itemID: old.id, kind: .movie)] },
            fetch: { _ in
                if await calls.beginAttempt() == 1 {
                    started.fulfill()
                    await gate.wait()
                    return old
                }
                return fresh
            }
        )
        let first = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 1)
        first.cancel()
        loader.cancel()
        await loader.load(for: seed)
        await gate.open()
        await first.value
        XCTAssertEqual(loader.entries.map(\.item), [fresh])
        XCTAssertTrue(loader.hasResolved)
        XCTAssertFalse(loader.isLoading)
    }

    func testBatchesAreAccountScopedOrderedBoundedAndStopAtTwelve() async {
        for accountCount in [2, 16] {
            let copies = (0..<24).map { index -> MediaItem in
                var item = native(index)
                item.id = "native-\(index / accountCount)"
                item.sourceAccountID = "account-\(index % accountCount)"
                return item
            }
            let calls = Calls()
            var batches: [String: @Sendable ([String]) async -> [MediaItem]] = [:]
            for account in 0..<accountCount {
                let id = "account-\(account)"
                batches[id] = { ids in await calls.batch(id, ids: ids, items: copies) }
            }
            let loader = loader(
                titles: (0..<24).map(title),
                sources: { item in
                    guard let copy = copies.first(where: { $0.providerIDs == item.providerIDs }) else { return [] }
                    return [.init(accountID: copy.sourceAccountID!, itemID: copy.id, kind: .movie)]
                },
                fetch: { _ in XCTFail("Healthy batches must not fetch individually"); return nil },
                batches: batches,
                search: { _, _ in XCTFail("Healthy index must not search"); return [] }
            )
            await loader.load(for: seed)
            XCTAssertEqual(loader.entries.map(\.item), Array(copies.prefix(12)))
            let recorded = await calls.batches
            let peak = await calls.peak
            XCTAssertEqual(recorded.count, min(accountCount, 12))
            XCTAssertEqual(recorded.values.flatMap { $0 }.flatMap { $0 }.count, 12)
            XCTAssertLessThanOrEqual(peak, RelatedTitlesLoader.concurrentLookups)
        }
    }

    func testPartialAndUnverifiedBatchResultsRetryOnlyAffectedItems() async {
        let copies = (0..<3).map(native)
        var foreign = copies[1]
        foreign.sourceAccountID = "wrong-account"
        let returned = [copies[0], foreign]
        let calls = Calls()
        let loader = loader(
            titles: (0..<3).map(title),
            sources: { item in
                let n = Int(item.providerIDs["Tmdb"]!)! - 1
                return [.init(accountID: "account", itemID: copies[n].id, kind: .movie)]
            },
            fetch: { source in await calls.fetch(source, from: copies) },
            batches: ["account": { _ in returned }],
            search: { _, _ in XCTFail("Individual recovery succeeded"); return [] }
        )
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item), copies)
        let fetched = await calls.fetched
        XCTAssertEqual(Set(fetched), Set(copies.dropFirst().map(\.id)))
    }

    func testSlowServerCannotHideReadyCardsFromAnotherAccount() async throws {
        let started = expectation(description: "Slow batch started")
        let gate = Gate()
        let copies = (0..<12).map { index -> MediaItem in
            var item = native(index)
            item.sourceAccountID = index < 6 ? "slow" : "fast"
            return item
        }
        let loader = loader(
            titles: (0..<12).map(title),
            sources: { item in
                let copy = copies[Int(item.providerIDs["Tmdb"]!)! - 1]
                return [.init(accountID: copy.sourceAccountID!, itemID: copy.id, kind: .movie)]
            },
            batches: [
                "slow": { _ in started.fulfill(); await gate.wait(); return Array(copies.prefix(6)) },
                "fast": { _ in Array(copies.suffix(6)) }
            ]
        )
        let task = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 2)
        let deadline = ContinuousClock.now + .seconds(2)
        while loader.entries.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let early = loader.entries.map(\.item)
        let stillLoading = loader.isLoading
        await gate.open()
        await task.value
        XCTAssertEqual(early, Array(copies.suffix(6)))
        XCTAssertTrue(stillLoading)
        XCTAssertEqual(loader.entries.map(\.item), copies)
    }

    func testBatchCancellationDoesNotBeginIndividualOrSearchFallback() async {
        let started = expectation(description: "Batch started")
        let cancelled = expectation(description: "Batch cancelled")
        let loader = loader(
            titles: [title(0)],
            sources: { _ in [.init(accountID: "account", itemID: "native-0", kind: .movie)] },
            fetch: { _ in XCTFail("Cancelled batch must not retry"); return nil },
            batches: ["account": { _ in
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { cancelled.fulfill() }
                return []
            }],
            search: { _, _ in XCTFail("Cancelled batch must not search"); return [] }
        )
        let task = Task { await loader.load(for: seed) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        loader.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await task.value
        XCTAssertFalse(loader.hasResolved)
        XCTAssertTrue(loader.entries.isEmpty)
    }

    func testPreparationSharesPublicWorkButDoesNotFetchOrPublishLibraryData() async throws {
        let started = expectation(description: "Public lookup started")
        let gate = Gate()
        let calls = Calls()
        let recommendation = title(0)
        let copy = native(0)
        let loader = RelatedTitlesLoader(
            resolver: .init(providers: [CallbackTitles {
                _ = await calls.beginAttempt()
                started.fulfill()
                await gate.wait()
                return [recommendation]
            }]),
            store: RelatedTitlesStore(directory: nil),
            search: { query, _ in await calls.search(query); return [copy] }
        )
        loader.prepareRecommendations(for: seed)
        await fulfillment(of: [started], timeout: 2)
        loader.prepareRecommendations(for: seed)
        XCTAssertTrue(loader.entries.isEmpty)
        XCTAssertFalse(loader.isLoading)
        let searchesBeforeLoad = await calls.searched
        XCTAssertTrue(searchesBeforeLoad.isEmpty)
        let load = Task { await loader.load(for: seed) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !loader.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await gate.open()
        await load.value
        let attempts = await calls.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(loader.entries.map(\.item), [copy])
    }

    func testCancellationBeforeRowLoadCancelsPreparationAndAllowsRetry() async {
        let started = expectation(description: "Preparation started")
        let cancelled = expectation(description: "Preparation cancelled")
        let calls = Calls()
        let recommendation = title(0)
        let copy = native(0)
        let store = RelatedTitlesStore(directory: nil)
        let loader = RelatedTitlesLoader(
            resolver: .init(providers: [CallbackTitles {
                if await calls.beginAttempt() == 1 {
                    started.fulfill()
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancelled.fulfill(); return [] }
                }
                return [recommendation]
            }]),
            store: store, search: { _, _ in [copy] }
        )
        loader.prepareRecommendations(for: seed)
        await fulfillment(of: [started], timeout: 2)
        loader.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let cached = await store.record(for: MetadataQuery(seed).seriesScoped.enrichmentCacheKey)
        XCTAssertNil(cached)
        await loader.load(for: seed)
        XCTAssertEqual(loader.entries.map(\.item), [copy])
    }

    func testChangedFreshIdentityDoesNotConsumeOldPreparation() async {
        let started = expectation(description: "Old preparation started")
        let gate = Gate()
        let calls = Calls()
        let oldTitle = title(1)
        let freshTitle = title(0)
        let copy = native(0)
        let store = RelatedTitlesStore(directory: nil)
        let loader = RelatedTitlesLoader(
            resolver: .init(providers: [CallbackTitles {
                if await calls.beginAttempt() == 1 {
                    started.fulfill()
                    await gate.wait()
                    return [oldTitle]
                }
                return [freshTitle]
            }]),
            store: store, search: { _, _ in [copy] }
        )
        loader.prepareRecommendations(for: seed)
        await fulfillment(of: [started], timeout: 2)
        var freshSeed = seed
        freshSeed.providerIDs["Tmdb"] = "777"
        await loader.load(for: freshSeed)
        await gate.open()
        XCTAssertEqual(loader.entries.map(\.item), [copy])
        let attempts = await calls.attempts
        XCTAssertEqual(attempts, 2)
        let cached = await store.record(for: MetadataQuery(seed).seriesScoped.enrichmentCacheKey)
        XCTAssertNil(cached)
    }

    private struct Titles: RelatedTitlesProviding {
        let id: MetadataSource = .tmdb
        let isEnabled = true
        let titles: [RelatedTitle]
        func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] { titles }
    }

    private struct CallbackTitles: RelatedTitlesProviding {
        let id: MetadataSource = .tmdb
        let isEnabled = true
        let operation: @Sendable () async -> [RelatedTitle]
        func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] { await operation() }
    }

    private actor Calls {
        var fetched: [String] = []
        var searched: [String] = []
        var batches: [String: [[String]]] = [:]
        var active = 0
        var peak = 0
        var attempts = 0
        func search(_ query: String) { searched.append(query) }
        func beginAttempt() -> Int { attempts += 1; return attempts }
        func batch(_ account: String, ids: [String], items: [MediaItem]) async -> [MediaItem] {
            batches[account, default: []].append(ids)
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return [] }
            return items.reversed().filter { $0.sourceAccountID == account && ids.contains($0.id) }
        }
        func fetch(_ source: MediaSourceRef, from items: [MediaItem]) async -> MediaItem? {
            fetched.append(source.itemID)
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            let index = items.firstIndex { $0.id == source.itemID } ?? 0
            do { try await Task.sleep(for: .milliseconds(6 - index % 6)) }
            catch { return nil }
            return items.first { $0.id == source.itemID }
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
