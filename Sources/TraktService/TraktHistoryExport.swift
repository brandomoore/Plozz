import CoreModels
import CoreNetworking
import Foundation

public struct TraktHistoryExportTarget: Codable, Hashable, Sendable {
    let userID: String
    let mediaID: Int
    let kind: MediaItemKind
}

@MainActor
final class TraktHistoryExportAdapter {
    private let client: TraktClient
    private var ownerID: String?
    private var sources: [TraktHistoryExportTarget: MediaItem] = [:]
    private var protectionCache: (TraktExportActivity, [TrackerHistoryObservation])?

    init(client: TraktClient) { self.client = client }

    static func supports(_ item: MediaItem) -> Bool {
        guard item.kind == .movie || item.kind == .episode,
            let date = item.lastPlayedAt, date.timeIntervalSince1970.isFinite, date <= Date(),
            (item.resumePosition ?? 0) <= 0, lookupID(item) != nil
        else { return false }
        return item.kind == .movie || !MediaItemIdentity.seriesIdentities(for: item).isEmpty
    }

    func snapshot(
        token: String, connectionID: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        let owner = try await owner(token, validate)
        let before: TraktExportActivity = try await read("/sync/last_activities", token: token, validate: validate)
        try before.requireValid()
        let watches: [TraktHistoryRecord] = try await pages("/users/me/history", token: token, validate: validate)
        var observations = try watches.map { try $0.exportProtection() }
        observations += try await protection(before, token: token, validate: validate)
        if let current = try await watching(token: token, validate: validate) { observations.append(current) }
        try await finish(before, owner: owner, token: token, validate: validate)
        sources.removeAll(keepingCapacity: true)
        return try .init(
            trackerID: "trakt", connectionID: connectionID, observations: observations,
            completeness: .completeResponse
        )
    }

    func resolve(
        _ item: MediaItem, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> TraktHistoryExportTarget {
        guard Self.supports(item) else { throw TrackerHistoryExportError.unsupported }
        let owner = try await owner(token, validate)
        let media = try await metadata(item, validate: validate)
        guard try await self.owner(token, validate) == owner else { throw TrackerHistoryError.scopeChanged }
        let target = TraktHistoryExportTarget(userID: owner, mediaID: media.id, kind: item.kind)
        guard sources.count < 50 || sources[target] != nil else { throw TrackerHistoryError.invalidSelection }
        sources[target] = item
        return target
    }

    func state(
        _ target: TraktHistoryExportTarget, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistoryExportState {
        guard let item = sources[target], try await owner(token, validate) == target.userID else {
            throw TrackerHistoryError.scopeChanged
        }
        let media = try await metadata(item, validate: validate)
        guard media.id == target.mediaID, item.kind == target.kind else { throw TrackerHistoryError.scopeChanged }
        let before: TraktExportActivity = try await read("/sync/last_activities", token: token, validate: validate)
        try before.requireValid()
        let kind = target.kind == .movie ? "movies" : "episodes"
        let records: [TraktHistoryRecord] = try await pages(
            "/users/me/history/\(kind)/\(target.mediaID)", token: token, validate: validate
        )
        let watches = try records.map { record in
            let watch = try record.exportProtection()
            let id = target.kind == .movie ? record.movie?.ids.trakt : record.episode?.ids.trakt
            guard id == target.mediaID, watch.matchesHistoryExport(item) else {
                throw TrackerHistoryError.invalidObservation
            }
            return watch
        }
        let protected = try await protection(before, token: token, validate: validate)
        let current = try await watching(token: token, validate: validate)
        try await finish(before, owner: target.userID, token: token, validate: validate)
        return try .init(
            observations: watches + protected.filter { $0.matchesHistoryExport(item) },
            isPlaying: current?.matchesHistoryExport(item) == true
        )
    }

    private func protection(
        _ activity: TraktExportActivity, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> [TrackerHistoryObservation] {
        if let protectionCache, protectionCache.0 == activity { return protectionCache.1 }
        let movies: [TraktWatchlistMovieEntry] = try await pages(
            "/sync/watchlist/movies/added/desc", token: token, validate: validate
        )
        let shows: [TraktWatchlistShowEntry] = try await pages(
            "/sync/watchlist/shows/added/desc", token: token, validate: validate
        )
        let seasons: [TraktExportWatchlistEntry] = try await pages(
            "/sync/watchlist/seasons/added/desc", token: token, validate: validate
        )
        let episodes: [TraktExportWatchlistEntry] = try await pages(
            "/sync/watchlist/episodes/added/desc", token: token, validate: validate
        )
        let paused: [TraktHistoryRecord] = try await pages("/sync/playback", token: token, validate: validate)
        let lists =
            movies.map { ($0.id, $0.listedAt, $0.movie, MediaItemKind.movie) }
            + shows.map { ($0.id, $0.listedAt, $0.show, MediaItemKind.series) }
        let result =
            try lists.map { id, listed, media, kind in
                guard id > 0, TraktClient.parseTimestamp(listed) != nil else {
                    throw TrackerHistoryError.invalidObservation
                }
                let ids = TraktIDs(
                    trakt: media.ids.trakt, imdb: media.ids.imdb, tmdb: media.ids.tmdb, tvdb: media.ids.tvdb)
                return try TrackerHistoryObservation(
                    recordID: "watchlist/\(kind.rawValue)/\(id)", kind: kind,
                    identities: ids.historyIdentities(), fact: .listState(.planning)
                )
            } + seasons.map { try $0.observation(expectedType: "season") }
            + episodes.map { try $0.observation(expectedType: "episode") }
            + paused.map { try $0.observation(playback: true) }
        let after: TraktExportActivity = try await read("/sync/last_activities", token: token, validate: validate)
        guard after == activity else { throw TrackerHistoryError.incompleteSnapshot }
        protectionCache = (activity, result)
        return result
    }

    private func watching(
        token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistoryObservation? {
        let (data, response) = try await response("/users/me/watching", token: token, validate: validate)
        if response.statusCode == 204 {
            guard data.isEmpty else { throw TrackerHistoryError.invalidObservation }
            return nil
        }
        guard response.statusCode == 200 else { throw client.oauthError(data: data, response: response) }
        let media = try decode(TraktExportMedia.self, data)
        guard let started = media.startedAt.flatMap(TraktClient.parseTimestamp),
            let expires = media.expiresAt.flatMap(TraktClient.parseTimestamp), expires > started,
            let action = media.action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TrackerHistoryError.invalidObservation
        }
        return try media.observation(fact: .listState(.watching), prefix: "watching")
    }

    private func metadata(
        _ item: MediaItem, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> TraktExportMedia {
        guard let lookup = Self.lookupID(item) else { throw TrackerHistoryExportError.unsupported }
        let matches: [TraktExportMedia] = try await client.paginatedGET(
            path: "/search/\(lookup.0)/\(lookup.1)", accessToken: nil, requiresCompleteEvidence: true,
            query: [.init(name: "type", value: item.kind == .movie ? "movie" : "episode")],
            maximumResponseBytes: 8 * 1_024 * 1_024, validateScope: validate
        )
        guard matches.count == 1, let media = matches.first else { throw TrackerHistoryExportError.unsupported }
        try media.requireMatch(item)
        let canonical: TraktExportMedia
        if item.kind == .movie {
            let movie: TraktMovieRef = try await read("/movies/\(media.id)", token: nil, validate: validate)
            canonical = .init(type: "movie", movie: movie)
        } else {
            guard let showID = media.show?.ids.trakt, showID > 0,
                let season = media.episode?.season, season >= 0,
                let episode = media.episode?.number, episode > 0
            else { throw TrackerHistoryExportError.unsupported }
            let show: TraktShowRef = try await read("/shows/\(showID)", token: nil, validate: validate)
            let detail: TraktEpisodeRef = try await read(
                "/shows/\(showID)/seasons/\(season)/episodes/\(episode)", token: nil, validate: validate
            )
            guard show.ids.trakt == showID else { throw TrackerHistoryExportError.unsupported }
            canonical = .init(type: "episode", show: show, episode: detail)
        }
        guard canonical.id == media.id else { throw TrackerHistoryExportError.unsupported }
        try canonical.requireMatch(item)
        return canonical
    }

    private func owner(_ token: String, _ validate: @escaping @Sendable () async throws -> Void) async throws -> String
    {
        struct Settings: Decodable {
            struct User: Decodable {
                struct IDs: Decodable { let uuid: String }
                let ids: IDs
            }
            let user: User
        }
        let settings: Settings = try await read("/users/settings", token: token, validate: validate)
        let id = settings.user.ids.uuid
        guard !id.isEmpty, id.utf8.count <= 256 else { throw TrackerHistoryError.invalidObservation }
        guard ownerID == nil || ownerID == id else { throw TrackerHistoryError.scopeChanged }
        ownerID = id
        return id
    }

    private func finish(
        _ before: TraktExportActivity, owner: String, token: String,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws {
        let after: TraktExportActivity = try await read("/sync/last_activities", token: token, validate: validate)
        guard before == after else { throw TrackerHistoryError.incompleteSnapshot }
        guard try await self.owner(token, validate) == owner else { throw TrackerHistoryError.scopeChanged }
    }

    private func pages<Value: Decodable & TraktPageIdentifiable>(
        _ path: String, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> [Value] {
        try await client.paginatedGET(
            path: path, accessToken: token, requiresCompleteEvidence: true,
            maximumResponseBytes: 8 * 1_024 * 1_024, validateScope: validate
        )
    }

    private func response(
        _ path: String, token: String?, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        guard client.config.isConfigured else { throw AppError.unauthorized }
        try Task.checkCancellation()
        try await validate()
        var request = Endpoint(path: path, headers: client.headers(accessToken: token), redirectPolicy: .sameOrigin)
        request.maximumResponseBytes = 1_024 * 1_024
        request.redactsURLForLogging = true
        let result = try await client.http.sendRaw(request, baseURL: client.config.apiBaseURL)
        try Task.checkCancellation()
        try await validate()
        guard result.0.count <= 1_024 * 1_024 else { throw TrackerHistoryError.incompleteSnapshot }
        return result
    }

    private func read<Value: Decodable>(
        _ path: String, token: String?, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> Value {
        let (data, response) = try await response(path, token: token, validate: validate)
        guard response.statusCode == 200 else { throw client.oauthError(data: data, response: response) }
        return try decode(Value.self, data)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            PlozzLog.networking.error("Trakt export evidence could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
    }

    private static func lookupID(_ item: MediaItem) -> (String, String)? {
        let namespaces: [ProviderIDNamespace] = item.kind == .episode ? [.tvdb, .imdb, .tmdb] : [.imdb, .tmdb]
        for namespace in namespaces {
            guard let value = item.providerID(namespace) else { continue }
            if namespace == .imdb {
                if value.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil { return ("imdb", value) }
            } else if let id = Int(value), id > 0 {
                return (namespace.rawValue, String(id))
            }
        }
        return nil
    }
}

private struct TraktExportWatchlistEntry: Decodable, Sendable, TraktPageIdentifiable {
    struct Season: Decodable, Sendable { let number: Int; let ids: TraktIDs }
    let id: Int
    let type: String
    let listedAt: String
    let show: TraktShowRef?
    let episode: TraktEpisodeRef?
    let season: Season?
    enum CodingKeys: String, CodingKey { case id, type, show, episode, season, listedAt = "listed_at" }

    func observation(expectedType: String) throws -> TrackerHistoryObservation {
        guard id > 0, type == expectedType, TraktClient.parseTimestamp(listedAt) != nil else {
            throw TrackerHistoryError.invalidObservation
        }
        let recordID = "watchlist/\(type)/\(id)"
        if type == "season" {
            guard let show, let season, episode == nil, season.number >= 0,
                  let seasonID = season.ids.trakt, seasonID > 0 else { throw TrackerHistoryError.invalidObservation }
            return try .init(
                recordID: recordID, kind: .series, identities: show.ids.historyIdentities(),
                season: season.number, fact: .listState(.planning)
            )
        }
        guard season == nil else { throw TrackerHistoryError.invalidObservation }
        return try TraktHistoryRecord(
            id: id, type: type, movie: nil, show: show, episode: episode,
            watchedAt: nil, action: nil, pausedAt: nil, progress: nil
        ).observation(fact: .listState(.planning), recordID: recordID)
    }
}

private struct TraktExportActivity: Decodable, Equatable, Sendable {
    struct Watchlist: Decodable, Equatable, Sendable {
        let updatedAt: String
        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
    }
    let all: String
    let movies: TraktHistoryActivity.MediaActivity
    let episodes: TraktHistoryActivity.MediaActivity
    let watchlist: Watchlist

    func requireValid() throws {
        guard
            [all, movies.watchedAt, movies.pausedAt, episodes.watchedAt, episodes.pausedAt, watchlist.updatedAt]
                .allSatisfy({ TraktClient.parseTimestamp($0) != nil })
        else { throw TrackerHistoryError.incompleteSnapshot }
    }
}

private struct TraktExportMedia: Decodable, Sendable, TraktPageIdentifiable {
    let type: String
    var movie: TraktMovieRef?
    var show: TraktShowRef?
    var episode: TraktEpisodeRef?
    var startedAt: String?
    var expiresAt: String?
    var action: String?
    enum CodingKeys: String, CodingKey {
        case type, movie, show, episode, action
        case startedAt = "started_at"
        case expiresAt = "expires_at"
    }
    var id: Int { type == "movie" ? movie?.ids.trakt ?? 0 : episode?.ids.trakt ?? 0 }

    func observation(fact: TrackerHistoryObservation.Fact, prefix: String) throws -> TrackerHistoryObservation {
        try TraktHistoryRecord(
            id: id, type: type, movie: movie, show: show, episode: episode,
            watchedAt: nil, action: nil, pausedAt: nil, progress: nil
        ).observation(fact: fact, recordID: "\(prefix)/\(type)/\(id)")
    }

    func requireMatch(_ item: MediaItem) throws {
        let proof = try observation(fact: .listState(.planning), prefix: "metadata")
        guard proof.kind == item.kind, proof.matchesHistoryExport(item) else {
            throw TrackerHistoryExportError.unsupported
        }
    }
}

actor TraktHistoryExportGate {
    static let shared = TraktHistoryExportGate(defaults: .standard)
    private let limiter = ConcurrencyLimiter(limit: 1)
    private let defaults: UserDefaults?
    private static let cooldownKey = "trakt.historyExportCooldown"
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextRequest: Date?
    private var blockedUntil: Date?

    init(
        defaults: UserDefaults? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
        if let stored = defaults?.object(forKey: Self.cooldownKey) {
            if let date = stored as? Date, date.timeIntervalSince1970.isFinite {
                blockedUntil = min(date, now().addingTimeInterval(90_000))
            } else {
                PlozzLog.networking.error("Trakt export cooldown was invalid")
            }
        }
    }

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await limiter.runUnlessCancelled {
            try await self.wait()
            do {
                try await operation()
                await self.completed()
            } catch {
                if case .notWritten(.rateLimited(let retry)) = error as? TrackerHistoryExportError {
                    await self.block(retry ?? 60)
                }
                await self.completed()
                throw error
            }
        }
    }

    private func wait() async throws {
        try requireQuota()
        if let nextRequest {
            let delay = nextRequest.timeIntervalSince(now())
            if delay > 0 { try await sleep(delay) }
        }
        try Task.checkCancellation()
        try requireQuota()
    }

    private func completed() { nextRequest = now().addingTimeInterval(1.01) }

    private func requireQuota() throws {
        if let blockedUntil, blockedUntil > now() {
            throw AppError.rateLimited(retryAfter: blockedUntil.timeIntervalSince(now()))
        }
    }

    private func block(_ delay: TimeInterval) {
        let bounded = delay.isFinite && delay >= 0 ? min(90_000, max(1, delay)) : 60
        blockedUntil = max(blockedUntil ?? .distantPast, now().addingTimeInterval(bounded))
        defaults?.set(blockedUntil, forKey: Self.cooldownKey)
    }
}

private struct TraktExportAcknowledgement: Decodable {
    struct Failure: Decodable { let ids: TraktIDs? }
    let added: [String: Int]
    let updated: [String: Int]
    let notFound: [String: [Failure]]
    enum CodingKeys: String, CodingKey {
        case added, updated
        case notFound = "not_found"
    }
}

extension TraktClient {
    func exportHistory(
        _ target: TraktHistoryExportTarget, date: Date?,
        gate: TraktHistoryExportGate = .shared,
        accessToken: @escaping @Sendable () async throws -> String,
        authorize: @escaping @Sendable () async throws -> Void,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard config.isConfigured, !target.userID.isEmpty, target.mediaID > 0,
            target.kind == .movie || target.kind == .episode,
            let date, date.timeIntervalSince1970.isFinite, date <= Date()
        else {
            throw TrackerHistoryExportError.notWritten(.invalidResponse)
        }
        struct Entry: Encodable, Sendable {
            let ids: TraktIDs
            let watchedAt: String
            enum CodingKeys: String, CodingKey {
                case ids
                case watchedAt = "watched_at"
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let kind = target.kind == .movie ? "movies" : "episodes"
        let body = [kind: [Entry(ids: .init(trakt: target.mediaID), watchedAt: formatter.string(from: date))]]
        do {
            try await gate.run {
                let token: String
                do {
                    try await authorize()
                    token = try await accessToken()
                    try await validate()
                    try Task.checkCancellation()
                } catch {
                    throw TrackerHistoryExportError.notWritten(
                        error is CancellationError ? .cancelled : (error as? AppError ?? .conflict)
                    )
                }
                var request = try Endpoint(
                    method: .post, path: "/sync/history", headers: headers(accessToken: token),
                    redirectPolicy: .doNotFollow
                ).jsonBody(body)
                request.maximumResponseBytes = 1_024 * 1_024
                request.reportsUndeliveredRequests = true
                request.redactsURLForLogging = true
                let data: Data
                let response: HTTPURLResponse
                do {
                    (data, response) = try await http.sendRaw(request, baseURL: config.apiBaseURL)
                } catch let error as HTTPRequestNotSentError {
                    throw TrackerHistoryExportError.notWritten(error.underlying)
                } catch {
                    throw TrackerHistoryExportError.uncertainWrite
                }
                switch response.statusCode {
                case 200: break
                case 401, 403, 429:
                    throw TrackerHistoryExportError.notWritten(oauthError(data: data, response: response))
                default: throw TrackerHistoryExportError.uncertainWrite
                }
                guard data.count <= 1_024 * 1_024 else { throw TrackerHistoryExportError.uncertainWrite }
                let result: TraktExportAcknowledgement
                do { result = try JSONDecoder().decode(TraktExportAcknowledgement.self, from: data) } catch {
                    PlozzLog.networking.error("Trakt export acknowledgement could not be interpreted safely")
                    throw TrackerHistoryExportError.uncertainWrite
                }
                guard result.added == ["movies": target.kind == .movie ? 1 : 0, "episodes": target.kind == .episode ? 1 : 0],
                    result.updated == ["movies": 0, "episodes": 0],
                    Set(result.notFound.keys) == ["movies", "shows", "seasons", "episodes"],
                    result.notFound.values.allSatisfy(\.isEmpty)
                else { throw TrackerHistoryExportError.uncertainWrite }
            }
        } catch is CancellationError {
            throw TrackerHistoryExportError.notWritten(.cancelled)
        } catch let error as AppError {
            throw TrackerHistoryExportError.notWritten(error)
        }
    }
}
