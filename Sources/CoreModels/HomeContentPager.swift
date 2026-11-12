import Foundation

/// One cursor per source keeps round-robin ordering stable across unequal server
/// page sizes. A page never scans an entire library to fill a sparse preview.
public actor HomeContentPager {
    public typealias Loader = @Sendable (HomeContentSource, Int, Int) async throws -> HomeRowPage

    public struct Snapshot: Sendable {
        public let items: [MediaItem]
        public let hasMore: Bool
        public let failures: [HomeContentSource.ID: AppError]
        public let groups: [HomeContentSource: [MediaItem]]
        public let continuingSources: Set<HomeContentSource.ID>
    }

    private struct Cursor: Sendable {
        var offset: Int? = 0
        var buffer: [MediaItem] = []
        var position = 0
        var seen = Set<String>()
        var emitted: [MediaItem] = []
    }

    public nonisolated let sources: [HomeContentSource]
    private let loader: Loader
    private let serverInfo: [String: SourceServerInfo]
    private let identitySources: @Sendable (MediaItem) -> [MediaSourceRef]
    private var cursors: [Cursor]
    private var items: [MediaItem] = []
    private var turn = 0
    private let gate = ConcurrencyLimiter(limit: 1)

    public init(
        sources: [HomeContentSource], serverInfo: [String: SourceServerInfo] = [:],
        identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef] = { _ in [] },
        loader: @escaping Loader
    ) {
        self.sources = HomeContentSource.normalized(sources)
        self.cursors = self.sources.map { _ in Cursor() }
        self.serverInfo = serverInfo
        self.identitySources = identitySources
        self.loader = loader
    }

    public nonisolated func loadNext(limit: Int) async throws -> Snapshot {
        try await gate.runUnlessCancelled { try await self.advance(limit: limit) }
    }

    public nonisolated static func interleave<T>(_ groups: [[T]]) -> [T] {
        var result: [T] = []
        result.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for offset in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where offset < group.count { result.append(group[offset]) }
        }
        return result
    }

    /// Alternate ordering and filters require complete membership. Never return
    /// a sorted prefix or silently accept a failed source as a complete result.
    public nonisolated func load(
        limit: Int, query: HomeContentQuery, watchlistDates: Bool = false
    ) async throws -> Snapshot {
        guard limit > 0, limit <= PageRequest.defaultLimit else { throw AppError.invalidResponse }
        if query.isDefault { return try await loadNext(limit: limit) }
        let result = try await loadAll()
        try Task.checkCancellation()
        return Snapshot(
            items: try query.applying(
                to: result.items, watchlistDates: watchlistDates, checkCancellation: Task.checkCancellation
            ),
            hasMore: false, failures: result.failures,
            groups: result.groups, continuingSources: result.continuingSources
        )
    }

    public nonisolated func loadAll() async throws -> Snapshot {
        try await gate.runUnlessCancelled { try await self.complete() }
    }

    private func complete() async throws -> Snapshot {
        if cursors.allSatisfy({ $0.offset == nil && $0.position == $0.buffer.count }) {
            try Task.checkCancellation()
            return Snapshot(
                items: items, hasMore: false, failures: [:],
                groups: Dictionary(uniqueKeysWithValues: sources.indices.map { (sources[$0], cursors[$0].emitted) }),
                continuingSources: []
            )
        }
        let sources = sources
        let loader = loader
        let current = cursors
        let completed = try await withThrowingTaskGroup(of: (Int, Cursor).self) { group in
            let fetch: @Sendable (Int) async throws -> (Int, Cursor) = { index in
                var cursor = current[index]
                cursor.emitted += cursor.buffer.dropFirst(cursor.position)
                cursor.buffer = []
                cursor.position = 0
                while let start = cursor.offset {
                    try Task.checkCancellation()
                    let page = try await loader(sources[index], start, PageRequest.defaultLimit)
                    guard page.nextOffset.map({ $0 > start }) ?? true,
                          page.items.count <= PageRequest.defaultLimit else { throw AppError.invalidResponse }
                    let fresh = page.items.filter { cursor.seen.insert($0.stablePresentationID).inserted }
                    guard page.items.isEmpty || !fresh.isEmpty || page.nextOffset == nil else {
                        throw AppError.invalidResponse
                    }
                    cursor.emitted += fresh
                    cursor.offset = page.nextOffset
                }
                try Task.checkCancellation()
                return (index, cursor)
            }
            var queued = 0
            for index in sources.indices.prefix(3) {
                group.addTask { try await fetch(index) }
                queued += 1
            }
            var next = current
            while let (index, cursor) = try await group.next() {
                next[index] = cursor
                if queued < sources.count {
                    let index = queued
                    group.addTask { try await fetch(index) }
                    queued += 1
                }
            }
            return next
        }
        try Task.checkCancellation()
        let interleaved = Self.interleave(completed.map(\.emitted))
        let merged = sources.count == 1 ? interleaved
            : MediaItemMerger.merge(interleaved, serverInfo: { serverInfo[$0] }, identitySources: identitySources)
        try Task.checkCancellation()
        cursors = completed
        items = merged
        return Snapshot(
            items: merged, hasMore: false, failures: [:],
            groups: Dictionary(uniqueKeysWithValues: sources.indices.map { (sources[$0], completed[$0].emitted) }),
            continuingSources: []
        )
    }

    private func advance(limit: Int) async throws -> Snapshot {
        guard limit > 0, limit <= PageRequest.defaultLimit else { throw AppError.invalidResponse }
        try Task.checkCancellation()
        var next = cursors
        var nextTurn = turn
        var consumedTotal = 0
        var failures: [HomeContentSource.ID: AppError] = [:]
        var scanned = 0
        var merged = items
        let target = items.count + limit
        let scanBudget = limit * max(4, sources.count) + (sources.count > 1 ? 20 * sources.count : 0)
        while merged.count < target, !sources.isEmpty {
            try Task.checkCancellation()
            let remaining = target - merged.count
            let uniqueAdded = max(1, merged.count - items.count)
            let overlap = max(1, (consumedTotal + uniqueAdded - 1) / uniqueAdded)
            let initialBatch = (limit + sources.count - 1) / sources.count
            let batchSize = sources.count == 1 ? min(20, remaining)
                : min(20, max(initialBatch, (remaining * overlap + sources.count - 1) / sources.count))
            let needed = next.indices.filter {
                next[$0].position == next[$0].buffer.count
                    && next[$0].offset != nil && failures[sources[$0].id] == nil
            }
            if !needed.isEmpty, scanned < scanBudget {
                let requests = needed.map { ($0, next[$0].offset ?? 0) }
                let sources = sources
                let loader = loader
                let fetch: @Sendable ((Int, Int)) async -> (Int, Result<HomeRowPage, AppError>) = { request in
                    do {
                        return (request.0, .success(try await loader(sources[request.0], request.1, batchSize)))
                    } catch {
                        return (request.0, .failure(
                            error is CancellationError ? .cancelled : (error as? AppError) ?? .invalidResponse
                        ))
                    }
                }
                let results = await withTaskGroup(of: (Int, Result<HomeRowPage, AppError>).self) { group in
                    var queued = 0
                    for request in requests.prefix(3) {
                        group.addTask { await fetch(request) }
                        queued += 1
                    }
                    var results: [(Int, Result<HomeRowPage, AppError>)] = []
                    while let result = await group.next() {
                        results.append(result)
                        if Task.isCancelled { group.cancelAll() }
                        else if queued < requests.count {
                            let request = requests[queued]
                            queued += 1
                            group.addTask { await fetch(request) }
                        }
                    }
                    return results
                }
                try Task.checkCancellation()
                for (index, result) in results {
                    switch result {
                    case let .success(page):
                        guard let start = next[index].offset,
                              page.nextOffset.map({ $0 > start }) ?? true,
                              page.items.count <= batchSize else { throw AppError.invalidResponse }
                        var seen = next[index].seen
                        let fresh = page.items.filter { seen.insert($0.stablePresentationID).inserted }
                        next[index].seen = seen
                        next[index].offset = page.nextOffset
                        next[index].buffer = fresh
                        next[index].position = 0
                        scanned += max(1, page.items.count)
                    case let .failure(error):
                        if error == .cancelled { throw CancellationError() }
                        failures[sources[index].id] = error
                    }
                }
            }
            var visited = 0
            var consumed = 0
            var emitted: [MediaItem] = []
            var reachedScanBoundary = false
            while consumed < remaining, visited < sources.count {
                let index = nextTurn
                nextTurn = (nextTurn + 1) % sources.count
                visited += 1
                if next[index].position < next[index].buffer.count {
                    let item = next[index].buffer[next[index].position]
                    emitted.append(item)
                    consumed += 1
                    visited = 0
                    next[index].emitted.append(item)
                    next[index].position += 1
                } else if next[index].offset != nil && failures[sources[index].id] == nil {
                    // This source's next item belongs before the following source.
                    nextTurn = index
                    reachedScanBoundary = scanned >= scanBudget
                    break
                }
            }
            if consumed > 0 {
                consumedTotal += consumed
                merged = sources.count == 1 ? merged + emitted
                    : MediaItemMerger.merge(merged + emitted, serverInfo: { serverInfo[$0] }, identitySources: identitySources)
            }
            if reachedScanBoundary { break }
            let canContinue = next.indices.contains {
                next[$0].position < next[$0].buffer.count
                    || (scanned < scanBudget && next[$0].offset != nil && failures[sources[$0].id] == nil)
            }
            if !canContinue { break }
        }
        try Task.checkCancellation()
        cursors = next
        turn = nextTurn
        items = merged
        return Snapshot(
            items: merged,
            hasMore: next.contains { $0.position < $0.buffer.count || $0.offset != nil },
            failures: failures,
            groups: Dictionary(uniqueKeysWithValues: sources.indices.map { (sources[$0], next[$0].emitted) }),
            continuingSources: Set(sources.indices.filter {
                next[$0].position < next[$0].buffer.count || next[$0].offset != nil
            }.map { sources[$0].id })
        )
    }
}
