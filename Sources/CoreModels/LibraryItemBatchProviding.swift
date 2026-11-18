import Foundation

/// Optional exact-ID browsing transport. Each provider remains bound to one
/// authenticated server viewer; callers must never combine accounts in a batch.
public protocol LibraryItemBatchProviding: MediaProvider {
    /// Fresh native cards, including identity, artwork and server watch state.
    /// Missing items may be omitted and response order is unspecified. Request
    /// at most 50 distinct IDs; failures throw rather than masquerading as misses.
    /// This must not discover playback inventory or probe media.
    func libraryItems(ids: [String]) async throws -> [MediaItem]
}
