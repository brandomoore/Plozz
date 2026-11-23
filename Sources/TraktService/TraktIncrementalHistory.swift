import CoreModels
import CoreNetworking
import Foundation

extension TraktClient {
    func refreshedRecords(
        _ group: TraktHistoryGroup, prior: TraktHistoryCache.Entry?, revision: String, token: String,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws -> [TraktHistoryRecord] {
        let type = group.movies ? "movies" : "episodes"
        let path = group.playback ? "/sync/playback/\(type)" : "/users/me/history/\(type)"
        func category() async throws -> [TraktHistoryRecord] {
            try await paginatedGET(path: path, accessToken: token, requiresCompleteEvidence: true, validateScope: validate)
        }
        // Playback has no deletion cursor. Replace the affected current list,
        // never infer deletion or a backdated watch from a watch-date window.
        guard !group.playback, let prior, !prior.records.isEmpty,
              let watermark = Self.parseTimestamp(prior.stamp), let now = Self.parseTimestamp(revision), now > watermark else {
            return try await category()
        }
        let byTitle = Dictionary(grouping: prior.records) { group.movies ? $0.movie?.ids.trakt : $0.show?.ids.trakt }
        guard byTitle[nil] == nil else { return try await category() }
        let rows = try await watchedTitles(movies: group.movies, token: token, validate: validate)
        var result: [TraktHistoryRecord] = []
        var changed: [(Int, Int)] = []
        var seen = Set<Int>()
        var total = 0
        for row in rows {
            guard let id = row.titleID(movies: group.movies), id > 0, seen.insert(id).inserted,
                  (1...100_000).contains(row.plays), total <= 100_000 - row.plays,
                  let updated = Self.parseTimestamp(row.lastUpdatedAt) else {
                throw TraktHistoryDiagnostics.incomplete("watches", "title-summary")
            }
            total += row.plays
            if let previous = byTitle[id], previous.count == row.plays, updated < watermark {
                result.append(contentsOf: previous)
            } else {
                changed.append((id, row.plays))
            }
        }
        // Don't issue thousands of per-title GETs after a bulk edit. One title
        // always stays targeted; otherwise choose the cheaper paginated read.
        let limit = historyRead == nil ? 100 : 250
        if changed.reduce(0, { $0 + ($1.1 + limit - 1) / limit }) > (total + limit - 1) / limit {
            return try await category()
        }
        for (id, plays) in changed {
            let records: [TraktHistoryRecord] = try await paginatedGET(
                path: "/users/me/history/\(group.movies ? "movies" : "shows")/\(id)", accessToken: token,
                requiresCompleteEvidence: true, validateScope: validate
            )
            guard records.count == plays, records.allSatisfy({
                $0.type == group.type && (group.movies ? $0.movie?.ids.trakt : $0.show?.ids.trakt) == id
            }) else { throw TraktHistoryDiagnostics.incomplete("watches", "title-membership") }
            result.append(contentsOf: records)
        }
        return result
    }

    private func watchedTitles(
        movies: Bool, token: String, validate: @escaping @Sendable () async throws -> Void
    ) async throws -> [TraktWatchedTitle] {
        let query = movies ? [] : [
            URLQueryItem(name: "extended", value: "noseasons"), URLQueryItem(name: "hidden", value: "true"),
            URLQueryItem(name: "specials", value: "true"), URLQueryItem(name: "count_specials", value: "true")
        ]
        var endpoint = Endpoint(method: .get, path: "/users/me/watched/\(movies ? "movies" : "shows")",
                                queryItems: query, headers: headers(accessToken: token))
        endpoint.maximumResponseBytes = 32 * 1024 * 1024
        endpoint.redirectPolicy = .sameOrigin
        endpoint.redactsURLForLogging = true
        try Task.checkCancellation()
        try await validate()
        let (data, response) = try await readPage(endpoint, validate: validate)
        try Task.checkCancellation()
        try await validate()
        guard response.statusCode == 200 else { throw oauthError(data: data, response: response) }
        // This is Trakt's unpaginated title summary, not its paginated minimal format.
        guard data.count <= 32 * 1024 * 1024, !["Page", "Limit", "Page-Count", "Item-Count"].contains(where: {
            response.value(forHTTPHeaderField: "X-Pagination-" + $0) != nil
        }) else { throw TraktHistoryDiagnostics.incomplete("watches", "title-summary-pagination") }
        return try JSONDecoder().decode([TraktWatchedTitle].self, from: data)
    }
}

private struct TraktWatchedTitle: Decodable {
    let movie: TraktMovieRef?
    let show: TraktShowRef?
    let lastUpdatedAt: String
    let plays: Int
    enum CodingKeys: String, CodingKey {
        case movie, show, plays
        case lastUpdatedAt = "last_updated_at"
    }

    func titleID(movies: Bool) -> Int? {
        guard movies ? show == nil : movie == nil else { return nil }
        return movies ? movie?.ids.trakt : show?.ids.trakt
    }
}
