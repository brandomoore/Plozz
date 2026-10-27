import Foundation

/// Optional, read-only rating metadata for an item already authorized by this provider.
/// Required item and playback requests must not call this presentation-only seam.
public protocol ServerRatingsProviding: Sendable {
    func serverRatings(for item: MediaItem) async throws -> [ExternalRating]?
    /// Memory-only read: this must never start a request or wait for an in-flight fetch.
    func cachedServerRatings(for item: MediaItem) async -> [ExternalRating]?
}

public extension ServerRatingsProviding {
    func cachedServerRatings(for item: MediaItem) async -> [ExternalRating]? { nil }
}

public extension MediaProvider {
    func applyingCachedServerRatings(to item: MediaItem) async -> MediaItem {
        guard !item.usesProviderRatings, let source = self as? any ServerRatingsProviding,
              let ratings = await source.cachedServerRatings(for: item), !Task.isCancelled else { return item }
        var result = item
        result.ratings = ratings
        result.usesProviderRatings = true
        return result
    }
}
