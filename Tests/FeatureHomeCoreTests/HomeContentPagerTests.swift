import CoreModels
import XCTest
@testable import FeatureHomeCore
@testable import TestSupportPerformance

final class HomeContentPagerTests: XCTestCase {
    func testInventoryBatchesRetainPreviewPrefixAndFollowServerPageCaps() async throws {
        let fixture = ContentFixture(counts: [735], pageSizes: [75], reportsTotals: true, delay: .milliseconds(1))
        let pager = fixture.pager()
        let preview = try await pager.loadNext(limit: 20)
        let result = try await pager.loadAll()
        XCTAssertEqual(result.items.map(\.id), (0..<735).map { "0-\($0)" })
        XCTAssertEqual(Array(result.items.prefix(20)), preview.items)
        let requests = await fixture.requests
        XCTAssertEqual(requests.first?.limit, 20)
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.limit == 200 })
        XCTAssertEqual(requests.dropFirst().map(\.start).sorted(), Array(stride(from: 20, to: 735, by: 75)))
        let metrics = await fixture.metrics()
        XCTAssertEqual(metrics.maximumConcurrent, 3)
        XCTAssertEqual(metrics.items, 735)
    }

    func testInventoryPrefetchKeepsOneGlobalThreeRequestCeiling() async throws {
        let fixture = ContentFixture(counts: Array(repeating: 830, count: 8), overlapping: true,
                                     reportsTotals: true, delay: .milliseconds(1))
        let result = try await fixture.pager().loadAll()
        XCTAssertEqual(result.items.count, 830)
        XCTAssertTrue(result.items.allSatisfy { $0.sources.count == 8 })
        let metrics = await fixture.metrics()
        XCTAssertEqual(metrics.maximumConcurrent, 3)
        XCTAssertEqual(metrics.items, 6_640)
    }

    func testHomeFeedsKeepSequentialSixtyItemRequestsEvenWithATotalHint() async throws {
        let fixture = ContentFixture(counts: [230], reportsTotals: true, delay: .milliseconds(1))
        let pager = HomeContentPager(sources: [.init(home: .watchlist)]) { _, start, limit in
            try await fixture.page(fixture.sources[0], start: start, limit: limit)
        }
        let result = try await pager.loadAll()
        XCTAssertEqual(result.items.count, 230)
        let requests = await fixture.requests
        XCTAssertEqual(requests.map(\.start), [0, 60, 120, 180])
        XCTAssertTrue(requests.allSatisfy { $0.limit == 60 })
        let metrics = await fixture.metrics()
        XCTAssertEqual(metrics.maximumConcurrent, 1)
    }

    func testInventoryUsesActualOffsetsWhenAResponseChangesPageSize() async throws {
        let fixture = ContentFixture(counts: [1_200], reportsTotals: true)
        let pager = HomeContentPager(sources: fixture.sources) {
            try await fixture.page($0, start: $1, limit: $1 == 200 ? 50 : $2)
        }
        let result = try await pager.loadAll()
        XCTAssertEqual(result.items.map(\.id), (0..<1_200).map { "0-\($0)" })
        let requests = await fixture.requests
        XCTAssertTrue(requests.contains { $0.start == 250 }, "A short page must not skip to a prefetched offset")
        XCTAssertTrue(requests.contains { $0.start == 400 }, "Exercise the discarded speculative page")
    }

    func testInventoryCompletionDoesNotTrustMissingLowOrHighTotals() async throws {
        for hint in [nil, 1, 201, 10_000] as [Int?] {
            let fixture = ContentFixture(counts: [450], reportsTotals: hint != nil, totalHint: hint)
            let result = try await fixture.pager().loadAll()
            XCTAssertEqual(result.items.map(\.id), (0..<450).map { "0-\($0)" })
            XCTAssertFalse(result.hasMore)
            let requests = await fixture.requests
            XCTAssertTrue(requests.contains { $0.start == 400 })
            XCTAssertLessThanOrEqual(requests.count, 4)
        }
    }

    func testInventoryPrefetchCancellationDrainsRequestsAndRetriesUncommittedPages() async throws {
        let fixture = ContentFixture(counts: [1_200], reportsTotals: true, delay: .milliseconds(20))
        let pager = fixture.pager()
        let task = Task { try await pager.loadAll() }
        await fixture.waitForRequest(count: 4)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled inventory cannot publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = await fixture.metrics()
        XCTAssertEqual(cancelled.active, 0)
        let result = try await pager.loadAll()
        XCTAssertEqual(result.items.count, 1_200)
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.start == 0 }.count, 2)
    }

    func testInventoryPrefetchFailureCannotPublishAndRemainsRetryable() async throws {
        let fixture = ContentFixture(counts: [850], reportsTotals: true, failureStarts: [200])
        let pager = fixture.pager()
        do { _ = try await pager.loadAll(); XCTFail("A failed prefetched page cannot be omitted") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        await fixture.recover()
        let result = try await pager.loadAll()
        XCTAssertEqual(result.items.map(\.id), (0..<850).map { "0-\($0)" })
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.start == 0 }.count, 2)
    }

    func testCompleteInventoryRejectsOversizedAndNonadvancingPages() async throws {
        for oversized in [false, true] {
            let pager = HomeContentPager(sources: ContentFixture(counts: [1]).sources) { _, start, limit in
                .init(items: oversized ? (0...limit).map { .init(id: "\($0)", title: "Title", kind: .movie) } : [],
                      nextOffset: oversized ? nil : start)
            }
            do { _ = try await pager.loadAll(); XCTFail("Invalid inventory page must fail") }
            catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        }
    }

    func testSavedSortReadsWholeSourcesAndReusesInventoryForFurtherQueries() async throws {
        let fixture = ContentFixture(counts: [241, 130], pageSizes: [13, 7])
        let pager = fixture.pager()
        let original = try await pager.loadNext(limit: 20)
        XCTAssertEqual(original.items.first?.id, "0-0")
        let query = HomeContentQuery(sort: .init(field: .name, direction: .descending))
        let sorted = try await pager.load(limit: 20, query: query)
        XCTAssertFalse(sorted.hasMore)
        XCTAssertEqual(sorted.items.count, 371)
        XCTAssertEqual(sorted.items.first?.id, "1-129")
        let before = await fixture.metrics()
        let ascending = try await pager.load(limit: 20, query: .init(sort: .default))
        let after = await fixture.metrics()
        XCTAssertEqual(before.requests, after.requests)
        XCTAssertEqual(ascending.items.first?.id, "0-0")
        let restored = try await pager.load(limit: 20, query: .init())
        XCTAssertEqual(Array(restored.items.prefix(20)), original.items)
        XCTAssertLessThanOrEqual(after.maximumConcurrent, 3)
    }

    func testSavedFilterFindsLateMatchesAndIncludesEpisodesWithoutReordering() async throws {
        let sources = ContentFixture(counts: [260]).sources
        let pager = HomeContentPager(sources: sources) { _, start, limit in
            let end = min(start + limit, 260)
            let items = (start..<end).map {
                MediaItem(id: "\($0)", title: "Title \($0)", kind: $0 < 240 ? .movie : .episode)
            }
            return .init(items: items, nextOffset: end < 260 ? end : nil)
        }
        let result = try await pager.load(limit: 20, query: .init(media: .shows))
        XCTAssertEqual(result.items.map(\.id), (240..<260).map(String.init))
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.groups.values.first?.count, 260)
    }

    func testSavedQueryDoesNotPublishPartialInventoryAndCancellationIsRetryable() async throws {
        let fixture = ContentFixture(counts: [250, 250], failing: [1], delay: .milliseconds(5))
        let pager = fixture.pager()
        let query = HomeContentQuery(sort: .default)
        do { _ = try await pager.load(limit: 20, query: query); XCTFail("Partial inventory cannot be globally sorted") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        await fixture.recover()
        let cancelled = Task { try await pager.load(limit: 20, query: query) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation cannot publish") }
        catch { XCTAssertTrue(error is CancellationError || error as? AppError == .cancelled) }
        let result = try await pager.load(limit: 20, query: query)
        XCTAssertEqual(result.items.count, 500)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCompleteInventoryRetainsAllDuplicatePlaybackSources() async throws {
        let fixture = ContentFixture(counts: Array(repeating: 230, count: 8), overlapping: true)
        let result = try await fixture.pager().load(limit: 20, query: .init(sort: .default))
        XCTAssertEqual(result.items.count, 230)
        XCTAssertTrue(result.items.allSatisfy { $0.sources.count == 8 })
        let metrics = await fixture.metrics()
        XCTAssertLessThanOrEqual(metrics.maximumConcurrent, 3)
        XCTAssertEqual(metrics.items, 1_840)
    }

    func testUnequalAndEmptySourceMatrixMatchesRoundRobinReference() async throws {
        for counts in [[0, 0, 0], [0, 1, 7], [7, 0, 1], [1, 7, 0], [21, 3, 11], [3, 21, 11]] {
            let expected = (0..<(counts.max() ?? 0)).flatMap { item in
                counts.indices.compactMap { source in item < counts[source] ? "\(source)-\(item)" : nil }
            }
            for pageLimit in [1, 2, 5, 20] {
                let fixture = ContentFixture(counts: counts, pageSizes: [1, 3, 7])
                let pager = fixture.pager()
                var previous: [String] = []
                var finished = false
                for _ in 0..<100 {
                    let result = try await pager.loadNext(limit: pageLimit)
                    let ids = result.items.map(\.id)
                    XCTAssertEqual(Array(ids.prefix(previous.count)), previous)
                    XCTAssertEqual(ids, Array(expected.prefix(ids.count)))
                    XCTAssertTrue(result.failures.isEmpty)
                    XCTAssertLessThanOrEqual(ids.count - previous.count, pageLimit)
                    previous = ids
                    if !result.hasMore { finished = true; break }
                }
                XCTAssertTrue(finished)
                XCTAssertEqual(previous, expected)
            }
        }
    }

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
    func testPerformanceRapidSavedRowQueries() async throws {
        try await PerformanceProbe.measure(self, scenario: "home-rapid-row-queries") {
            let items = (0..<20_000).map { index in
                MediaItem(
                    id: "\(index)", title: "Title \(20_000 - index)",
                    kind: index.isMultiple(of: 2) ? .movie : .series,
                    productionYear: 1980 + index % 40, runtime: Double(index % 100 + 1) * 60,
                    resumePosition: index.isMultiple(of: 5) ? 20 : nil,
                    isPlayed: index.isMultiple(of: 3)
                )
            }
            let model = HomeRowBrowseModel(title: "Rapid queries", snapshot: items)
            var ticks = 0
            var maximumGap = 0
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { break }
                    let now = ContinuousClock.now
                    maximumGap = max(maximumGap, previous.duration(to: now).nanosecondsForQueryTest)
                    previous = now
                    ticks += 1
                }
            }
            defer { heartbeat.cancel() }
            for field in HomeContentQuery.sortFields {
                model.query = .init(sort: .init(field: field, direction: .descending))
                let abandoned = Task { await model.load() }
                try await Task.sleep(for: .milliseconds(5))
                abandoned.cancel()
                model.query = .init(
                    sort: .init(field: field, direction: .ascending), media: .movies,
                    filters: .init(filter: .unwatched)
                )
                await model.load()
                await abandoned.value
                XCTAssertNil(model.error)
                XCTAssertEqual(model.appliedQuery, model.query)
                XCTAssertEqual(model.items.count, items.filter { $0.kind == .movie && !$0.isPlayed }.count)
                XCTAssertTrue(model.items.allSatisfy { $0.kind == .movie && !$0.isPlayed })
            }
            await model.applyMutation(.init(itemIDs: ["2"], played: true))
            XCTAssertFalse(model.items.contains { $0.id == "2" })
            model.query = .init(media: .shows, filters: .init(filter: .inProgress))
            await model.load()
            XCTAssertTrue(model.items.allSatisfy { $0.kind == .series && !$0.isPlayed && ($0.resumePosition ?? 0) > 0 })
            XCTAssertEqual(model.items.count, items.filter {
                $0.kind == .series && !$0.isPlayed && ($0.resumePosition ?? 0) > 0
            }.count)
            XCTAssertGreaterThan(ticks, 5, "Queries must leave the main actor available.")
            XCTAssertLessThan(maximumGap, 100_000_000, "Simulator main-actor scheduling gap, not physical frame timing.")
            return ["items": items.count, "heartbeatTicks": ticks, "maximumMainActorGapNanoseconds": maximumGap]
        }
    }

    @MainActor
    func testPerformanceSavedRowQueries() async throws {
        try await PerformanceProbe.measure(self, scenario: "home-saved-row-queries") {
            let fixture = ContentFixture(counts: [10_000, 10_000])
            let pager = fixture.pager()
            let query = HomeContentQuery(sort: .init(field: .name, direction: .descending))
            let start = ContinuousClock.now
            let snapshot = try await pager.load(limit: 20, query: query)
            let cold = start.duration(to: .now).nanosecondsForQueryTest
            XCTAssertEqual(snapshot.items.count, 20_000)
            XCTAssertEqual(snapshot.items.first?.id, "1-9999")
            let initial = await fixture.metrics()
            let browser = HomeRowBrowseModel(title: "Query", contentPager: pager, query: query)
            await browser.load()
            XCTAssertEqual(browser.items, snapshot.items)
            let warmStart = ContinuousClock.now
            for field in HomeContentQuery.sortFields {
                browser.query = .init(sort: .init(field: field, direction: .ascending), media: .movies)
                await browser.load()
                XCTAssertNil(browser.error)
                XCTAssertEqual(browser.items.count, 20_000)
            }
            let warm = warmStart.duration(to: .now).nanosecondsForQueryTest
            let mutationStart = ContinuousClock.now
            await browser.applyMutation(.init(itemIDs: ["0-0"], played: true))
            XCTAssertEqual(browser.items.first { $0.id == "0-0" }?.isPlayed, true)
            let mutation = mutationStart.duration(to: .now).nanosecondsForQueryTest
            let final = await fixture.metrics()
            XCTAssertEqual(initial.requests, final.requests)
            XCTAssertEqual(final.items, 20_000)
            XCTAssertLessThanOrEqual(final.maximumConcurrent, 3)
            return ["items": snapshot.items.count, "requests": final.requests,
                    "fetched": final.items, "coldNanoseconds": cold,
                    "warmFourQueriesNanoseconds": warm, "mutationNanoseconds": mutation]
        }
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

private extension Duration {
    var nanosecondsForQueryTest: Int {
        let value = components
        return Int(value.seconds) * 1_000_000_000 + Int(value.attoseconds / 1_000_000_000)
    }
}

private actor PageCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor ContentFixture {
    struct Request { let source: Int; let start: Int; let limit: Int }
    struct Metrics { let requests: Int; let items: Int; let active: Int; let maximumConcurrent: Int }
    nonisolated let sources: [HomeContentSource]
    let counts: [Int]
    let pageSizes: [Int]
    let overlapping: Bool
    let reportsTotals: Bool
    let totalHint: Int?
    let delay: Duration
    var failing: Set<Int>
    var failureStarts: Set<Int>
    var requests: [Request] = []
    var active = 0
    var maximumConcurrent = 0
    var fetched = 0
    var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(counts: [Int], pageSizes: [Int] = [], overlapping: Bool = false,
         failing: Set<Int> = [], reportsTotals: Bool = false, totalHint: Int? = nil,
         failureStarts: Set<Int> = [], delay: Duration = .zero) {
        self.counts = counts
        self.pageSizes = pageSizes
        self.overlapping = overlapping
        self.failing = failing
        self.reportsTotals = reportsTotals
        self.totalHint = totalHint
        self.failureStarts = failureStarts
        self.delay = delay
        sources = counts.indices.map {
            .init(feed: .collection("collection-\($0)"), accountID: "\($0)", serverUserID: "viewer", title: "Source \($0)")
        }
    }

    nonisolated func pager() -> HomeContentPager {
        HomeContentPager(sources: sources) { try await self.page($0, start: $1, limit: $2) }
    }

    func recover() { failing = []; failureStarts = [] }
    func metrics() -> Metrics {
        .init(requests: requests.count, items: fetched, active: active, maximumConcurrent: maximumConcurrent)
    }
    func waitForRequest(count: Int = 1) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func page(_ source: HomeContentSource, start: Int, limit: Int) async throws -> HomeRowPage {
        let index = try XCTUnwrap(sources.firstIndex(where: { $0.id == source.id }))
        requests.append(.init(source: index, start: start, limit: limit))
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        requestWaiters.removeAll {
            guard requests.count >= $0.0 else { return false }
            $0.1.resume()
            return true
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if failing.contains(index) || failureStarts.contains(start) { throw AppError.serverUnreachable }
        let end = max(start, min(counts[index], start + min(limit, pageSizes.indices.contains(index) ? pageSizes[index] : limit)))
        let items = (start..<end).map { number in
            MediaItem(
                id: "\(index)-\(number)", title: overlapping ? "Title \(number)" : "Title \(index)-\(number)", kind: .movie,
                providerIDs: overlapping ? ["Tmdb": "\(number + 1)"] : [:], sourceAccountID: source.accountID
            )
        }
        fetched += items.count
        return .init(items: items, nextOffset: end < counts[index] ? end : nil,
                     totalCountHint: reportsTotals ? (totalHint ?? counts[index]) : nil)
    }
}
