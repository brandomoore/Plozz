import CoreModels
import Foundation

enum SimklHistoryKind: String, CaseIterable, Sendable {
    case shows, movies, anime

    var listFields: [String] {
        self == .movies ? ["plantowatch", "completed", "dropped"]
            : ["plantowatch", "watching", "completed", "hold", "dropped"]
    }
}

struct SimklHistoryActivity: Decodable, Equatable, Sendable {
    let all: String
    let tvShows: [String: String]
    let movies: [String: String]
    let anime: [String: String]

    enum CodingKeys: String, CodingKey {
        case all, movies, anime
        case tvShows = "tv_shows"
    }

    subscript(kind: SimklHistoryKind) -> [String: String] {
        var fields = switch kind {
        case .shows: tvShows
        case .movies: movies
        case .anime: anime
        }
        if fields["dropped"] == nil { fields["dropped"] = fields["notinteresting"] }
        return fields
    }

    func validate() throws {
        _ = try SimklHistoryDate.parse(all)
        for kind in SimklHistoryKind.allCases {
            for field in kind.listFields + ["all", "playback", "removed_from_list"] {
                guard let value = self[kind][field] else { throw TrackerHistoryError.incompleteSnapshot }
                _ = try SimklHistoryDate.parse(value)
            }
        }
    }
}

struct SimklHistoryEntry: Decodable, Sendable {
    struct Season: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            struct IDs: Decodable, Sendable {
                let tvdbID: Int?
                enum CodingKeys: String, CodingKey { case tvdbID = "tvdb_id" }
            }
            let number: Int
            let watchedAt: String
            let ids: IDs?
            enum CodingKeys: String, CodingKey {
                case number, ids
                case watchedAt = "watched_at"
            }
        }
        let number: Int
        let episodes: [Episode]
    }

    let movie: SimklListEntry.Title?
    let show: SimklListEntry.Title?
    let status: String?
    let lastWatchedAt: String?
    let watchedEpisodesCount: Int?
    let seasons: [Season]?
    let isRewatch: Bool?

    enum CodingKeys: String, CodingKey {
        case movie, show, status, seasons
        case lastWatchedAt = "last_watched_at"
        case watchedEpisodesCount = "watched_episodes_count"
        case isRewatch = "is_rewatch"
    }

    func ids(for kind: SimklHistoryKind) throws -> SimklResponseIDs {
        guard isRewatch != true,
              let ids = kind == .movies ? movie?.ids : show?.ids,
              kind == .movies ? show == nil : movie == nil,
              let id = ids.simkl, id > 0 else { throw TrackerHistoryError.invalidObservation }
        return ids
    }

    func observations(kind: SimklHistoryKind, includesListStates: Bool = false) throws -> [TrackerHistoryObservation] {
        let ids = try ids(for: kind)
        guard let id = ids.simkl, let status,
              (kind.listFields + ["notinteresting"]).contains(status) else {
            throw TrackerHistoryError.invalidObservation
        }
        let identities = try ids.historyIdentities()
        let date = try lastWatchedAt.map(SimklHistoryDate.watchDate) ?? nil
        let recordID = "\(kind.rawValue)/\(id)"
        var listEvidence: [TrackerHistoryObservation] = []
        if includesListStates {
            let state: TrackerHistoryListState
            switch status {
            case "plantowatch": state = .planning
            case "watching": state = .watching
            case "hold": state = .paused
            case "dropped", "notinteresting": state = .dropped
            case "completed": state = .completed
            default: throw TrackerHistoryError.invalidObservation
            }
            listEvidence = [try .init(
                recordID: "\(recordID)/state", kind: kind == .movies ? .movie : .series,
                identities: identities, fact: .listState(state)
            )]
        }
        if kind == .movies {
            guard seasons == nil || seasons?.isEmpty == true else { throw TrackerHistoryError.invalidObservation }
            return status == "completed" ? [
                try .init(recordID: recordID, kind: .movie, identities: identities, fact: .watched(at: date))
            ] : listEvidence
        }
        guard let count = watchedEpisodesCount, count >= 0 else { throw TrackerHistoryError.invalidObservation }
        var result = listEvidence
        var seenSeasons: Set<Int> = []
        for season in seasons ?? [] {
            guard season.number >= 0, seenSeasons.insert(season.number).inserted else {
                throw TrackerHistoryError.invalidObservation
            }
            var seenEpisodes: Set<Int> = []
            for episode in season.episodes {
                guard episode.number > 0, seenEpisodes.insert(episode.number).inserted else {
                    throw TrackerHistoryError.invalidObservation
                }
                let suffix = ":s\(season.number)e\(episode.number)"
                var episodeIDs = try ids.historyIdentities(prefix: "series-", suffix: suffix)
                if let tvdbID = episode.ids?.tvdbID {
                    guard tvdbID > 0 else { throw TrackerHistoryError.invalidObservation }
                    episodeIDs.append(.external(source: "tvdb\(suffix)", value: String(tvdbID)))
                }
                result.append(try .init(
                    recordID: "\(recordID)\(suffix)", kind: .episode, identities: episodeIDs,
                    season: season.number, episode: episode.number, requiresExactEpisodeIdentity: true,
                    fact: .watched(at: SimklHistoryDate.watchDate(episode.watchedAt))
                ))
            }
        }
        if count > 0 {
            result.append(try .init(
                recordID: "\(recordID)/count", kind: .series, identities: identities,
                fact: .episodeCount(watched: count, repeats: nil)
            ))
        }
        return result
    }
}

struct SimklHistoryPlayback: Decodable, Sendable {
    struct Episode: Decodable, Sendable {
        let season: Int?
        let number: Int
    }
    let id: Int
    let progress: Double
    let pausedAt: String?
    let watchedAt: String?
    let type: String?
    let movie: SimklListEntry.Title?
    let show: SimklListEntry.Title?
    let anime: SimklListEntry.Title?
    let episode: Episode?

    enum CodingKeys: String, CodingKey {
        case id, progress, type, movie, show, anime, episode
        case pausedAt = "paused_at"
        case watchedAt = "watched_at"
    }

    func observation() throws -> TrackerHistoryObservation {
        guard id > 0 else { throw TrackerHistoryError.invalidObservation }
        let paused = try pausedAt.map(SimklHistoryDate.parse)
        if let watchedAt { _ = try SimklHistoryDate.parse(watchedAt) }
        // Older schema examples call a timestamp watched_at. Do not relabel it as a pause.
        let fact = TrackerHistoryObservation.Fact.resumePercentage(percent: progress, updatedAt: paused)
        if let movie {
            guard show == nil, anime == nil, episode == nil, type == nil || type == "movie", let ids = movie.ids else {
                throw TrackerHistoryError.invalidObservation
            }
            return try .init(recordID: "resume/\(id)", kind: .movie, identities: ids.historyIdentities(), fact: fact)
        }
        guard type == nil || type == "episode", (show == nil) != (anime == nil),
              let ids = (show ?? anime)?.ids, let episode, episode.number > 0 else {
            throw TrackerHistoryError.invalidObservation
        }
        if let season = episode.season {
            guard season >= 0 else { throw TrackerHistoryError.invalidObservation }
            return try .init(
                recordID: "resume/\(id)", kind: .episode,
                identities: ids.historyIdentities(prefix: "series-", suffix: ":s\(season)e\(episode.number)"),
                season: season, episode: episode.number, requiresExactEpisodeIdentity: true, fact: fact
            )
        }
        return try .init(recordID: "resume/\(id)", kind: .series, identities: ids.historyIdentities(), fact: fact)
    }
}

private extension SimklResponseIDs {
    func historyIdentities(prefix: String = "", suffix: String = "") throws -> [MediaIdentity] {
        var result: [MediaIdentity] = []
        if let simkl {
            guard simkl > 0 else { throw TrackerHistoryError.invalidObservation }
            result.append(.external(source: prefix + "simkl" + suffix, value: String(simkl)))
        }
        for (source, id) in [("tmdb", tmdb), ("tvdb", tvdb), ("myanimelist", mal), ("anilist", anilist), ("anidb", anidb)] {
            guard let id else { continue }
            let value = id.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw TrackerHistoryError.invalidObservation }
            if source != "tvdb", Int(value).map({ $0 > 0 }) != true {
                throw TrackerHistoryError.invalidObservation
            }
            if let numeric = Int(value), numeric <= 0 { throw TrackerHistoryError.invalidObservation }
            result.append(.external(source: prefix + source + suffix, value: value.lowercased()))
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

enum SimklHistoryDate {
    static func parse(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw TrackerHistoryError.invalidObservation }
        return date
    }

    static func watchDate(_ value: String) throws -> Date? {
        let date = try parse(value)
        return date.timeIntervalSince1970 == 1 ? nil : date
    }
}
