import CoreModels
import Foundation

public extension PublicMetaDBService {
    var historyConnectionID: String? { phase == .connected ? connectionID?.uuidString : nil }

    func historySnapshot(expectedConnectionID: String) async throws -> TrackerHistorySnapshot {
        guard historyConnectionID == expectedConnectionID else { throw TrackerHistoryError.scopeChanged }
        let snapshot = try await historySnapshot()
        guard historyConnectionID == expectedConnectionID,
              snapshot.connectionID == expectedConnectionID else { throw TrackerHistoryError.scopeChanged }
        return snapshot
    }

    func historySnapshot() async throws -> TrackerHistorySnapshot {
        guard let client, let connectionID else { throw PublicMetaDB.Failure.disconnected }
        let watches = try await client.completeHistory()
        let resumes = try await client.completeResumePoints()
        try Task.checkCancellation()
        guard self.connectionID == connectionID else { throw PublicMetaDB.Failure.connectionChanged }
        var observations: [TrackerHistoryObservation] = []
        observations.reserveCapacity(watches.count + resumes.count)
        for record in watches {
            observations.append(try record.value.content.observation(
                recordID: "watched/\(record.id)", fact: .watched(at: record.value.watchedAt)
            ))
        }
        for record in resumes {
            let updated: Date?
            if let value = record.updated {
                updated = try PublicMetaDBClient.decoder().decode(Date.self, from: PublicMetaDBClient.encode(value))
            } else {
                updated = nil
            }
            observations.append(try record.value.content.observation(
                recordID: "resume/\(record.id)",
                fact: .resume(
                    seconds: record.value.positionMilliseconds / 1_000,
                    runtime: record.value.runtimeMilliseconds / 1_000, updatedAt: updated
                )
            ))
        }
        return try TrackerHistorySnapshot(
            trackerID: "publicmetadb", connectionID: connectionID.uuidString,
            observations: observations, expectedCount: watches.count + resumes.count
        )
    }
}

private extension PublicMetaDB.Content {
    func observation(recordID: String, fact: TrackerHistoryObservation.Fact) throws -> TrackerHistoryObservation {
        guard isPlayable else { throw PublicMetaDB.Failure.incompleteResponse }
        let source: String
        if let season, let episode {
            source = "series-tmdb:s\(season)e\(episode)"
        } else {
            source = "tmdb"
        }
        return try TrackerHistoryObservation(
            recordID: recordID, kind: mediaType == .movie ? .movie : .episode,
            identities: [.external(source: source, value: String(tmdbID))],
            season: season, episode: episode, episodeOrdering: mediaType == .tv ? .tmdb : nil,
            fact: fact
        )
    }
}
