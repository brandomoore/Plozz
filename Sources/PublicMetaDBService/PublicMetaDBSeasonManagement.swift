import CoreModels
import Foundation

public extension PublicMetaDB {
    struct RatingBatchFailure: Error, Sendable {
        public let confirmedRecordIDs: [String]
        public let unconfirmedEpisodes: [Int]
        public let unconfirmedRecordIDs: [String]
        public var unconfirmedCount: Int { unconfirmedEpisodes.count + unconfirmedRecordIDs.count }
    }
}

public extension PublicMetaDBService {
    func seasonRatingsForManagement(
        tmdbID: Int, season: Int, expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.SeasonRatings {
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.seasonRatings(tmdbID: tmdbID, season: season)
        _ = try confirmedClient(expectedConnectionID)
        let records = result.episodes.flatMap(\.ratings)
        guard result.tmdbID == tmdbID, result.mediaType == .tv, result.season == season,
              !result.mayBeCapped, result.totalRatings == records.count,
              result.episodeCount == result.episodes.count,
              Set(result.episodes.map(\.episode)).count == result.episodes.count,
              Set(records.map(\.id)).count == records.count else { throw PublicMetaDB.Failure.incompleteResponse }
        for episode in result.episodes {
            guard episode.episode > 0, episode.total == episode.ratings.count,
                  episode.ratings.allSatisfy({
                      $0.value.content.tmdbID == tmdbID && $0.value.content.mediaType == .tv
                        && $0.value.content.season == season && $0.value.content.episode == episode.episode
                  }) else { throw PublicMetaDB.Failure.incompleteResponse }
            let groups = Dictionary(grouping: episode.ratings, by: \.value.label)
            guard Set(groups.keys) == Set(episode.aggregates.keys) else { throw PublicMetaDB.Failure.incompleteResponse }
            for (label, aggregate) in episode.aggregates {
                guard aggregate.label == label, aggregate.count == groups[label]?.count,
                      aggregate.average.isFinite, (0...100).contains(aggregate.average) else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
            }
        }
        if let average = result.seasonAverage {
            guard result.totalRatings > 0, average.isFinite, (0...100).contains(average) else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
        }
        return result
    }

    func submitManagedEpisodeRatings(
        tmdbID: Int, season: Int, label: String, ratings: [PublicMetaDB.EpisodeRatingInput],
        expectedConnectionID: UUID
    ) async throws {
        guard (1...50).contains(ratings.count), Set(ratings.map(\.episode)).count == ratings.count,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        _ = try await seasonRatingsForManagement(tmdbID: tmdbID, season: season, expectedConnectionID: expectedConnectionID)
        _ = try confirmedClient(expectedConnectionID)
        defer { invalidateCommunityRatings(expectedConnectionID: expectedConnectionID) }
        let result = try await client.submitEpisodeRatings(tmdbID: tmdbID, season: season, label: label, ratings: ratings)
        let after: PublicMetaDB.SeasonRatings
        do {
            after = try await seasonRatingsForManagement(tmdbID: tmdbID, season: season, expectedConnectionID: expectedConnectionID)
        } catch { throw PublicMetaDB.Failure.uncertainWrite }
        let records = after.episodes.flatMap(\.ratings)
        let confirmed = result.items.filter { item in
            records.contains {
                $0.id == item.id && $0.value.content.episode == item.episode
                    && $0.value.score == item.score && $0.value.label == item.label
            }
        }
        let unconfirmed = ratings.map(\.episode).filter { episode in !confirmed.contains { $0.episode == episode } }
        guard unconfirmed.isEmpty else {
            throw PublicMetaDB.RatingBatchFailure(
                confirmedRecordIDs: confirmed.map(\.id), unconfirmedEpisodes: unconfirmed, unconfirmedRecordIDs: []
            )
        }
    }

    func deleteManagedEpisodeRatings(
        _ records: [PublicMetaDB.Record<PublicMetaDB.Rating>], expectedConnectionID: UUID
    ) async throws {
        guard let first = records.first, let season = first.value.content.season,
              (1...50).contains(records.count), Set(records.map(\.id)).count == records.count,
              records.allSatisfy({
                  $0.value.content.tmdbID == first.value.content.tmdbID && $0.value.content.mediaType == .tv
                    && $0.value.content.season == season && $0.value.content.episode != nil
              }) else { throw PublicMetaDB.Failure.invalidInput }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await seasonRatingsForManagement(
            tmdbID: first.value.content.tmdbID, season: season, expectedConnectionID: expectedConnectionID
        ).episodes.flatMap(\.ratings)
        var existing: [String] = []
        for record in records {
            guard let current = before.first(where: { $0.id == record.id }) else { continue }
            guard current.value == record.value, current.updated == record.updated,
                  current.contributor == record.contributor else { throw AppError.conflict }
            existing.append(record.id)
        }
        _ = try confirmedClient(expectedConnectionID)
        guard !existing.isEmpty else { return }
        defer { invalidateCommunityRatings(expectedConnectionID: expectedConnectionID) }
        do { _ = try await client.deleteEpisodeRatings(ids: existing) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Exact selected IDs can still be reconciled without resending.
        }
        let after: [PublicMetaDB.Record<PublicMetaDB.Rating>]
        do {
            after = try await seasonRatingsForManagement(
                tmdbID: first.value.content.tmdbID, season: season, expectedConnectionID: expectedConnectionID
            ).episodes.flatMap(\.ratings)
        } catch { throw PublicMetaDB.Failure.uncertainWrite }
        let remaining = Set(after.map(\.id))
        let confirmed = records.map(\.id).filter { !remaining.contains($0) }
        let unconfirmed = records.map(\.id).filter { remaining.contains($0) }
        guard unconfirmed.isEmpty else {
            throw PublicMetaDB.RatingBatchFailure(
                confirmedRecordIDs: confirmed, unconfirmedEpisodes: [], unconfirmedRecordIDs: unconfirmed
            )
        }
    }
}
