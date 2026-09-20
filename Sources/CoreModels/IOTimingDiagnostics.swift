import Foundation

/// Opt-in synchronous cache and artwork timings, including Release builds. Requires both
/// `PLZIO=1` and `PLZXMEM=1`; output joins `Library/Caches/plzxmem.log`.
/// Only the diagnostic emission moves off-thread, never the measured operation.
public enum IOTimingDiagnostics {
    public enum Label: String, Sendable {
        case identityModelLoad = "identity.model.load"
        case identityModelSave = "identity.model.save"
        case identityStoreLoad = "identity.store.load"
        case identityStoreRead = "identity.store.read"
        case identityStoreDecode = "identity.store.decode"
        case identityStoreSave = "identity.store.save"
        case identityStoreEncode = "identity.store.encode"
        case identityStoreWrite = "identity.store.write"
        case homeModelLoad = "home.model.load"
        case homeModelSaveHero = "home.model.saveHero"
        case homeStoreLoad = "home.store.load"
        case homeStoreRead = "home.store.read"
        case homeStoreDecode = "home.store.decode"
        case homeStoreExpire = "home.store.expire"
        case homeHeroSave = "home.hero.save"
        case homeHeroSanitize = "home.hero.sanitize"
        case homeHeroEncode = "home.hero.encode"
        case homeHeroMkdir = "home.hero.mkdir"
        case homeHeroWrite = "home.hero.write"
        case nativePosterPrepare = "native.poster.prepare"
        case nativePosterUpdate = "native.poster.update"
        case nativePosterLayout = "native.poster.layout"
        case cloudLedgerEncode = "cloud.ledger.encode"
        case cloudLedgerLoad = "cloud.ledger.load"
        case cloudLedgerWrite = "cloud.ledger.write"
        case cloudLedgerUnchanged = "cloud.ledger.unchanged"
    }

    public struct Metrics: Sendable {
        public var items: Int?
        public var bytes: Int?

        public init(items: Int? = nil, bytes: Int? = nil) {
            self.items = items
            self.bytes = bytes
        }
    }

    public static let isEnabled =
        ProcessInfo.processInfo.environment["PLZIO"] == "1"
        && BrowseDiagnostics.isEnabled

    private static let output = Output()

    /// Executes exactly once on the caller's thread and preserves thrown errors.
    /// Counts are collected only when enabled and after the measured interval.
    public static func measure<Result>(
        _ label: Label,
        minimumDurationNanoseconds: UInt64 = 0,
        metrics: (Result) -> Metrics = { _ in Metrics() },
        _ operation: () throws -> Result
    ) rethrows -> Result {
        guard isEnabled else { return try operation() }
        let startUnix = Date().timeIntervalSince1970
        let mainThread = Thread.isMainThread
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let result = try operation()
            let duration = DispatchTime.now().uptimeNanoseconds &- start
            if meetsThreshold(duration: duration, minimum: minimumDurationNanoseconds) {
                output.enqueue(Record(
                    label: label, startUnix: startUnix, start: start,
                    duration: duration, mainThread: mainThread,
                    succeeded: true, metrics: metrics(result)
                ))
            }
            return result
        } catch {
            let duration = DispatchTime.now().uptimeNanoseconds &- start
            output.enqueue(Record(
                label: label, startUnix: startUnix, start: start,
                duration: duration, mainThread: mainThread,
                succeeded: false, metrics: Metrics()
            ))
            throw error
        }
    }

    static func meetsThreshold(duration: UInt64, minimum: UInt64) -> Bool {
        duration >= minimum
    }

    struct Record: Sendable {
        let label: Label
        let startUnix: TimeInterval
        let start: UInt64
        let duration: UInt64
        let mainThread: Bool
        let succeeded: Bool
        let metrics: Metrics

        func line(dropped: UInt64) -> String {
            String(
                format: "PLZIO label=%@ startUnix=%.3f startUptimeMs=%.3f ms=%.3f main=%d success=%d items=%lld bytes=%lld dropped=%llu",
                label.rawValue, startUnix, Double(start) / 1_000_000,
                Double(duration) / 1_000_000, mainThread ? 1 : 0,
                succeeded ? 1 : 0, Int64(metrics.items ?? -1),
                Int64(metrics.bytes ?? -1), dropped
            )
        }
    }

    /// The admission lock never covers formatting or output. A slow file/stdout
    /// consumer drops new records instead of retaining an unbounded backlog.
    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.plozz.io-timing.output", qos: .utility)
        private let capacity: Int
        private let sink: @Sendable (String) -> Void
        private var pending = 0
        private var dropped: UInt64 = 0

        init(
            capacity: Int = 64,
            sink: @escaping @Sendable (String) -> Void = { BrowseDiagnostics.emit($0) }
        ) {
            self.capacity = capacity
            self.sink = sink
        }

        @discardableResult
        func enqueue(_ record: Record) -> Bool {
            let droppedBeforeAdmission: UInt64? = lock.withLock {
                guard pending < capacity else {
                    dropped &+= 1
                    return nil
                }
                pending += 1
                return dropped
            }
            guard let droppedBeforeAdmission else { return false }
            queue.async { [self] in
                defer { lock.withLock { pending -= 1 } }
                sink(record.line(dropped: droppedBeforeAdmission))
            }
            return true
        }
    }
}
