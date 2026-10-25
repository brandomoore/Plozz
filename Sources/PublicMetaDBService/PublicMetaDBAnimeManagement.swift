import CoreModels
import Foundation

public extension PublicMetaDBService {
    func animeMappingsForManagement(
        tmdbID: Int, expectedConnectionID: UUID
    ) async throws -> PublicMetaDB.AnimeSeasons {
        let client = try confirmedClient(expectedConnectionID)
        let result = try await client.animeSeasons(tmdbID: tmdbID)
        _ = try confirmedClient(expectedConnectionID)
        let chunks = result.seasons.flatMap(\.chunks)
        guard result.tmdbID == tmdbID, result.total == chunks.count,
              Set(chunks.map(\.id)).count == chunks.count,
              Set(result.seasons.map(\.id)).count == result.seasons.count,
              result.seasons.allSatisfy({
                  !$0.id.isEmpty && $0.seasonNumber > 0 && !$0.chunks.isEmpty
                      && !$0.contributor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && ["community", "user"].contains($0.source)
              }) else { throw PublicMetaDB.Failure.incompleteResponse }
        return result
    }

    func replaceManagedAnimeMapping(
        _ mapping: PublicMetaDB.AnimeMapping, observed: PublicMetaDB.AnimeSeasons, expectedConnectionID: UUID
    ) async throws {
        guard observed.tmdbID == mapping.tmdbID else { throw PublicMetaDB.Failure.invalidInput }
        let mutation = try beginAnimeMutation(tmdbID: mapping.tmdbID, connection: expectedConnectionID)
        defer { activeAnimeMutations.remove(mutation) }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await animeMappingsForManagement(tmdbID: mapping.tmdbID, expectedConnectionID: expectedConnectionID)
        guard before == observed else { throw AppError.conflict }
        let created = try await client.replaceAnimeMapping(mapping)
        try await confirmContributionChange(expectedConnectionID) {
            let after = try await self.animeMappingsForManagement(
                tmdbID: mapping.tmdbID, expectedConnectionID: expectedConnectionID
            )
            let ids = Set(created.chunks.map(\.id))
            let matches = after.seasons.filter {
                $0.source == "user" && $0.seasonNumber == mapping.seasonNumber
                    && $0.seasonName == mapping.seasonName && Set($0.chunks.map(\.id)) == ids
            }
            guard matches.count == 1, let group = matches.first,
                  created.chunks.allSatisfy({ created in
                      group.chunks.contains { $0.id == created.id && $0.value == created.value }
                  }) else { throw PublicMetaDB.Failure.uncertainWrite }
        }
    }

    func deleteManagedAnimeChunk(
        _ record: PublicMetaDB.Record<PublicMetaDB.AnimeChunk>, tmdbID: Int, expectedConnectionID: UUID
    ) async throws {
        let mutation = try beginAnimeMutation(tmdbID: tmdbID, connection: expectedConnectionID)
        defer { activeAnimeMutations.remove(mutation) }
        try await deleteManagedContribution(record, category: .animeSeasons, expectedConnectionID: expectedConnectionID) {
            try await self.animeMappingsForManagement(tmdbID: tmdbID, expectedConnectionID: expectedConnectionID)
                .seasons.flatMap(\.chunks)
        }
    }

    func deleteManagedAnimeSeason(
        seasonNumber: Int, observed: PublicMetaDB.AnimeSeasons, expectedConnectionID: UUID
    ) async throws {
        guard seasonNumber > 0 else { throw PublicMetaDB.Failure.invalidInput }
        let mutation = try beginAnimeMutation(tmdbID: observed.tmdbID, connection: expectedConnectionID)
        defer { activeAnimeMutations.remove(mutation) }
        let client = try confirmedClient(expectedConnectionID)
        let before = try await animeMappingsForManagement(
            tmdbID: observed.tmdbID, expectedConnectionID: expectedConnectionID
        )
        guard before == observed else { throw AppError.conflict }
        // Only the authenticated endpoint knows which group belongs to this key.
        // A lost acknowledgement cannot be reconciled by guessing from a name.
        let deleted = try await client.deleteAnimeMapping(tmdbID: observed.tmdbID, seasonNumber: seasonNumber)
        try await confirmContributionChange(expectedConnectionID) {
            let after = try await self.animeMappingsForManagement(
                tmdbID: observed.tmdbID, expectedConnectionID: expectedConnectionID
            )
            let beforeChunks = before.seasons.flatMap(\.chunks)
            let afterChunks = after.seasons.flatMap(\.chunks)
            let afterIDs = Set(afterChunks.map(\.id))
            let removed = beforeChunks.filter { !afterIDs.contains($0.id) }
            guard deleted <= beforeChunks.count, removed.count == deleted,
                  afterChunks.count == beforeChunks.count - deleted,
                  afterChunks.allSatisfy({ remaining in
                      beforeChunks.contains { $0.id == remaining.id && $0.value == remaining.value }
                  }) else { throw PublicMetaDB.Failure.uncertainWrite }
            if deleted > 0 {
                let removedIDs = Set(removed.map(\.id))
                guard before.seasons.contains(where: {
                    $0.source == "user" && $0.seasonNumber == seasonNumber
                        && Set($0.chunks.map(\.id)) == removedIDs
                }) else { throw PublicMetaDB.Failure.uncertainWrite }
            }
        }
    }

    private func beginAnimeMutation(tmdbID: Int, connection: UUID) throws -> String {
        _ = try confirmedClient(connection)
        let key = "\(connection.uuidString):\(tmdbID)"
        guard activeAnimeMutations.insert(key).inserted else { throw AppError.conflict }
        return key
    }
}
