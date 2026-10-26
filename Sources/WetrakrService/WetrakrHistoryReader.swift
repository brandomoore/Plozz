import CoreModels
import CoreNetworking
import Foundation

actor WetrakrHistoryReader {
    private let includesListStates: Bool
    private struct Cache {
        let connectionID: String
        let activity: WetrakrHistoryActivity
        let watches: [TrackerHistoryObservation]
        let count: Int
    }
    private var cache: Cache?
    private var reading = false

    init(includesListStates: Bool = false) { self.includesListStates = includesListStates }

    func snapshot(
        client: WetrakrClient, accessToken: String, connectionID: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        try await validateScope()
        guard !reading else { throw TrackerHistoryError.stalePreview }
        reading = true
        defer { reading = false }
        if cache?.connectionID != connectionID { cache = nil }
        let before: WetrakrHistoryActivity = try await read(
            client, accessToken: accessToken, path: "/sync/last_activities", validateScope: validateScope
        ).value
        var watches: [TrackerHistoryObservation]
        var watchCount: Int
        if let cache, before.all != nil, cache.activity == before {
            watches = cache.watches
            watchCount = cache.count
        } else {
            watches = []
            watchCount = 0
            for target in ["movies", "episodes"] {
                let rows = try await complete(
                    client, accessToken: accessToken, path: "/sync/tracking/watched/history/\(target)",
                    target: target, playback: false, validateScope: validateScope
                )
                watches += rows.observations
                watchCount += rows.count
            }
            if includesListStates {
                for (status, state, targets) in [
                    ("planning", TrackerHistoryListState.planning, ["movies", "shows"]),
                    ("dropped", .dropped, ["movies", "shows"]),
                    ("hold", .paused, ["shows"])
                ] {
                    for target in targets {
                        let rows = try await complete(
                            client, accessToken: accessToken, path: "/sync/tracking/\(status)/\(target)",
                            target: target, playback: false, listState: state, validateScope: validateScope
                        )
                        watches += rows.observations
                        watchCount += rows.count
                    }
                }
            }
        }
        var observations = watches
        var expectedCount = watchCount
        // Playing clocks can move without a new activity stamp. Always refresh
        // the current set; absence never becomes a resume-clear observation.
        for target in ["movies", "episodes"] {
            let rows = try await complete(
                client, accessToken: accessToken, path: "/sync/tracking/playing/\(target)",
                target: target, playback: true, validateScope: validateScope
            )
            observations += rows.observations
            expectedCount += rows.count
        }
        let after: WetrakrHistoryActivity = try await read(
            client, accessToken: accessToken, path: "/sync/last_activities", validateScope: validateScope
        ).value
        guard before == after else { throw TrackerHistoryError.incompleteSnapshot }
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "wetrakr", connectionID: connectionID,
            observations: observations, expectedCount: expectedCount
        )
        try await validateScope()
        try Task.checkCancellation()
        cache = Cache(connectionID: connectionID, activity: before, watches: watches, count: watchCount)
        return snapshot
    }

    private func complete(
        _ client: WetrakrClient, accessToken: String, path: String, target: String,
        playback: Bool, listState: TrackerHistoryListState? = nil,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> (observations: [TrackerHistoryObservation], count: Int) {
        var observations: [TrackerHistoryObservation] = []
        var ids = Set<String>()
        var cursors = Set<String>()
        var cursor: String?
        var expectedCount: Int?
        for _ in 0..<100 {
            var query = [URLQueryItem(name: "compact", value: "true"), .init(name: "limit", value: "5000")]
            if let cursor { query.append(.init(name: "after", value: cursor)) }
            let result: (value: [WetrakrHistoryRecord], response: HTTPURLResponse) = try await read(
                client, accessToken: accessToken, path: path, query: query, validateScope: validateScope
            )
            guard let rawCount = result.response.value(forHTTPHeaderField: "X-Pagination-Item-Count"),
                  let count = Int(rawCount), (0...100_000).contains(count),
                  expectedCount == nil || expectedCount == count,
                  result.value.count <= 5_000 else { throw TrackerHistoryError.incompleteSnapshot }
            expectedCount = count
            for record in result.value {
                let observation = try record.observation(target: target, playback: playback, listState: listState)
                guard ids.insert(observation.recordID).inserted else { throw TrackerHistoryError.incompleteSnapshot }
                observations.append(observation)
            }
            guard observations.count <= count else { throw TrackerHistoryError.incompleteSnapshot }
            guard let next = result.response.value(forHTTPHeaderField: "X-Pagination-Next") else {
                guard observations.count == count else { throw TrackerHistoryError.incompleteSnapshot }
                return (observations, count)
            }
            guard !next.isEmpty, next.utf8.count <= 2_048,
                  next.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
                  !result.value.isEmpty, observations.count < count, cursors.insert(next).inserted else {
                throw TrackerHistoryError.incompleteSnapshot
            }
            cursor = next
        }
        throw TrackerHistoryError.incompleteSnapshot
    }

    private func read<Value: Decodable & Sendable>(
        _ client: WetrakrClient, accessToken: String, path: String, query: [URLQueryItem] = [],
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> (value: Value, response: HTTPURLResponse) {
        try Task.checkCancellation()
        try await validateScope()
        var endpoint = Endpoint(path: path, queryItems: query)
        endpoint.maximumResponseBytes = 8 * 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        let (data, response) = try await client.send(
            endpoint, accessToken: accessToken, operation: .historyRead, validateScope: validateScope
        )
        try Task.checkCancellation()
        guard response.statusCode == 200, data.count <= 8 * 1_024 * 1_024 else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        do { return (try JSONDecoder().decode(Value.self, from: data), response) }
        catch {
            PlozzLog.networking.error("WeTrakr history response could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
    }
}

private struct WetrakrHistoryActivity: Decodable, Equatable, Sendable {
    let all: String?
    private enum CodingKeys: String, CodingKey { case all }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.all) else { throw TrackerHistoryError.incompleteSnapshot }
        all = try values.decodeIfPresent(String.self, forKey: .all)
        if let all { _ = try WetrakrDate.parse(all) }
    }
}

struct WetrakrHistoryRecord: Decodable, Sendable {
    struct Playback: Decodable, Sendable {
        let status: String
        let progress: Double
        let runtime: Double?
        let trackedAt: String
        enum CodingKeys: String, CodingKey {
            case status, progress = "progress_percent", runtime = "runtime_seconds", trackedAt = "tracked_at"
        }
    }
    let id: Int
    let type: String
    let ids: WetrakrIDs?
    let showID: Int?
    let showIDs: WetrakrIDs?
    let season: Int?
    let episode: Int?
    let playID: String?
    let watchedAt: String?
    let unknownDate: Bool?
    let playback: Playback?
    let status: String?
    enum CodingKeys: String, CodingKey {
        case id, type, ids, playback, status, showID = "show_id", showIDs = "show_ids"
        case season = "season_number", episode = "number", playID = "play_id"
        case watchedAt = "watched_at", unknownDate = "watched_at_unknown"
    }

    func observation(
        target: String, playback isPlayback: Bool, listState: TrackerHistoryListState? = nil
    ) throws -> TrackerHistoryObservation {
        guard id > 0, ["movies": "movie", "shows": "show", "episodes": "episode"][target] == type else {
            throw TrackerHistoryError.invalidObservation
        }
        let fact: TrackerHistoryObservation.Fact
        let recordID: String
        if let listState {
            guard !isPlayback, let status,
                  Self.listState(status) == listState else { throw TrackerHistoryError.invalidObservation }
            fact = .listState(listState)
            recordID = "state/\(type)/\(id)"
        } else if isPlayback {
            guard let playback, ["playing", "paused"].contains(playback.status),
                  playback.progress.isFinite, (0...100).contains(playback.progress),
                  playback.runtime.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw TrackerHistoryError.invalidObservation
            }
            let date = try WetrakrDate.parse(playback.trackedAt)
            if playback.status == "paused", let runtime = playback.runtime,
               playback.progress > 0, playback.progress < 100 {
                fact = .resume(seconds: runtime * (playback.progress / 100), runtime: runtime, updatedAt: date)
            } else {
                fact = .resumePercentage(percent: playback.progress, updatedAt: date)
            }
            recordID = "resume/\(type)/\(id)"
        } else {
            guard let playID, !playID.isEmpty, let watchedAt else { throw TrackerHistoryError.invalidObservation }
            let date = try WetrakrDate.parse(watchedAt)
            fact = .watched(at: unknownDate == true ? nil : date)
            recordID = "watched/\(playID)"
        }
        if type == "movie" || type == "show" {
            guard showID == nil, showIDs == nil, season == nil, episode == nil else {
                throw TrackerHistoryError.invalidObservation
            }
            guard type == "movie" || listState != nil else { throw TrackerHistoryError.invalidObservation }
            return try .init(
                recordID: recordID, kind: type == "movie" ? .movie : .series,
                identities: Self.identities(nativeID: id, ids: ids), fact: fact
            )
        }
        guard let showID, showID > 0, let season, season >= 0, let episode, episode > 0 else {
            throw TrackerHistoryError.invalidObservation
        }
        let suffix = ":s\(season)e\(episode)"
        return try .init(
            recordID: recordID, kind: .episode,
            identities: Self.identities(nativeID: id, ids: ids, suffix: suffix)
                + Self.identities(nativeID: showID, ids: showIDs, prefix: "series-", suffix: suffix),
            season: season, episode: episode, requiresExactEpisodeIdentity: true, fact: fact
        )
    }

    static func listState(_ status: String) -> TrackerHistoryListState? {
        switch status {
        case "hold", "paused": .paused
        case "watched": .completed
        default: TrackerHistoryListState(rawValue: status)
        }
    }

    static func identities(
        nativeID: Int, ids: WetrakrIDs?, prefix: String = "", suffix: String = ""
    ) throws -> [MediaIdentity] {
        var result: [MediaIdentity] = [.external(source: prefix + "wetrakr" + suffix, value: String(nativeID))]
        guard let ids else { return result }
        for (source, value) in [
            ("tmdb", ids.tmdb), ("tvdb", ids.tvdb), ("trakt", ids.trakt),
            ("anilist", ids.anilist), ("myanimelist", ids.myanimelist), ("anidb", ids.anidb)
        ] {
            guard let value else { continue }
            guard value > 0 else { throw TrackerHistoryError.invalidObservation }
            result.append(.external(source: prefix + source + suffix, value: String(value)))
        }
        if let imdb = ids.imdb {
            guard imdb.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil else {
                throw TrackerHistoryError.invalidObservation
            }
            result.append(.external(source: prefix + "imdb" + suffix, value: imdb))
        }
        return result
    }
}
