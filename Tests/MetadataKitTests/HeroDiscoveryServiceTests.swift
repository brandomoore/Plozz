import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class HeroDiscoveryServiceTests: XCTestCase {
    func testProductionRegistersOnlySupportedDiscoverySources() async {
        let providers = await ProductionHeroDiscovery.providers(
            providerConfig: .init(tmdb: .disabled), tvdbConfig: .init()
        )
        XCTAssertEqual(providers.map(\.source), [.tmdb, .anilist, .tvdb, .tvmaze])
        XCTAssertEqual(Set(providers.map(\.source)), Set(HeroDiscoverySource.allCases))
    }

    private static func item(_ id: String, tmdb: String? = nil) -> MediaItem {
        MediaItem(
            id: id, title: id, kind: .movie, productionYear: 2024,
            providerIDs: ["Tmdb": tmdb ?? String(id.utf8.reduce(1) { $0 + Int($1) })]
        )
    }

    func testActualTMDBAdapterProvidesKindCorrectCompositionLinks() async {
        let http = MetadataDiscoveryHTTPClient { request in
            let tv = request.url?.path.contains("/tv") == true
            let json = tv
                ? #"{"results":[{"id":42,"name":"Show","first_air_date":"2024-01-01"}]}"#
                : #"{"results":[{"id":42,"title":"Movie","release_date":"2024-01-01"}]}"#
            return (
                Data(json.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let provider = TMDbDiscoveryProvider(access: .directToken("fixture"), http: http)
        let service = HeroDiscoveryService()
        let items = await service.discover(
            .init(now: Date(timeIntervalSince1970: 1_735_689_600)), sources: [.tmdb], providers: [provider]
        )
        XCTAssertEqual(items.first { $0.kind == .movie }?.discoveryURLs["tmdb"]?.absoluteString,
                       "https://www.themoviedb.org/movie/42")
        XCTAssertEqual(items.first { $0.kind == .series }?.discoveryURLs["tmdb"]?.absoluteString,
                       "https://www.themoviedb.org/tv/42")
    }

    func testSourcesInterleaveAndMergeAttributionWithoutClaimingOwnership() async {
        var first = Self.item("shared", tmdb: "42")
        first.metadataProvenance[.title] = .init(
            source: .tmdb, sourceURL: URL(string: "https://www.themoviedb.org/movie/42")
        )
        var second = first
        second.metadataProvenance[.title] = .init(
            source: .init(rawValue: "tvdb"), sourceURL: URL(string: "https://thetvdb.com/movies/9/shared")
        )
        let tmdbTitle = first
        let tvdbTitle = second
        let service = HeroDiscoveryService()
        let providers: [any HeroDiscoveryProviding] = [
            DiscoveryFixtureProvider(source: .tmdb) { _ in [tmdbTitle, Self.item("a")] },
            DiscoveryFixtureProvider(source: .tvdb) { _ in [tvdbTitle, Self.item("b")] }
        ]
        let items = await service.discover(.init(limit: 4), sources: [.tmdb, .tvdb], providers: providers)
        XCTAssertEqual(items.map(\.id), ["shared", "a", "b"])
        XCTAssertEqual(Set(items[0].discoverySources), [.tmdb, .tvdb])
        XCTAssertEqual(items[0].discoveryURLs["tvdb"]?.absoluteString, "https://thetvdb.com/movies/9/shared")
        XCTAssertEqual(items[0].discoveryURLs["tmdb"]?.absoluteString, "https://www.themoviedb.org/movie/42")
        XCTAssertTrue(items.allSatisfy { !$0.locallyValidatedPlayableSource })
        XCTAssertTrue(items.allSatisfy { $0.sourceAccountID == nil && $0.sources.isEmpty })
    }

    func testDisabledAndUnselectedSourcesNeverRun() async {
        let calls = DiscoveryCallRecorder()
        let providers: [any HeroDiscoveryProviding] = [
            DiscoveryFixtureProvider(source: .tmdb, isEnabled: false) { _ in
                await calls.record()
                return []
            },
            DiscoveryFixtureProvider(source: .tvdb) { _ in
                await calls.record()
                return []
            }
        ]
        let result = await HeroDiscoveryService().discover(.init(), sources: [.tmdb], providers: providers)
        let count = await calls.count
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(count, 0)
    }

    func testCacheVariesWithCredentialsAndSeedsOnlyForSeededProviders() async {
        let calls = DiscoveryCallRecorder()
        let service = HeroDiscoveryService()
        let fetch: @Sendable (HeroDiscoveryRequest) async throws -> [MediaItem] = { _ in
            await calls.record()
            return [Self.item("1")]
        }
        let tmdb = DiscoveryFixtureProvider(source: .tmdb, cacheIdentifier: "key-a", usesTitleSeeds: true, fetch: fetch)
        let tvdb = DiscoveryFixtureProvider(source: .tvdb, fetch: fetch)
        let first = HeroDiscoveryRequest(seeds: [Self.item("seed-a")])
        let second = HeroDiscoveryRequest(seeds: [Self.item("seed-b")])
        _ = await service.discover(first, sources: [.tmdb, .tvdb], providers: [tmdb, tvdb])
        _ = await service.discover(first, sources: [.tmdb, .tvdb], providers: [tmdb, tvdb])
        let cachedCount = await calls.count
        XCTAssertEqual(cachedCount, 2)
        _ = await service.discover(second, sources: [.tmdb, .tvdb], providers: [tmdb, tvdb])
        let reseededCount = await calls.count
        XCTAssertEqual(reseededCount, 3)
        let newCredential = DiscoveryFixtureProvider(source: .tmdb, cacheIdentifier: "key-b", usesTitleSeeds: true, fetch: fetch)
        _ = await service.discover(second, sources: [.tmdb, .tvdb], providers: [newCredential, tvdb])
        let rotatedCount = await calls.count
        XCTAssertEqual(rotatedCount, 4)
    }

    func testRecencyPolicyReachesProvidersAndSeparatesCachedFeeds() async {
        let calls = DiscoveryCallRecorder()
        let service = HeroDiscoveryService()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { request in
            await calls.record()
            return [Self.item("window-\(request.recency.years)")]
        }
        let now = Date(timeIntervalSince1970: 1_779_494_400)
        for years in [2, 5, 2, 5] {
            let items = await service.discover(
                .init(now: now, recency: .init(years: years)), sources: [.tmdb], providers: [provider]
            )
            XCTAssertEqual(items.first?.id, "window-\(years)")
        }
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testCancelledConsumerDoesNotCancelAnotherConsumerOrSharedLoad() async {
        let started = expectation(description: "One shared request starts")
        let gate = DiscoveryGate()
        let calls = DiscoveryCallRecorder()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { _ in
            await calls.record()
            started.fulfill()
            await gate.wait()
            return [Self.item("1")]
        }
        let service = HeroDiscoveryService(responseBudget: .seconds(5))
        let returned = expectation(description: "Cancelled consumer returns promptly")
        let first = Task {
            let result = await service.discover(.init(), sources: [.tmdb], providers: [provider])
            returned.fulfill()
            return result
        }
        let second = Task { await service.discover(.init(), sources: [.tmdb], providers: [provider]) }
        await fulfillment(of: [started], timeout: 2)
        await waitUntil { await service.subscriberCount == 2 }
        first.cancel()
        await fulfillment(of: [returned], timeout: 1)
        await gate.release()
        let cancelled = await first.value
        let completed = await second.value
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertEqual(completed.map(\.id), ["1"])
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testSlowSourceDoesNotHoldBackCompletedSources() async {
        let gate = DiscoveryGate()
        let started = expectation(description: "Slow source entered")
        let slow = DiscoveryFixtureProvider(source: .tvdb) { _ in
            started.fulfill()
            await gate.wait()
            return [Self.item("slow")]
        }
        let fast = DiscoveryFixtureProvider(source: .tmdb) { _ in [Self.item("fast")] }
        let service = HeroDiscoveryService(responseBudget: .milliseconds(100), loadBudget: .seconds(3))
        let result = await service.discover(.init(limit: 2), sources: [.tmdb, .tvdb], providers: [fast, slow])
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(result.map(\.id), ["fast"])
        await gate.release()
        await waitUntil { await service.activeLoadCount == 0 }
        let next = await service.discover(.init(limit: 2), sources: [.tmdb, .tvdb], providers: [fast, slow])
        XCTAssertEqual(next.map(\.id), ["fast", "slow"])
    }

    func testExpiredGenerationCannotOverwriteFreshReplacement() async {
        let gate = DiscoveryGate()
        let calls = DiscoveryCallRecorder()
        let clock = DiscoveryTestClock()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { _ in
            let index = await calls.record()
            if index == 1 { await gate.wait() }
            return [Self.item(index == 1 ? "old" : "fresh")]
        }
        let service = HeroDiscoveryService(
            responseBudget: .seconds(1), loadBudget: .milliseconds(60),
            now: { clock.value }
        )
        let expired = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertTrue(expired.isEmpty)
        clock.advance(61)
        let replacement = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(replacement.map(\.id), ["fresh"])
        await gate.release()
        await waitUntil { await service.activeLoadCount == 0 }
        let retained = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(retained.map(\.id), ["fresh"])
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testRetiredWorkKeepsItsAdmissionUntilActualReturn() async {
        let gate = DiscoveryGate()
        let calls = DiscoveryCallRecorder()
        let clock = DiscoveryTestClock()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { _ in
            await calls.record()
            await gate.wait()
            return [Self.item("1")]
        }
        let service = HeroDiscoveryService(
            responseBudget: .seconds(1), loadBudget: .milliseconds(60),
            maximumInFlight: 1, now: { clock.value }
        )
        _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        clock.advance(61)
        let rejected = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        let count = await calls.count
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(count, 1)
        await gate.release()
        await waitUntil { await service.activeLoadCount == 0 }
        let next = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(next.map(\.id), ["1"])
    }

    func testTransientFailureRetainsGoodCacheAndBacksOff() async {
        let clock = DiscoveryTestClock()
        let calls = DiscoveryCallRecorder()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { _ in
            let index = await calls.record()
            if index == 2 { throw MetadataDiscoveryHTTPError.status(429, retryAfter: 100) }
            return [Self.item(index == 1 ? "old" : "new")]
        }
        let service = HeroDiscoveryService(cacheLifetime: 1, now: { clock.value })
        _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        clock.advance(2)
        let stale = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(stale.map(\.id), ["old"])
        _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        let throttled = await calls.count
        XCTAssertEqual(throttled, 2)
        clock.advance(101)
        let recovered = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(recovered.map(\.id), ["new"])
    }

    func testCancellationDoesNotPoisonNextRequest() async {
        let calls = DiscoveryCallRecorder()
        let provider = DiscoveryFixtureProvider(source: .tmdb) { _ in
            let index = await calls.record()
            if index == 1 { throw CancellationError() }
            return [Self.item("1")]
        }
        let service = HeroDiscoveryService()
        _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        let next = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        XCTAssertEqual(next.map(\.id), ["1"])
    }

    func testRepeatedDeadlinesBoundAndEvictBackoffEntriesWithoutSuccessfulLoads() async {
        let clock = DiscoveryTestClock()
        let service = HeroDiscoveryService(
            responseBudget: .seconds(1), loadBudget: .milliseconds(5),
            maximumInFlight: 1, now: { clock.value }
        )
        for index in 0..<70 {
            let provider = DiscoveryFixtureProvider(source: .tmdb, cacheIdentifier: "timeout-\(index)") { _ in
                try await Task.sleep(for: .seconds(1))
                return []
            }
            _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
            await waitUntil { await service.activeLoadCount == 0 }
            let count = await service.backoffEntryCount
            XCTAssertLessThanOrEqual(count, 64)
        }
        clock.advance(61)
        let provider = DiscoveryFixtureProvider(source: .tmdb, cacheIdentifier: "final-timeout") { _ in
            try await Task.sleep(for: .seconds(1))
            return []
        }
        _ = await service.discover(.init(), sources: [.tmdb], providers: [provider])
        await waitUntil { await service.activeLoadCount == 0 }
        let count = await service.backoffEntryCount
        XCTAssertEqual(count, 1)
    }

    private func waitUntil(_ predicate: () async -> Bool) async {
        let end = ContinuousClock.now + .seconds(2)
        while !(await predicate()), ContinuousClock.now < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }
}

private struct DiscoveryFixtureProvider: HeroDiscoveryProviding {
    let source: HeroDiscoverySource
    var isEnabled = true
    var cacheIdentifier = "fixture"
    var usesTitleSeeds = false
    let fetch: @Sendable (HeroDiscoveryRequest) async throws -> [MediaItem]

    func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        try await fetch(request)
    }
}

private actor DiscoveryCallRecorder {
    private(set) var count = 0
    @discardableResult func record() -> Int {
        count += 1
        return count
    }
}

private actor DiscoveryGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class DiscoveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
