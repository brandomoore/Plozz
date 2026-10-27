#if canImport(UIKit)
import CoreModels
import CoreNetworking
import Foundation

/// Samples only the initial cover group before publication. Plex often omits
/// dimensions; use the normal authenticated artwork path rather than guess from a URL.
public enum CollectionCoverArtwork {
    public static func preparing(_ items: [MediaItem]) async throws -> [MediaItem] {
        try await preparing(items, loadAspectRatio: measure)
    }

    static func preparing(
        _ items: [MediaItem], loadAspectRatio: @escaping @Sendable (MediaItem) async -> Double?
    ) async throws -> [MediaItem] {
        guard CollectionCoverLayout.isCollectionGroup(items) else { return items }
        var result = items
        let indices = Array(items.prefix(CollectionCoverLayout.sampleLimit).indices).filter {
            items[$0].primaryImageAspectRatio.map { !$0.isFinite || $0 <= 0 } ?? true
        }
        try await withThrowingTaskGroup(of: (Int, Double?).self) { group in
            for index in indices {
                let item = items[index]
                group.addTask {
                    try Task.checkCancellation()
                    let ratio = await loadAspectRatio(item)
                    try Task.checkCancellation()
                    return (index, ratio)
                }
            }
            for try await (index, ratio) in group {
                result[index].primaryImageAspectRatio = ratio
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func measure(_ item: MediaItem) async -> Double? {
        await ArtworkSession.artworkResolveLimiter.run {
            guard !Task.isCancelled else { return nil as Double? }
            guard let artwork = await ArtworkFirstPaintResolver.resolve(
                references: item.artworkReferences(for: .poster), variant: .posterPreview,
                asyncOnlineURL: nil, prefersOnlineArtwork: false
            ), artwork.image.size.height > 0 else {
                if !Task.isCancelled, !item.artworkReferences(for: .poster).isEmpty {
                    PlozzLog.app.debug("Collection cover dimensions unavailable")
                }
                return nil
            }
            return Double(artwork.image.size.width / artwork.image.size.height)
        }
    }
}
#endif
