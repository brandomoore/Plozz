import Foundation

/// Volatile, opt-in operation timings. No logging, tasks, timers or event emission.
/// Durations measure elapsed uptime, not main-thread CPU time or presented-frame hitches.
public final class PerformanceDiagnostics: @unchecked Sendable {
    public static let shared = PerformanceDiagnostics()
    @TaskLocal public static var provider: ProviderKind?

    public enum Operation: String, Codable, Sendable {
        case homeLoad, homeFetch, homeMerge, homePublish, serverRequest, serverDecode
        case shareScan, playlistFetch, playlistParse, playlistImport, playlistCommit, guideFetch
        case liveTVRefresh, automaticChannels, search
    }

    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public var items: Int?
        public var bytes: Int?
        public var rows: Int?
        public var credits: Int?
        public var accounts: Int?
        public var requests: Int?

        public init(
            items: Int? = nil, bytes: Int? = nil, rows: Int? = nil, credits: Int? = nil,
            accounts: Int? = nil, requests: Int? = nil
        ) {
            self.items = items
            self.bytes = bytes
            self.rows = rows
            self.credits = credits
            self.accounts = accounts
            self.requests = requests
        }

        fileprivate func merging(_ newer: Metrics) -> Metrics {
            func value(_ newer: Int?, _ older: Int?) -> Int? {
                if let newer, (0...PerformanceDiagnostics.maximumCount).contains(newer) { return newer }
                if let older, (0...PerformanceDiagnostics.maximumCount).contains(older) { return older }
                return nil
            }
            return Metrics(
                items: value(newer.items, items), bytes: value(newer.bytes, bytes),
                rows: value(newer.rows, rows), credits: value(newer.credits, credits),
                accounts: value(newer.accounts, accounts), requests: value(newer.requests, requests)
            )
        }
    }

    public static let maximumActive = 32
    public static let maximumRecent = 16
    public static let maximumSlow = 16
    public static let slowMilliseconds = 250
    public static let maximumCount = 1_000_000_000_000
    /// All elapsed/relative times saturate after 30 days; no wall-clock timestamp is collected.
    public static let maximumMilliseconds = 2_592_000_000

    public struct Record: Encodable, Sendable {
        public let operation: Operation
        public let provider: ProviderKind?
        public let startedMilliseconds: Int
        public let elapsedMilliseconds: Int
        public let startedOnMain: Bool
        /// Admitted spans, including this one; dropped spans are not counted as tracked overlap.
        public let activeAtStart: Int
        /// Nil means still active at snapshot time, not an inferred success.
        public let outcome: Outcome?
        public let metrics: Metrics
        public let httpStatus: Int?
        public let networkCode: Int?
    }

    public struct Snapshot: Encodable, Sendable {
        public let schema: Int
        public let elapsedMilliseconds: Int
        public let maxActive: Int
        /// Admission failures plus overwritten completed records, saturating at maximumCount.
        public let dropped: Int
        public let active: [Record]
        public let recent: [Record]
        /// Reserved for slow completions so a fast flood cannot displace all slow evidence.
        public let slow: [Record]
        fileprivate let generation: UUID

        private enum CodingKeys: String, CodingKey {
            case schema, elapsedMilliseconds, maxActive, dropped, active, recent, slow
        }
    }

    public final class Span: Sendable {
        private let owner: PerformanceDiagnostics
        private let generation: UUID
        private let id: UInt64

        fileprivate init(owner: PerformanceDiagnostics, generation: UUID, id: UInt64) {
            self.owner = owner
            self.generation = generation
            self.id = id
        }

        /// The first finish wins, even across concurrent callers. Missing metrics preserve start values.
        public func finish(
            _ outcome: Outcome, metrics: Metrics = .init(), httpStatus: Int? = nil, networkCode: Int? = nil
        ) {
            owner.finish(
                id: id, generation: generation, outcome: outcome, metrics: metrics,
                httpStatus: httpStatus, networkCode: networkCode
            )
        }
    }

    private struct Entry {
        let operation: Operation
        let provider: ProviderKind?
        let started: UInt64
        let startedOnMain: Bool
        let activeAtStart: Int
        var ended: UInt64?
        var outcome: Outcome?
        var metrics: Metrics
        var httpStatus: Int?
        var networkCode: Int?

        func record(epoch: UInt64, now: UInt64) -> Record {
            Record(
                operation: operation, provider: provider,
                startedMilliseconds: PerformanceDiagnostics.milliseconds(from: epoch, to: started),
                elapsedMilliseconds: PerformanceDiagnostics.milliseconds(from: started, to: ended ?? now),
                startedOnMain: startedOnMain, activeAtStart: activeAtStart,
                outcome: outcome, metrics: metrics, httpStatus: httpStatus, networkCode: networkCode
            )
        }
    }

    private struct Ring {
        var entries: [Entry?]
        var next = 0

        init(capacity: Int) { entries = Array(repeating: nil, count: capacity) }

        mutating func append(_ entry: Entry) -> Bool {
            let replaced = entries[next] != nil
            entries[next] = entry
            next = (next + 1) % entries.count
            return replaced
        }
    }

    private let lock = NSLock()
    private let uptime: @Sendable () -> UInt64
    private let wallClock: @Sendable () -> Date
    private var generation: UUID?
    private var epoch: UInt64 = 0
    private var startedAt = Date.distantFuture
    private var nextID: UInt64 = 0
    private var active: [UInt64: Entry] = [:]
    private var recent = Ring(capacity: PerformanceDiagnostics.maximumRecent)
    private var slow = Ring(capacity: PerformanceDiagnostics.maximumSlow)
    private var maxActive = 0
    private var dropped = 0

    public convenience init() { self.init(uptime: { DispatchTime.now().uptimeNanoseconds }) }

    /// Clock injection is internal and only used for deterministic tests; it must not reenter the recorder.
    init(
        uptime: @escaping @Sendable () -> UInt64,
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uptime = uptime
        self.wallClock = wallClock
    }

    public func start() {
        lock.withLock {
            guard generation == nil else { return }
            generation = UUID()
            epoch = uptime()
            startedAt = wallClock()
        }
    }

    public func stop() {
        lock.withLock {
            generation = nil
            epoch = 0
            startedAt = .distantFuture
            nextID = 0
            active.removeAll(keepingCapacity: false)
            recent = Ring(capacity: Self.maximumRecent)
            slow = Ring(capacity: Self.maximumSlow)
            maxActive = 0
            dropped = 0
        }
    }

    public func begin(
        _ operation: Operation, provider: ProviderKind? = nil, metrics: Metrics = .init()
    ) -> Span? {
        let admission: (UUID, UInt64)? = lock.withLock {
            // Disabled calls do not read the clock/thread/task local, allocate a span, or collect metrics.
            guard let generation else { return nil }
            guard active.count < Self.maximumActive else {
                dropped = min(Self.maximumCount, dropped + 1)
                return nil
            }
            nextID &+= 1
            let count = active.count + 1
            active[nextID] = Entry(
                operation: operation, provider: provider ?? Self.provider, started: uptime(),
                startedOnMain: Thread.isMainThread, activeAtStart: count, metrics: Metrics().merging(metrics)
            )
            maxActive = max(maxActive, count)
            return (generation, nextID)
        }
        guard let (generation, id) = admission else { return nil }
        return Span(owner: self, generation: generation, id: id)
    }

    private func finish(
        id: UInt64, generation: UUID, outcome: Outcome, metrics: Metrics,
        httpStatus: Int?, networkCode: Int?
    ) {
        lock.withLock {
            guard self.generation == generation, var entry = active.removeValue(forKey: id) else { return }
            let now = uptime()
            entry.ended = now
            entry.outcome = outcome
            entry.metrics = entry.metrics.merging(metrics)
            entry.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
            entry.networkCode = networkCode.flatMap { (-4_000 ... -1).contains($0) ? $0 : nil }
            let replaced = Self.milliseconds(from: entry.started, to: now) >= Self.slowMilliseconds
                ? slow.append(entry) : recent.append(entry)
            if replaced { dropped = min(Self.maximumCount, dropped + 1) }
        }
    }

    /// Event timestamps must belong to the current consent session. Wall-clock
    /// boundaries are local attribution checks only and are never serialized.
    /// Takes a bounded value copy under the lock; encoding happens outside it.
    public func snapshot(forEventAt eventDate: Date? = nil) -> Snapshot? {
        let captured = lock.withLock { () -> (UUID, UInt64, UInt64, Int, Int, [UInt64: Entry], Ring, Ring)? in
            guard let generation else { return nil }
            if let eventDate {
                guard eventDate.timeIntervalSinceReferenceDate.isFinite,
                      eventDate >= startedAt, eventDate <= wallClock() else { return nil }
            }
            return (generation, epoch, uptime(), maxActive, dropped, active, recent, slow)
        }
        guard let (generation, epoch, now, maxActive, dropped, active, recent, slow) = captured else { return nil }
        func records(_ entries: [Entry]) -> [Record] {
            entries.sorted { $0.started < $1.started }.map { $0.record(epoch: epoch, now: now) }
        }
        return Snapshot(
            schema: 1, elapsedMilliseconds: Self.milliseconds(from: epoch, to: now),
            maxActive: maxActive, dropped: dropped,
            active: records(Array(active.values)),
            recent: records(recent.entries.compactMap { $0 }),
            slow: records(slow.entries.compactMap { $0 }), generation: generation
        )
    }

    /// Event adapters recheck after serialization so an intervening opt-out/restart discards the old copy.
    public func isCurrent(_ snapshot: Snapshot) -> Bool {
        lock.withLock { generation == snapshot.generation }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        Int(min(UInt64(maximumMilliseconds), (end >= start ? end - start : 0) / 1_000_000))
    }
}
