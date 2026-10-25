import CoreModels
import Foundation

struct TraktHistoryRecord: Decodable, Sendable {
    let id: Int
    let type: String
    let movie: TraktMovieRef?
    let show: TraktShowRef?
    let episode: TraktEpisodeRef?
    let watchedAt: String?
    let action: String?
    let pausedAt: String?
    let progress: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, movie, show, episode, action, progress
        case watchedAt = "watched_at"
        case pausedAt = "paused_at"
    }

    func observation(playback: Bool) throws -> TrackerHistoryObservation {
        guard id > 0 else { throw TrackerHistoryError.invalidObservation }
        let fact: TrackerHistoryObservation.Fact
        if playback {
            guard let progress, let pausedAt, let date = TraktClient.parseTimestamp(pausedAt) else {
                throw TrackerHistoryError.invalidObservation
            }
            // Catalog runtimes cannot establish the duration of the played file.
            fact = .resumePercentage(percent: progress, updatedAt: date)
        } else {
            guard let action, ["watch", "scrobble", "checkin"].contains(action),
                  let watchedAt, let date = TraktClient.parseTimestamp(watchedAt) else {
                throw TrackerHistoryError.invalidObservation
            }
            fact = .watched(at: date)
        }
        let recordID = "\(playback ? "resume" : "watched")/\(id)"
        switch type {
        case "movie":
            guard let movie, show == nil, episode == nil else { throw TrackerHistoryError.invalidObservation }
            return try .init(
                recordID: recordID, kind: .movie, identities: movie.ids.historyIdentities(), fact: fact
            )
        case "episode":
            guard movie == nil, let show, let episode, let season = episode.season, let number = episode.number else {
                throw TrackerHistoryError.invalidObservation
            }
            let suffix = ":s\(season)e\(number)"
            return try .init(
                recordID: recordID, kind: .episode,
                identities: episode.ids.historyIdentities(suffix: suffix)
                    + show.ids.historyIdentities(prefix: "series-", suffix: suffix),
                season: season, episode: number, requiresExactEpisodeIdentity: true, fact: fact
            )
        default:
            throw TrackerHistoryError.invalidObservation
        }
    }
}

private extension TraktIDs {
    func historyIdentities(prefix: String = "", suffix: String = "") throws -> [MediaIdentity] {
        var result: [MediaIdentity] = []
        for (source, id) in [("tmdb", tmdb), ("tvdb", tvdb), ("trakt", trakt)] {
            guard let id else { continue }
            guard id > 0 else { throw TrackerHistoryError.invalidObservation }
            result.append(.external(source: prefix + source + suffix, value: String(id)))
        }
        if let imdb {
            guard imdb.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil else {
                throw TrackerHistoryError.invalidObservation
            }
            result.append(.external(source: prefix + "imdb" + suffix, value: imdb))
        }
        return result
    }
}

struct TraktHistoryActivity: Decodable, Equatable, Sendable {
    struct MediaActivity: Decodable, Equatable, Sendable {
        let watchedAt: String
        let pausedAt: String
        enum CodingKeys: String, CodingKey {
            case watchedAt = "watched_at"
            case pausedAt = "paused_at"
        }
    }
    let all: String
    let movies: MediaActivity
    let episodes: MediaActivity

    func validate() throws {
        guard [all, movies.watchedAt, movies.pausedAt, episodes.watchedAt, episodes.pausedAt]
            .allSatisfy({ TraktClient.parseTimestamp($0) != nil }) else {
            throw TrackerHistoryError.incompleteSnapshot
        }
    }
}
