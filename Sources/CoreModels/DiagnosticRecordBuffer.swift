import Foundation

/// Bounded local technical evidence. Entries intentionally are not Encodable:
/// exporters must select safe fields and replace record IDs and timestamps.
public final class DiagnosticRecordBuffer<Value: Sendable>: @unchecked Sendable {
    public struct Entry: Sendable {
        public let timestamp: Date
        public let id: UUID
        public let value: Value
    }

    public struct Snapshot: Sendable {
        public let entries: [Entry]
        public let dropped: Int
    }

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var entries: [Entry] = []
    private var dropped = 0

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func append(_ value: Value) {
        lock.withLock {
            let now = clock()
            trim(at: now)
            entries.append(Entry(timestamp: now, id: UUID(), value: value))
            if entries.count > 32 {
                dropped = min(1_000_000_000, dropped + entries.count - 32)
                entries.removeFirst(entries.count - 32)
            }
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            trim(at: clock())
            return Snapshot(entries: entries, dropped: dropped)
        }
    }

    private func trim(at now: Date) {
        let before = entries.count
        entries.removeAll { $0.timestamp < now.addingTimeInterval(-48 * 3_600) }
        dropped = min(1_000_000_000, dropped + before - entries.count)
    }
}
