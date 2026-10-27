import CoreModels
import Foundation
import MetadataKit

public typealias OnlineTrailerResolving = @Sendable (MediaItem) async -> [MediaItem]

/// Selects a metadata-supplied link, not an extracted or embed-verified stream.
public typealias PlayableTrailerResolving = @Sendable ([String]) async -> String?

enum OnlineTrailerSource {
    static func trailers(for item: MediaItem, limit: Int = 6) async -> [MediaItem] {
        await DetailMetadataResolver(providerConfig: { .resolved() })
            .trailers(for: item, limit: limit)
    }
}
