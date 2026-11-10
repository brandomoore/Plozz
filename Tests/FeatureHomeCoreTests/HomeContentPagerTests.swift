import CoreModels
import XCTest
@testable import FeatureHomeCore
@testable import TestSupportPerformance

final class HomeContentPagerTests: XCTestCase {
    func testUnequalPagesKeepRoundRobinOrderAcrossBrowsePages() async throws {
        let fixture = ContentFixture(counts: [20, 4], pageSizes: [1, 3])
        let pager = fixture.pager()
        let first = try await pager.loadNext(limit: 5)
        XCTAssertEqual(first.items.map(\.id), ["0-0", "1-0", "0-1", "1-1", "0-2"])
        var result = try await pager.loadNext(limit: 5)
        XCTAssertEqual(result.items.map(\.id), ["0-0", "1-0", "0-1", "1-1", "0-2", "1-2", "0-3", "1-3", "0-4", "0-5"])
        for _ in 0..<10 where result.hasMore { result = try await pager.loadNext(limit: 5) }
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.items.count, 24)
        XCTAssertEqual(Set(result.items.map(\.stablePresentationID)).count, 24)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testEightOverlappingSourcesFillUniqueBudgetAndRetainPlaybackReferences() async throws {
        let fixture = ContentFixture(counts: Array(repeating: 40, count: 8), overlapping: true)
        let pager = fixture.pager()
        let first = try await pager.loadNext(limit: 20)
        XCTAssertEqual(first.items.count, 20)
        XCTAssertEqual(first.items.map(\.title), (0..<20).map { "Title \($0)" })
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.items[0].sources.count, 8)
        var final = first
        for _ in 0..<5 where final.hasMore { final = try await pager.loadNext(limit: 20) }
        XCTAssertFalse(final.hasMore)
        XCTAssertEqual(final.items.count, 40)
        XCTAssertTrue(final.items.allSatisfy { $0.sources.count == 8 })
        let metrics = await fixture.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumConcurrent, 3)
        XCTAssertEqual(metrics.items, 320)
    }

    func testFailureKeepsOtherSourcesAndRetryDoesNotRepeatCommittedPages() async throws {
        let fixture = ContentFixture(counts: [4, 4], failing: [0])
        let pager = fixture.pager()
        let partial = try await pager.loadNext(limit: 6)
        XCTAssertEqual(partial.items.map(\.id), ["1-0", "1-1", "1-2", "1-3"])
        XCTAssertEqual(partial.failures[fixture.sources[0].id], .serverUnreachable)
        XCTAssertTrue(partial.hasMore)
        await fixture.recover()
        let retry = try await pager.loadNext(limit: 6)
        XCTAssertTrue(retry.failures.isEmpty)
        XCTAssertFalse(retry.hasMore)
        XCTAssertEqual(retry.items.count, 8)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.source == 1 && $0.start == 0 }.count, 1)
    }

    func testCancellationLeavesCursorUncommittedAndDrainsOwnedRequests() async throws {
        let fixture = ContentFixture(counts: Array(repeating: 100, count: 8), delay: .milliseconds(50))
        let pager = fixture.pager()
        let task = Task { try await pager.loadNext(limit: 20) }
        await fixture.waitForRequest()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let metrics = await fixture.metrics()
        XCTAssertEqual(metrics.active, 0)
        let retry = try await pager.loadNext(limit: 20)
        XCTAssertEqual(retry.items.first?.id, "0-0")
        XCTAssertEqual(retry.items.count, 20)
    }

    func testSparseSourcesAreBoundedAndRemainPageable() async throws {
        let counter = PageCounter()
        let pager = HomeContentPager(sources: ContentFixture(counts: [100]).sources) { _, start, _ in
            await counter.increment()
            return .init(items: [], nextOffset: start + 1)
        }
        let result = try await pager.loadNext(limit: 20)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.hasMore)
        XCTAssertTrue(result.failures.isEmpty)
        let count = await counter.count
        XCTAssertEqual(count, 80)
    }

    func testConcurrentBrowseRequestsSerializeWithoutRepeatingPages() async throws {
        let fixture = ContentFixture(counts: [100, 100], delay: .milliseconds(5))
        let pager = fixture.pager()
        async let first = pager.loadNext(limit: 20)
        async let second = pager.loadNext(limit: 20)
        let snapshots = try await [first, second]
        XCTAssertEqual(snapshots.map { $0.items.count }.sorted(), [20, 40])
        XCTAssertTrue(snapshots.allSatisfy { $0.failures.isEmpty })
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.start == 0 }.count, 2)
    }

    func testScanBoundaryCommitsConsumedItemsBeforePausing() async throws {
        let sources = ContentFixture(counts: [30, 30]).sources
        for tailStart in 1..<30 {
            let pager = HomeContentPager(sources: sources) { source, start, _ in
                let items: [MediaItem] = source.id == sources[0].id
                    ? [.init(id: start < tailStart ? "first" : "tail-\(start)",
                             title: "Title \(start < tailStart ? 0 : start)", kind: .movie)]
                    : []
                return .init(items: items, nextOffset: start < 29 ? start + 1 : nil)
            }
            var result = try await pager.loadNext(limit: 3)
            for _ in 0..<20 {
                XCTAssertEqual(Set(result.items.map(\.id)), Set(result.groups.values.flatMap { $0.map(\.id) }))
                if !result.hasMore { break }
                result = try await pager.loadNext(limit: 3)
            }
            XCTAssertFalse(result.hasMore)
            XCTAssertEqual(result.items.map(\.id), ["first"] + (tailStart..<30).map { "tail-\($0)" })
        }
    }

    func testNonadvancingPagesFailWithoutCommittingItems() async throws {
        let fixture = ContentFixture(counts: [10])
        let pager = HomeContentPager(sources: fixture.sources) { _, start, _ in
            .init(items: [], nextOffset: start)
        }
        do { _ = try await pager.loadNext(limit: 5); XCTFail("Nonadvancing pagination must fail") }
        catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    @MainActor
    func testPerformanceMultipleSources() async throws {
        try await PerformanceProbe.measure(self, scenario: "home-multi-source-row") {
            var requests = 0
            var fetched = 0
            var maximum = 0
            var delivered = 0
            for count in [2, 8, 32] {
                let fixture = ContentFixture(counts: Array(repeating: 100_000, count: count), delay: .milliseconds(1))
                let result = try await fixture.pager().loadNext(limit: 21)
                XCTAssertEqual(result.items.count, 21)
                XCTAssertTrue(result.hasMore)
                XCTAssertTrue(result.failures.isEmpty)
                let metrics = await fixture.metrics()
                XCTAssertLessThanOrEqual(metrics.maximumConcurrent, 3)
                XCTAssertLessThanOrEqual(metrics.items, max(42, count))
                requests += metrics.requests
                fetched += metrics.items
                maximum = max(maximum, metrics.maximumConcurrent)
                delivered += result.items.count
            }
            return ["items": delivered, "requests": requests, "fetched": fetched, "maximumConcurrent": maximum]
        }
    }

    @MainActor
    func testPerformanceOverlappingSourcesBrowse() async throws {
        try await PerformanceProbe.measure(self, scenario: "home-overlapping-source-browse") {
            let fixture = ContentFixture(counts: Array(repeating: 200, count: 8), overlapping: true)
            let pager = fixture.pager()
            var result = try await pager.loadNext(limit: 50)
            for _ in 0..<10 where result.hasMore { result = try await pager.loadNext(limit: 50) }
            XCTAssertFalse(result.hasMore)
            XCTAssertEqual(result.items.count, 200)
            XCTAssertTrue(result.items.allSatisfy { $0.sources.count == 8 })
            let metrics = await fixture.metrics()
            XCTAssertEqual(metrics.items, 1_600)
            return ["items": result.items.count, "requests": metrics.requests, "fetched": metrics.items,
                    "maximumConcurrent": metrics.maximumConcurrent]
        }
    }
}

private actor PageCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor ContentFixture {
    struct Request { let source: Int; let start: Int }
    struct Metrics { let requests: Int; let items: Int; let active: Int; let maximumConcurrent: Int }
    nonisolated let sources: [HomeContentSource]
    let counts: [Int]
    let pageSizes: [Int]
    let overlapping: Bool
    let delay: Duration
    var failing: Set<Int>
    var requests: [Request] = []
    var active = 0
    var maximumConcurrent = 0
    var fetched = 0
    var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(counts: [Int], pageSizes: [Int] = [], overlapping: Bool = false,
         failing: Set<Int> = [], delay: Duration = .zero) {
        self.counts = counts
        self.pageSizes = pageSizes
        self.overlapping = overlapping
        self.failing = failing
        self.delay = delay
        sources = counts.indices.map {
            .init(feed: .collection("collection-\($0)"), accountID: "\($0)", serverUserID: "viewer", title: "Source \($0)")
        }
    }

    nonisolated func pager() -> HomeContentPager {
        HomeContentPager(sources: sources) { try await self.page($0, start: $1, limit: $2) }
    }

    func recover() { failing = [] }
    func metrics() -> Metrics {
        .init(requests: requests.count, items: fetched, active: active, maximumConcurrent: maximumConcurrent)
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func page(_ source: HomeContentSource, start: Int, limit: Int) async throws -> HomeRowPage {
        let index = try XCTUnwrap(sources.firstIndex(where: { $0.id == source.id }))
        requests.append(.init(source: index, start: start))
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        requestWaiters.forEach { $0.resume() }
        requestWaiters = []
        if delay > .zero { try await Task.sleep(for: delay) }
        if failing.contains(index) { throw AppError.serverUnreachable }
        let end = min(counts[index], start + min(limit, pageSizes.indices.contains(index) ? pageSizes[index] : limit))
        let items = (start..<end).map { number in
            MediaItem(
                id: "\(index)-\(number)", title: overlapping ? "Title \(number)" : "Title \(index)-\(number)", kind: .movie,
                providerIDs: overlapping ? ["Tmdb": "\(number + 1)"] : [:], sourceAccountID: source.accountID
            )
        }
        fetched += items.count
        return .init(items: items, nextOffset: end < counts[index] ? end : nil)
    }
}
