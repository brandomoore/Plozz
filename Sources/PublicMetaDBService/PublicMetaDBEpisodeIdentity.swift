import CoreModels
import Foundation

struct PublicMetaDBEpisodeIdentity: Codable, Sendable {
    typealias Resolving = @MainActor @Sendable (PublicMetaDB.Content) async throws -> MediaItem?

    let content: PublicMetaDB.Content
    let identities: [MediaIdentity]

    init(content: PublicMetaDB.Content, item: MediaItem) throws {
        guard item.kind == .episode, PublicMetaDB.Content.matching(item) == content else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        self.content = content
        identities = MediaItemIdentity.identities(for: item)
    }

    func matches(_ item: MediaItem) -> Bool {
        TrackerHistoryObservation.matches(
            item, kind: .episode, identities: identities,
            season: content.season, episode: content.episode, requiresExactEpisodeIdentity: true
        )
    }
}
