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

    enum Preparation { case alreadyMatched, dispatch }

    func prepare(
        deliveryID: String, content: PublicMetaDB.Content, desiredState: WatchlistDesiredState, isPresent: Bool
    ) throws -> Preparation {
        try Self.lock.withLock {
            let key = try key(content)
            let matches = (desiredState == .present) == isPresent
            if let previous = try store.load(Receipt.self, for: key) {
                if previous.phase == .attempted, (previous.desiredState == .present) != isPresent {
                    // A matching opposite intent does not settle a still-unobserved write.
                    throw PublicMetaDB.Failure.uncertainWrite
                }
                if previous.deliveryID == deliveryID {
                    guard previous.desiredState == desiredState else { throw PublicMetaDB.Failure.uncertainWrite }
                    if previous.phase == .confirmed {
                        guard matches else { throw PublicMetaDB.Failure.uncertainWrite }
                        return .alreadyMatched
                    }
                }
            }
            // Even a read-only match must survive loss of the outbox acknowledgement.
            try store.save(Receipt(
                deliveryID: deliveryID, desiredState: desiredState, phase: matches ? .confirmed : .attempted
            ), for: key)
            return matches ? .alreadyMatched : .dispatch
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
