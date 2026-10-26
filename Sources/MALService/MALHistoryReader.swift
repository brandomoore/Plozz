import CoreModels
import CoreNetworking
import Foundation

extension MALClient {
    func historySnapshot(
        accessToken: String, connectionID: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        let owner: MALHistoryOwner = try await historyRead(
            path: "/users/@me", accessToken: accessToken, validateScope: validateScope
        )
        guard owner.id > 0 else { throw TrackerHistoryError.invalidObservation }
        var observations: [TrackerHistoryObservation] = []
        var seenIDs = Set<Int>()
        var offset = 0
        var previousUpdate: Date?
        for _ in 0..<100 {
            let page: MALHistoryPage = try await historyRead(
                path: "/users/@me/animelist",
                query: [
                    .init(name: "limit", value: "1000"), .init(name: "offset", value: String(offset)),
                    .init(name: "sort", value: "list_updated_at"), .init(name: "nsfw", value: "true"),
                    .init(name: "fields", value:
                        "id,title,media_type,list_status{status,score,num_episodes_watched,is_rewatching,num_times_rewatched,updated_at}")
                ],
                accessToken: accessToken, validateScope: validateScope
            )
            guard page.data.count <= 1_000 else { throw TrackerHistoryError.incompleteSnapshot }
            for entry in page.data {
                guard seenIDs.insert(entry.node.id).inserted else { throw TrackerHistoryError.incompleteSnapshot }
                let observation = try entry.observation()
                if case .animeList(let progress) = observation.fact, let updated = progress.updatedAt {
                    guard previousUpdate.map({ updated <= $0 }) ?? true else { throw TrackerHistoryError.incompleteSnapshot }
                    previousUpdate = updated
                }
                observations.append(observation)
            }
            guard let next = page.paging.next else {
                let current: MALHistoryOwner = try await historyRead(
                    path: "/users/@me", accessToken: accessToken, validateScope: validateScope
                )
                guard current.id == owner.id else { throw TrackerHistoryError.scopeChanged }
                return try .init(
                    trackerID: "myanimelist", connectionID: connectionID,
                    observations: observations, completeness: .exhaustedPagination
                )
            }
            guard !page.data.isEmpty else { throw TrackerHistoryError.incompleteSnapshot }
            offset = try historyOffset(next, expected: offset + page.data.count)
        }
        throw TrackerHistoryError.incompleteSnapshot
    }

    func historyRead<Value: Decodable>(
        path: String, query: [URLQueryItem] = [], accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        try await validateScope()
        var endpoint = Endpoint(
            method: .get, path: path, queryItems: query,
            headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"],
            redirectPolicy: .sameOrigin
        )
        endpoint.maximumResponseBytes = 8 * 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        let (data, response) = try await http.send(endpoint, baseURL: config.apiBaseURL)
        try Task.checkCancellation()
        try await validateScope()
        guard response.statusCode == 200, data.count <= 8 * 1_024 * 1_024 else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch {
            PlozzLog.networking.error("MyAnimeList history response could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
    }

    private func historyOffset(_ next: String, expected: Int) throws -> Int {
        let base = config.apiBaseURL
        guard let url = URLComponents(string: next),
              url.scheme == base.scheme, url.host == base.host,
              url.port == base.port, url.user == nil, url.password == nil, url.fragment == nil,
              url.path == base.appendingPathComponent("users/@me/animelist").path,
              let items = url.queryItems else { throw TrackerHistoryError.incompleteSnapshot }
        let offsets = items.filter { $0.name == "offset" }
        guard offsets.count == 1, let raw = offsets.first?.value,
              raw == String(expected) else { throw TrackerHistoryError.incompleteSnapshot }
        // Only the checked offset is reused. Credentials never follow the supplied URL.
        return expected
    }
}

struct MALHistoryOwner: Decodable { let id: Int }

private struct MALHistoryPage: Decodable {
    struct Paging: Decodable { let next: String? }
    let data: [MALHistoryEntry]
    let paging: Paging
}

struct MALHistoryEntry: Decodable {
    struct Node: Decodable {
        let id: Int
        let title: String?
        let media_type: String?
    }
    struct Status: Decodable {
        let status: String?
        let score: Int?
        let num_episodes_watched: Int?
        let num_watched_episodes: Int?
        let is_rewatching: Bool?
        let num_times_rewatched: Int?
        let updated_at: String?
    }
    let node: Node
    let list_status: Status

    func observation() throws -> TrackerHistoryObservation {
        guard node.id > 0 else { throw TrackerHistoryError.invalidObservation }
        let status: TrackerAnimeListProgress.Status?
        switch list_status.status {
        case "watching": status = .watching
        case "completed": status = .completed
        case "on_hold": status = .paused
        case "dropped": status = .dropped
        case "plan_to_watch": status = .planning
        case nil: status = nil
        default: throw TrackerHistoryError.invalidObservation
        }
        guard status != .completed || list_status.is_rewatching != nil else {
            throw TrackerHistoryError.invalidObservation
        }
        let count = list_status.num_episodes_watched
        let alias = list_status.num_watched_episodes
        guard count == nil || alias == nil || count == alias else { throw TrackerHistoryError.invalidObservation }
        let updated: Date?
        if let raw = list_status.updated_at {
            guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw))
                ?? (try? Date.ISO8601FormatStyle().parse(raw)) else {
                throw TrackerHistoryError.invalidObservation
            }
            updated = date
        } else { updated = nil }
        return try .init(
            recordID: "list/\(node.id)", kind: node.media_type == "movie" ? .movie : .series,
            identities: [.external(source: "myanimelist", value: String(node.id))], sourceTitle: node.title,
            fact: .animeList(try .init(
                status: list_status.is_rewatching == true ? .rewatching : status,
                episodesWatched: count ?? alias, repeats: list_status.num_times_rewatched,
                score: list_status.score.map(Double.init), updatedAt: updated
            ))
        )
    }
}
