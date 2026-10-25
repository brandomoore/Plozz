import CoreModels
import Foundation

/// Delivery evidence for the existing watchlist outbox, not another queue.
struct PublicMetaDBWatchlistReceipts: Sendable {
    private struct Receipt: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.publicmetadb-watchlist-delivery.v1"
        enum Phase: String, Codable { case attempted, confirmed, retryable }
        let deliveryID: String
        let desiredState: WatchlistDesiredState
        let phase: Phase
    }

    private static let lock = NSLock()
    let store: DurableLocalStateStore
    let selectionID: UUID

    func begin(deliveryID: String, content: PublicMetaDB.Content, desiredState: WatchlistDesiredState) throws {
        try Self.lock.withLock {
            let key = try key(content)
            if let previous = try store.load(Receipt.self, for: key),
               previous.phase == .attempted || (previous.deliveryID == deliveryID && previous.phase == .confirmed) {
                throw PublicMetaDB.Failure.uncertainWrite
            }
            try store.save(Receipt(deliveryID: deliveryID, desiredState: desiredState, phase: .attempted), for: key)
        }
    }

    func observe(content: PublicMetaDB.Content, isPresent: Bool) throws {
        try Self.lock.withLock {
            let key = try key(content)
            guard let previous = try store.load(Receipt.self, for: key), previous.phase == .attempted,
                  (previous.desiredState == .present) == isPresent else { return }
            try store.save(Receipt(
                deliveryID: previous.deliveryID, desiredState: previous.desiredState, phase: .confirmed
            ), for: key)
        }
    }

    func confirm(deliveryID: String, content: PublicMetaDB.Content) throws {
        try update(deliveryID: deliveryID, content: content, phase: .confirmed)
    }

    func allowRetry(deliveryID: String, content: PublicMetaDB.Content) throws {
        try update(deliveryID: deliveryID, content: content, phase: .retryable)
    }

    private func update(deliveryID: String, content: PublicMetaDB.Content, phase: Receipt.Phase) throws {
        try Self.lock.withLock {
            let key = try key(content)
            guard let previous = try store.load(Receipt.self, for: key), previous.deliveryID == deliveryID else { return }
            try store.save(Receipt(deliveryID: deliveryID, desiredState: previous.desiredState, phase: phase), for: key)
        }
    }

    private func key(_ content: PublicMetaDB.Content) throws -> DurableLocalStateKey {
        try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: "publicmetadb", sourceID: selectionID.uuidString),
            recordID: "\(content.mediaType.rawValue)-\(content.tmdbID)"
        )
    }
}
