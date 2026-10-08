import Foundation

/// Created only after the system grants execution, and revoked synchronously
/// before cancellation crosses an actor boundary.
public final class DownloadBackgroundExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    public init() {}

    public var isValid: Bool { lock.withLock { valid } }

    public func invalidate() {
        lock.withLock { valid = false }
    }
}

public struct DownloadActivityProgress: Equatable, Sendable {
    public struct ItemProgress: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            case preparing
            case downloading
            case finishing
        }

        public let title: String
        public let seasonNumber: Int?
        public let episodeNumber: Int?
        public let phase: Phase
        public let fractionCompleted: Double?

        fileprivate init(record: DownloadedMediaRecord) {
            title = record.snapshot.title
            seasonNumber = record.snapshot.kind == .episode ? record.snapshot.seasonNumber : nil
            episodeNumber = record.snapshot.kind == .episode ? record.snapshot.episodeNumber : nil
            if record.status == .preparing {
                phase = .preparing
                fractionCompleted = record.preparationFraction.flatMap {
                    $0.isFinite ? min(1, max(0, $0)) : nil
                }
            } else if let total = record.totalBytes, total > 0, record.bytesDownloaded >= total {
                phase = .finishing
                fractionCompleted = nil
            } else {
                phase = .downloading
                fractionCompleted = record.fractionCompleted.map { min(1, max(0, $0)) }
            }
        }
    }

    public let totalUnitCount: Int64
    public let completedUnitCount: Int64
    public let completedCount: Int
    public let totalCount: Int
    public let hasActiveWork: Bool
    public let succeeded: Bool
    public let displayTitle: String?
    public let status: DownloadStatus
    public let estimatedTimeRemaining: TimeInterval?
    public let activeItemCount: Int
    public let currentItem: ItemProgress?
    public let currentItemNumber: Int?

    public init(records: [DownloadedMediaRecord], bytesPerSecond: Int64 = 0) {
        totalCount = records.count
        completedCount = records.filter { $0.status == .completed }.count
        hasActiveWork = records.contains { $0.status.isActive }
        succeeded = !records.isEmpty && completedCount == totalCount
        let activeItems = records.filter { $0.status == .downloading || $0.status == .preparing }
        activeItemCount = activeItems.count
        currentItem = activeItems.count == 1 ? activeItems.first.map(ItemProgress.init(record:)) : nil
        // Count the current step through sequential work, not the unordered registry.
        // Paused or failed peers leave gaps, so they require explicit completion counts.
        currentItemNumber = activeItems.count == 1 && records.allSatisfy({
            $0.status == .completed || $0.status.isActive
        }) ? completedCount + 1 : nil
        totalUnitCount = Int64(records.count) * 1_000
        // Equal-weight item progress, not an invented aggregate byte total.
        // Receiving every byte is not completion until engine finalization passes.
        completedUnitCount = records.reduce(0) { result, record in
            if record.status == .completed { return result + 1_000 }
            var fraction = max(0, record.fractionCompleted ?? 0)
            if record.quality != .original {
                // Requested renditions have two equally weighted work stages.
                // Advance preparation only from measured server progress.
                if record.status == .preparing {
                    let preparation = record.preparationFraction ?? 0
                    fraction = preparation.isFinite ? min(1, max(0, preparation)) / 2 : 0
                } else if record.status == .downloading || record.bytesDownloaded > 0 {
                    fraction = 0.5 + fraction / 2
                } else {
                    fraction = 0
                }
            }
            return result + Int64(min(999, fraction * 1_000))
        }
        if activeItems.count == 1, let record = activeItems.first {
            displayTitle = Self.mediaTitle(for: record)
        } else if records.count == 1, let record = records.first {
            displayTitle = Self.mediaTitle(for: record)
        } else if let batchID = records.first?.batchID,
                  records.allSatisfy({ $0.batchID == batchID }) {
            displayTitle = records.first?.batchTitle.flatMap(Self.nonemptyTitle)
        } else {
            displayTitle = nil
        }
        status = [.downloading, .preparing, .queued, .failed, .paused]
            .first { status in records.contains { $0.status == status } }
            ?? (records.isEmpty ? .paused : .completed)

        let remaining = records.filter { $0.status != .completed }
        if bytesPerSecond > 0, !remaining.isEmpty,
           remaining.allSatisfy({
               $0.status == .downloading || ($0.status == .queued && $0.quality == .original)
           }),
           remaining.allSatisfy({ ($0.totalBytes ?? 0) > $0.bytesDownloaded }) {
            estimatedTimeRemaining = remaining.reduce(0.0) {
                $0 + max(0, Double($1.totalBytes ?? 0) - Double($1.bytesDownloaded))
            } / Double(bytesPerSecond)
        } else {
            estimatedTimeRemaining = nil
        }
    }

    private static func mediaTitle(for record: DownloadedMediaRecord) -> String? {
        if record.snapshot.kind == .episode {
            if let title = record.snapshot.seriesTitle.flatMap(nonemptyTitle) { return title }
            if let title = record.batchTitle.flatMap(nonemptyTitle) { return title }
        }
        return nonemptyTitle(record.snapshot.title)
    }

    private static func nonemptyTitle(_ title: String) -> String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
