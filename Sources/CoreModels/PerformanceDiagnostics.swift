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

        public var isHomePresentation: Bool {
            switch self {
            case .homeLoad, .homeMerge, .homePublish: true
            default: false
            }
        }
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
    public static let reservedHomeActive = 4
    public static let maximumHomeUI = 60
    public static let homeDelayThresholdMilliseconds = 50
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
        public let homeRecent: [Record]
        public let homeSlow: [Record]
        public let homeDropped: Int
        public let homeUI: [HomeUIRecord]
        public let homeUIDropped: Int
        fileprivate let generation: UUID

        private enum CodingKeys: String, CodingKey {
            case schema, elapsedMilliseconds, maxActive, dropped, active, recent, slow
            case homeRecent, homeSlow, homeDropped, homeUI, homeUIDropped
        }
    }

    /// Sampled main-actor wake-up delay, not frame timing or CPU attribution.
    public struct HomeUIMetrics: Codable, Equatable, Sendable {
        public var samples = 0
        public var delayedSamples = 0
        public var maximumDelayMilliseconds = 0
        public var scrollingSamples = 0
        public var loadingSamples = 0
        public var heightChanges = 0
        public var maximumHeightDeltaPoints = 0
        public var maximumActiveScans = 0
        public var maximumActiveListers = 0

        public init() {}

        fileprivate var isValid: Bool {
            (1...PerformanceDiagnostics.maximumCount).contains(samples)
                && [delayedSamples, scrollingSamples, loadingSamples].allSatisfy { (0...samples).contains($0) }
                && (0...PerformanceDiagnostics.maximumMilliseconds).contains(maximumDelayMilliseconds)
                && [heightChanges, maximumHeightDeltaPoints, maximumActiveScans, maximumActiveListers]
                    .allSatisfy { (0...PerformanceDiagnostics.maximumCount).contains($0) }
        }
    }

    public struct HomeUIRecord: Encodable, Sendable {
        public let startedMilliseconds: Int
        public let elapsedMilliseconds: Int
        public let metrics: HomeUIMetrics
    }

    /// One visible Home owner. Replacement, stop and consent changes invalidate late samples.
    public final class HomeObservation: Sendable {
        private let owner: PerformanceDiagnostics
        private let generation: UUID
        private let id: UInt64

        fileprivate init(owner: PerformanceDiagnostics, generation: UUID, id: UInt64) {
            self.owner = owner
            self.generation = generation
            self.id = id
        }

        public var isCurrent: Bool {
            owner.lock.withLock { owner.generation == generation && owner.homeObservationID == id }
        }

        /// False means the owner ended or the bounded measurements were rejected.
        @discardableResult
        public func record(_ metrics: HomeUIMetrics) -> Bool {
            owner.lock.withLock {
                guard owner.generation == generation, owner.homeObservationID == id, metrics.isValid else { return false }
                let now = owner.uptime()
                let elapsed = PerformanceDiagnostics.milliseconds(from: owner.homeWindowStarted, to: now)
                guard metrics.maximumDelayMilliseconds <= elapsed else { return false }
                let entry = HomeUIRecord(
                    startedMilliseconds: PerformanceDiagnostics.milliseconds(from: owner.epoch, to: owner.homeWindowStarted),
                    elapsedMilliseconds: elapsed, metrics: metrics
                )
                if owner.homeUI.append(entry) {
                    owner.homeUIDropped = min(PerformanceDiagnostics.maximumCount, owner.homeUIDropped + 1)
                }
                owner.homeWindowStarted = now
                return true
            }
        }

        public func stop() {
            owner.lock.withLock {
                guard owner.generation == generation, owner.homeObservationID == id else { return }
                owner.homeObservationID = nil
            }
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

    private struct Ring<Value> {
        var entries: [Value?]
        var next = 0

        init(capacity: Int) { entries = Array(repeating: nil, count: capacity) }

        mutating func append(_ entry: Value) -> Bool {
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
    private var recent = Ring<Entry>(capacity: PerformanceDiagnostics.maximumRecent)
    private var slow = Ring<Entry>(capacity: PerformanceDiagnostics.maximumSlow)
    private var homeRecent = Ring<Entry>(capacity: PerformanceDiagnostics.maximumRecent)
    private var homeSlow = Ring<Entry>(capacity: PerformanceDiagnostics.maximumSlow)
    private var homeDropped = 0
    private var homeUI = Ring<HomeUIRecord>(capacity: PerformanceDiagnostics.maximumHomeUI)
    private var homeUIDropped = 0
    private var homeObservationID: UInt64?
    private var homeWindowStarted: UInt64 = 0
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
            homeRecent = Ring(capacity: Self.maximumRecent)
            homeSlow = Ring(capacity: Self.maximumSlow)
            homeDropped = 0
            homeUI = Ring(capacity: Self.maximumHomeUI)
            homeUIDropped = 0
            homeObservationID = nil
            homeWindowStarted = 0
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
            let limit = operation.isHomePresentation ? Self.maximumActive : Self.maximumActive - Self.reservedHomeActive
            guard active.count < limit else {
                dropped = min(Self.maximumCount, dropped + 1)
                if operation.isHomePresentation { homeDropped = min(Self.maximumCount, homeDropped + 1) }
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
            if entry.operation.isHomePresentation {
                let homeReplaced = Self.milliseconds(from: entry.started, to: now) >= Self.slowMilliseconds
                    ? homeSlow.append(entry) : homeRecent.append(entry)
                if homeReplaced { homeDropped = min(Self.maximumCount, homeDropped + 1) }
            }
        }
    }

    public func beginHomeObservation() -> HomeObservation? {
        lock.withLock {
            guard let generation else { return nil }
            nextID &+= 1
            homeObservationID = nextID
            homeWindowStarted = uptime()
            return HomeObservation(owner: self, generation: generation, id: nextID)
        }
    }

    /// Event timestamps must belong to the current consent session. Wall-clock
    /// boundaries are local attribution checks only and are never serialized.
    /// Takes a bounded value copy under the lock; encoding happens outside it.
    public func snapshot(forEventAt eventDate: Date? = nil) -> Snapshot? {
        let captured = lock.withLock { () -> (
            UUID, UInt64, UInt64, Int, Int, [UInt64: Entry], Ring<Entry>, Ring<Entry>,
            Ring<Entry>, Ring<Entry>, Int, Ring<HomeUIRecord>, Int
        )? in
            guard let generation else { return nil }
            if let eventDate {
                guard eventDate.timeIntervalSinceReferenceDate.isFinite,
                      eventDate >= startedAt, eventDate <= wallClock() else { return nil }
            }
            return (
                generation, epoch, uptime(), maxActive, dropped, active, recent, slow,
                homeRecent, homeSlow, homeDropped, homeUI, homeUIDropped
            )
        }
        guard let (
            generation, epoch, now, maxActive, dropped, active, recent, slow,
            homeRecent, homeSlow, homeDropped, homeUI, homeUIDropped
        ) = captured else { return nil }
        func records(_ entries: [Entry]) -> [Record] {
            entries.sorted { $0.started < $1.started }.map { $0.record(epoch: epoch, now: now) }
        }
        return Snapshot(
            schema: 1, elapsedMilliseconds: Self.milliseconds(from: epoch, to: now),
            maxActive: maxActive, dropped: dropped,
            active: records(Array(active.values)),
            recent: records(recent.entries.compactMap { $0 }),
            slow: records(slow.entries.compactMap { $0 }),
            homeRecent: records(homeRecent.entries.compactMap { $0 }),
            homeSlow: records(homeSlow.entries.compactMap { $0 }), homeDropped: homeDropped,
            homeUI: homeUI.entries.compactMap { $0 }.sorted { $0.startedMilliseconds < $1.startedMilliseconds },
            homeUIDropped: homeUIDropped, generation: generation
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
