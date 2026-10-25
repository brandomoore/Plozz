import CoreModels
import Foundation

struct PublicMetaDBRatingCacheEntry {
    let expires: Date
    let ratings: [ExternalRating]
}

public extension PublicMetaDBService {
    func cachedCommunityRatings(for item: MediaItem) -> [ExternalRating]? {
        guard !item.usesProviderRatings, communityRatingsEnabled, phase == .connected,
              let content = Self.ratingContent(item),
              let entry = communityRatingsCache[content], entry.expires > Date() else { return nil }
        return entry.ratings
    }

    func communityRatings(for item: MediaItem) async throws -> [ExternalRating] {
        guard !item.usesProviderRatings, communityRatingsEnabled, phase == .connected,
              let content = Self.ratingContent(item) else { return [] }
        if let cached = cachedCommunityRatings(for: item) { return cached }
        let (client, epoch) = try communityRatingsClient()
        let response = try await client.ratings(for: content, label: "Overall")
        try Task.checkCancellation()
        guard epoch.isCurrent, communityRatingsEnabled else { throw PublicMetaDB.Failure.connectionChanged }
        guard response.isComplete, Set(response.items.map(\.id)).count == response.items.count,
              response.items.allSatisfy({ $0.value.content == content && $0.value.label == "Overall" }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        let ratings: [ExternalRating]
        if response.total == 0 {
            guard response.average == nil else { throw PublicMetaDB.Failure.incompleteResponse }
            ratings = []
        } else {
            guard let average = response.average, average.isFinite, (0...100).contains(average) else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
            var rating = ExternalRating(source: .provider, value: average, scale: .outOfHundred, ratingCount: response.total)
            rating.providerDisplay = .init(
                sourceID: "publicmetadb.overall", name: "PublicMetaDB", value: rating.displayValue,
                order: RatingSource.provider.sortRank
            )
            ratings = [rating]
        }
        if communityRatingsCache.count >= 256,
           let oldest = communityRatingsCache.min(by: { $0.value.expires < $1.value.expires })?.key {
            communityRatingsCache.removeValue(forKey: oldest)
        }
        communityRatingsCache[content] = .init(expires: Date().addingTimeInterval(300), ratings: ratings)
        return ratings
    }

    internal static func ratingContent(_ item: MediaItem) -> PublicMetaDB.Content? {
        guard item.kind != .season else { return nil }
        return PublicMetaDB.Content.matching(item)
    }
}
