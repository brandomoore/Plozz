import CoreModels
import CoreNetworking
import Foundation

public struct WetrakrHistoryExportTarget: Codable, Hashable, Sendable {
    let userID: Int
    let mediaID: Int
    let kind: MediaItemKind
}

actor WetrakrHistoryExportAdapter {
    private let client: WetrakrClient
    private let reader = WetrakrHistoryReader(includesListStates: true)
    private var ownerID: Int?
    private var sources: [WetrakrHistoryExportTarget: MediaItem] = [:]

    init(client: WetrakrClient) { self.client = client }

    static func supports(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie: return lookupID(item, series: false) != nil
        case .episode:
            return lookupID(item, series: true) != nil
                && item.seasonNumber.map { $0 >= 0 } == true
                && item.episodeNumber.map { $0 > 0 } == true
                && (item.episodeNumberEnd == nil || item.episodeNumberEnd == item.episodeNumber)
                && [.imdb, .tmdb, .tvdb].contains { item.providerID($0) != nil }
        default: return false
        }
    }

    func snapshot(
        accessToken: String, connectionID: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        let owner = try await owner(accessToken, validateScope)
        let snapshot = try await reader.snapshot(
            client: client, accessToken: accessToken, connectionID: connectionID, validateScope: validateScope
        )
        guard try await self.owner(accessToken, validateScope) == owner else { throw TrackerHistoryError.scopeChanged }
        sources.removeAll(keepingCapacity: true)
        return snapshot
    }

    func resolve(
        _ item: MediaItem, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> WetrakrHistoryExportTarget {
        guard Self.supports(item), let (source, value) = Self.lookupID(item, series: item.kind == .episode) else {
            throw TrackerHistoryExportError.unsupported
        }
        let owner = try await owner(accessToken, validateScope)
        let expectedType = item.kind == .movie ? "movie" : "show"
        let resolved: WetrakrMedia = try await read(
            "/media/external/\(source)/\(value)", query: [.init(name: "type", value: expectedType)],
            token: accessToken, validate: validateScope
        )
        guard resolved.id > 0, resolved.type == expectedType else { throw TrackerHistoryExportError.unsupported }
        let mediaID: Int
        if item.kind == .episode, let season = item.seasonNumber, let episode = item.episodeNumber {
            let parent = try await detail(resolved.id, kind: .series, token: accessToken, validate: validateScope)
            try parent.requireParent(of: item)
            let child: WetrakrExportMedia = try await read(
                "/shows/\(resolved.id)/seasons/\(season)/episodes/\(episode)",
                token: accessToken, validate: validateScope
            )
            try child.requireMatch(item, parent: parent)
            mediaID = child.id
        } else {
            mediaID = resolved.id
        }
        let target = WetrakrHistoryExportTarget(userID: owner, mediaID: mediaID, kind: item.kind)
        _ = try await verifiedDetail(target, item: item, token: accessToken, validate: validateScope)
        guard try await self.owner(accessToken, validateScope) == owner else { throw TrackerHistoryError.scopeChanged }
        guard sources.count < 50 || sources[target] != nil else { throw TrackerHistoryError.invalidSelection }
        sources[target] = item
        return target
    }

    func state(
        _ target: WetrakrHistoryExportTarget, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistoryExportState {
        guard let item = sources[target],
              try await owner(accessToken, validateScope) == target.userID else {
            throw TrackerHistoryError.scopeChanged
        }
        let (media, parent) = try await verifiedDetail(target, item: item, token: accessToken, validate: validateScope)
        let page: WetrakrExportHistoryPage = try await read(
            "/\(target.kind == .movie ? "movies" : "episodes")/\(target.mediaID)/tracking/history",
            query: [.init(name: "page", value: "1")], token: accessToken, validate: validateScope
        )
        var observations = try page.observations(media: media, parent: parent, kind: target.kind)
        if let state = try media.listObservation(kind: target.kind, parent: parent) { observations.append(state) }
        if let parent, let state = try parent.listObservation(kind: .series, parent: nil),
           state.matchesHistoryExport(item) { observations.append(state) }
        guard try await owner(accessToken, validateScope) == target.userID else { throw TrackerHistoryError.scopeChanged }
        return try .init(observations: observations, isPlaying: media.interactions?.user?.tracking?.last?.status == "playing")
    }

    private func owner(_ token: String, _ validate: @escaping @Sendable () async throws -> Void) async throws -> Int {
        let user: WetrakrUser = try await read("/account/settings", token: token, validate: validate)
        guard user.id > 0 else { throw TrackerHistoryError.invalidObservation }
        guard ownerID == nil || ownerID == user.id else { throw TrackerHistoryError.scopeChanged }
        ownerID = user.id
        return user.id
    }

    private func verifiedDetail(
        _ target: WetrakrHistoryExportTarget, item: MediaItem, token: String,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws -> (WetrakrExportMedia, WetrakrExportMedia?) {
        let media = try await detail(target.mediaID, kind: target.kind, token: token, validate: validate)
        var parent: WetrakrExportMedia?
        if target.kind == .episode {
            guard let parentID = media.mediaID, parentID > 0 else { throw TrackerHistoryError.invalidObservation }
            parent = try await detail(parentID, kind: .series, token: token, validate: validate)
        }
        try media.requireMatch(item, parent: parent)
        return (media, parent)
    }

    private func detail(
        _ id: Int, kind: MediaItemKind, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> WetrakrExportMedia {
        guard id > 0, [.movie, .series, .episode].contains(kind) else { throw TrackerHistoryExportError.unsupported }
        let path = kind == .movie ? "movies" : kind == .series ? "shows" : "episodes"
        let media: WetrakrExportMedia = try await read(
            "/\(path)/\(id)", query: [.init(name: "extended", value: "interactions")], token: token, validate: validate
        )
        guard media.id == id, media.interactions?.user != nil else { throw TrackerHistoryError.incompleteSnapshot }
        return media
    }

    private func read<Value: Decodable & Sendable>(
        _ path: String, query: [URLQueryItem] = [], token: String,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        var endpoint = Endpoint(path: path, queryItems: query)
        endpoint.maximumResponseBytes = 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        let (data, response) = try await client.send(
            endpoint, accessToken: token, operation: .historyRead, validateScope: validate
        )
        guard response.statusCode == 200, data.count <= 1_024 * 1_024 else { throw TrackerHistoryError.incompleteSnapshot }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch {
            PlozzLog.networking.error("WeTrakr export evidence could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
    }

    private static func lookupID(_ item: MediaItem, series: Bool) -> (String, String)? {
        for (name, key) in [
            ("imdb", series ? ProviderIDNamespace.seriesImdb : .imdb),
            ("tmdb", series ? .seriesTmdb : .tmdb),
            ("tvdb", series ? .seriesTvdb : .tvdb)
        ] {
            guard let value = item.providerID(key) else { continue }
            if name == "imdb" {
                if value.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil { return (name, value) }
            } else if let id = Int(value), id > 0 { return (name, String(id)) }
        }
        return nil
    }
}

private struct WetrakrExportMedia: Decodable, Sendable {
    struct Interactions: Decodable, Sendable {
        struct User: Decodable, Sendable {
            struct Tracking: Decodable, Sendable {
                struct Last: Decodable, Sendable { let status: String }
                let last: Last?
            }
            let tracking: Tracking?
        }
        let user: User?
    }
    let id: Int
    let type: String?
    let ids: WetrakrIDs?
    let mediaID: Int?
    let season: Int?
    let episode: Int?
    let interactions: Interactions?
    enum CodingKeys: String, CodingKey {
        case id, type, ids, interactions, mediaID = "media_id", season = "season_number", episode = "number"
    }

    func requireParent(of item: MediaItem) throws {
        let identities = try WetrakrHistoryRecord.identities(nativeID: id, ids: ids)
        let source = MediaItemIdentity.seriesIdentities(for: item)
        guard id > 0, type == "show", !Set(identities).isDisjoint(with: source),
              !MediaItemIdentity.externalIdentitiesConflict(identities, source) else {
            throw TrackerHistoryExportError.unsupported
        }
    }

    func requireMatch(_ item: MediaItem, parent: Self?) throws {
        guard id > 0 else { throw TrackerHistoryError.invalidObservation }
        if item.kind == .episode {
            guard type == "episode", let parent, mediaID == parent.id else {
                throw TrackerHistoryExportError.unsupported
            }
            try parent.requireParent(of: item)
        } else {
            guard item.kind == .movie, type == "movie", mediaID == nil, season == nil, episode == nil else {
                throw TrackerHistoryExportError.unsupported
            }
        }
        guard try TrackerHistoryObservation.matches(
            item, kind: item.kind, identities: identities(kind: item.kind, parent: parent),
            season: season, episode: episode, requiresExactEpisodeIdentity: item.kind == .episode
        ) else { throw TrackerHistoryExportError.unsupported }
    }

    func identities(kind: MediaItemKind, parent: Self?) throws -> [MediaIdentity] {
        if kind == .episode {
            guard let season, season >= 0, let episode, episode > 0, let parent else {
                throw TrackerHistoryError.invalidObservation
            }
            let suffix = ":s\(season)e\(episode)"
            return try WetrakrHistoryRecord.identities(nativeID: id, ids: ids, suffix: suffix)
                + WetrakrHistoryRecord.identities(nativeID: parent.id, ids: parent.ids, prefix: "series-", suffix: suffix)
        }
        return try WetrakrHistoryRecord.identities(nativeID: id, ids: ids)
    }

    func listObservation(kind: MediaItemKind, parent: Self?) throws -> TrackerHistoryObservation? {
        guard let user = interactions?.user else { throw TrackerHistoryError.incompleteSnapshot }
        guard let tracking = user.tracking else { return nil }
        guard let status = tracking.last?.status else { throw TrackerHistoryError.incompleteSnapshot }
        if status == "none" { return nil }
        let state = status == "playing" ? TrackerHistoryListState.watching : WetrakrHistoryRecord.listState(status)
        guard let state else { throw TrackerHistoryError.invalidObservation }
        return try .init(
            recordID: "state/\(kind == .series ? "show" : kind == .movie ? "movie" : "episode")/\(id)",
            kind: kind, identities: identities(kind: kind, parent: parent),
            season: season, episode: episode, requiresExactEpisodeIdentity: kind == .episode,
            fact: .listState(state)
        )
    }
}

private struct WetrakrExportHistoryPage: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        struct Play: Decodable, Sendable {
            let id: String
            let target: String
            let status: String
            let trackedAt: String
            let unknown: Bool?
            enum CodingKeys: String, CodingKey {
                case id = "_track_log_id", target, status, trackedAt = "tracked_at", unknown = "tracked_at_unknown"
            }
        }
        let tracks: [Play]
    }
    struct Meta: Decodable, Sendable { let page: Int; let limit: Int; let total: Int; let totalPages: Int }
    let data: [Group]
    let meta: Meta

    func observations(
        media: WetrakrExportMedia, parent: WetrakrExportMedia?, kind: MediaItemKind
    ) throws -> [TrackerHistoryObservation] {
        guard meta.page == 1, (1...100).contains(meta.limit), meta.total >= 0, meta.totalPages >= 0 else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        let plays = data.flatMap(\.tracks)
        if plays.isEmpty {
            guard data.isEmpty, meta.total == 0, meta.totalPages <= 1 else { throw TrackerHistoryError.incompleteSnapshot }
            return []
        }
        // One valid play proves presence; only an explicitly empty complete result proves absence.
        guard meta.total > 0, meta.totalPages > 0, plays.count <= 5_000,
              Set(plays.map(\.id)).count == plays.count else { throw TrackerHistoryError.incompleteSnapshot }
        return try plays.map {
            guard !$0.id.isEmpty, $0.status == "watched", $0.target == (kind == .movie ? "movie" : "episode") else {
                throw TrackerHistoryError.invalidObservation
            }
            let date = try WetrakrDate.parse($0.trackedAt)
            return try .init(
                recordID: "watched/\($0.id)", kind: kind, identities: media.identities(kind: kind, parent: parent),
                season: media.season, episode: media.episode, requiresExactEpisodeIdentity: kind == .episode,
                fact: .watched(at: $0.unknown == true ? nil : date)
            )
        }
    }
}

private struct WetrakrExportAcknowledgement: Decodable {
    struct Added: Decodable {
        struct Play: Decodable {
            let type: String
            let id: Int
            let playID: String
            let watchedAt: String
            enum CodingKeys: String, CodingKey { case type, id, playID = "play_id", watchedAt = "watched_at" }
        }
        let plays: [Play]?
    }
    let added: Added?
    let notFound: [String: [WetrakrTrackingResult.Failure]]?
    let errored: [String: [WetrakrTrackingResult.Failure]]?
}

extension WetrakrClient {
    func exportHistory(
        _ target: WetrakrHistoryExportTarget, date: Date?, idempotencyKey: String, accessToken: String,
        authorize: @escaping @Sendable () async throws -> Void,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard target.userID > 0, target.mediaID > 0, [.movie, .episode].contains(target.kind),
              !idempotencyKey.isEmpty,
              date.map({ $0.timeIntervalSince1970.isFinite && $0 <= Date() }) ?? true else {
            throw TrackerHistoryExportError.notWritten(.invalidResponse)
        }
        let item = WetrakrTrackingBody.Item(
            id: target.mediaID, status: "watched", trackedAt: date.map(WetrakrDate.string),
            trackedAtUnknown: date == nil ? true : nil
        )
        let body = WetrakrTrackingBody(
            movies: target.kind == .movie ? [item] : nil,
            episodes: target.kind == .episode ? [item] : nil, allowRewatch: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var endpoint = try Endpoint(method: .post, path: "/sync/tracking", headers: ["Idempotency-Key": idempotencyKey])
            .jsonBody(body, encoder: encoder)
        endpoint.maximumResponseBytes = 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        endpoint.reportsUndeliveredRequests = true
        try Task.checkCancellation()
        // Full authorization reads use the same serial gate. Never run them while holding it.
        try await authorize()
        do {
            let (request, clientID) = try prepare(endpoint, accessToken: accessToken)
            let data: Data = try await gate.run(clientID: clientID, accessToken: accessToken, request: .historyWrite) {
                do {
                    try Task.checkCancellation()
                    try await validateScope()
                } catch {
                    throw TrackerHistoryExportError.notWritten(error is CancellationError ? .cancelled : .conflict)
                }
                let data: Data
                let response: HTTPURLResponse
                do { (data, response) = try await http.sendRaw(request, baseURL: config.apiBaseURL) }
                catch let error as HTTPRequestNotSentError { throw TrackerHistoryExportError.notWritten(error.underlying) }
                catch { throw TrackerHistoryExportError.uncertainWrite }
                let failure = response.statusCode >= 400 ? try? JSONDecoder().decode(ErrorResponse.self, from: data) : nil
                let delay = await gate.received(
                    response, code: failure?.error, clientID: clientID, accessToken: accessToken, request: .historyWrite
                )
                switch response.statusCode {
                case 401: throw TrackerHistoryExportError.notWritten(.unauthorized)
                case 403, 418, 423: throw TrackerHistoryExportError.notWritten(.accessRestricted)
                case 429: throw TrackerHistoryExportError.notWritten(.rateLimited(retryAfter: delay))
                case 200: return data
                default: throw TrackerHistoryExportError.uncertainWrite
                }
            }
            let result: WetrakrExportAcknowledgement
            do { result = try JSONDecoder().decode(WetrakrExportAcknowledgement.self, from: data) }
            catch {
                PlozzLog.networking.error("WeTrakr export acknowledgement could not be interpreted safely")
                throw TrackerHistoryExportError.uncertainWrite
            }
            guard data.count <= 1_024 * 1_024, result.notFound?.values.allSatisfy(\.isEmpty) ?? true,
                  result.errored?.values.allSatisfy(\.isEmpty) ?? true,
                  let plays = result.added?.plays, plays.count == 1, let play = plays.first,
                  play.id == target.mediaID, play.type == (target.kind == .movie ? "movie" : "episode"),
                  !play.playID.isEmpty, (try? WetrakrDate.parse(play.watchedAt)) != nil else {
                throw TrackerHistoryExportError.uncertainWrite
            }
        } catch let error as TrackerHistoryExportError { throw error }
        catch let error as AppError { throw TrackerHistoryExportError.notWritten(error) }
        catch is CancellationError { throw TrackerHistoryExportError.notWritten(.cancelled) }
        catch { throw TrackerHistoryExportError.notWritten(.invalidResponse) }
    }
}
