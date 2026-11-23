import CoreModels
import Foundation

struct PublicMetaDBRatingCacheEntry {
    let expires: Date
    let ratings: [ExternalRating]
}

public struct PublicMetaDBCommunityRatingLookup: Sendable {
    let item: MediaItem
    let epoch: PublicMetaDBConnectionEpoch
}

public extension PublicMetaDBService {
    func communityRatingLookup(for item: MediaItem) async throws -> PublicMetaDBCommunityRatingLookup? {
        guard !item.usesProviderRatings, communityRatingsEnabled, phase == .connected else { return nil }
        let (client, epoch) = try communityRatingsClient()
        var lookupItem = item
        if Self.ratingContent(item) == nil {
            guard item.kind == .episode, let episode = item.episodeNumber,
                  item.episodeNumberEnd == nil || item.episodeNumberEnd == episode,
                  let resolveLibraryEpisode else { return nil }
            guard var library = try await resolveLibraryEpisode(item) else { return nil }
            try Task.checkCancellation()
            guard epoch.isCurrent, communityRatingsEnabled else { throw PublicMetaDB.Failure.connectionChanged }
            guard library.id == item.id, library.sourceAccountID == item.sourceAccountID,
                  library.kind == .episode, !library.usesProviderRatings,
                  library.seriesID == item.seriesID,
                  library.seasonNumber == item.seasonNumber, library.episodeNumber == item.episodeNumber,
                  !MediaItemIdentity.externalIdentitiesConflict(
                      MediaItemIdentity.identities(for: item), MediaItemIdentity.identities(for: library)
                  ) else { throw PublicMetaDB.Failure.incompleteResponse }
            guard let content = PublicMetaDB.Content.episodeCandidate(library),
                  let reference = try await resolveEpisodeIdentity?(content) else { return nil }
            try Task.checkCancellation()
            guard epoch.isCurrent, communityRatingsEnabled else { throw PublicMetaDB.Failure.connectionChanged }
            let identity = try PublicMetaDBEpisodeIdentity(content: content, item: reference)
            guard identity.matches(library) else { return nil }
            library.episodeOrdering = .tmdb
            lookupItem = library
        }
        _ = try await communityRatings(for: lookupItem, client: client, epoch: epoch)
        return .init(item: lookupItem, epoch: epoch)
    }

    func cachedCommunityRatings(for lookup: PublicMetaDBCommunityRatingLookup) -> [ExternalRating]? {
        guard lookup.epoch.isCurrent else { return nil }
        return cachedCommunityRatings(for: lookup.item)
    }

    func cachedCommunityRatings(for item: MediaItem) -> [ExternalRating]? {
        guard !item.usesProviderRatings, communityRatingsEnabled, phase == .connected,
              let content = Self.ratingContent(item),
              let entry = communityRatingsCache[content], entry.expires > Date() else { return nil }
        return entry.ratings
    }

    func communityRatings(for item: MediaItem) async throws -> [ExternalRating] {
        guard !item.usesProviderRatings, communityRatingsEnabled, phase == .connected,
              Self.ratingContent(item) != nil else { return [] }
        let (client, epoch) = try communityRatingsClient()
        return try await communityRatings(for: item, client: client, epoch: epoch)
    }

    private func communityRatings(
        for item: MediaItem, client: PublicMetaDBClient, epoch: PublicMetaDBConnectionEpoch
    ) async throws -> [ExternalRating] {
        try Task.checkCancellation()
        guard epoch.isCurrent, communityRatingsEnabled else { throw PublicMetaDB.Failure.connectionChanged }
        guard let content = Self.ratingContent(item) else { throw PublicMetaDB.Failure.invalidInput }
        if let cached = cachedCommunityRatings(for: item) { return cached }
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
