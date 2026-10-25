import CoreModels
import CoreNetworking
import Foundation

extension AniListClient {
    func historySnapshot(
        accessToken: String, connectionID: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        let owner: HistoryOwnerResponse = try await historyQuery(
            "query { Viewer { id } }", variables: [:], accessToken: accessToken, validateScope: validateScope
        )
        guard owner.Viewer.id > 0 else { throw TrackerHistoryError.invalidObservation }
        var observations: [TrackerHistoryObservation] = []
        var entries = Set<Int>()
        var media = Set<Int>()
        var previousMediaID: Int?
        for pageNumber in 1...1_000 {
            let response: HistoryPageResponse = try await historyQuery(
                """
                query ($userId: Int!, $page: Int!) {
                  Viewer { id }
                  Page(page: $page, perPage: 50) {
                    pageInfo { currentPage perPage hasNextPage }
                    mediaList(userId: $userId, type: ANIME, sort: [MEDIA_ID_DESC]) {
                      id userId mediaId status progress repeat score(format: POINT_10_DECIMAL) updatedAt
                      media { id idMal type format title { romaji english } }
                    }
                  }
                }
                """,
                variables: ["userId": .int(owner.Viewer.id), "page": .int(pageNumber)],
                accessToken: accessToken, validateScope: validateScope
            )
            guard response.Viewer.id == owner.Viewer.id else { throw TrackerHistoryError.scopeChanged }
            let page = response.Page
            guard page.pageInfo.currentPage == pageNumber, page.pageInfo.perPage == 50,
                  page.mediaList.count <= 50,
                  !page.pageInfo.hasNextPage || page.mediaList.count == 50 else {
                throw TrackerHistoryError.incompleteSnapshot
            }
            for entry in page.mediaList {
                guard entry.userId == owner.Viewer.id, entries.insert(entry.id).inserted,
                      media.insert(entry.mediaId).inserted,
                      previousMediaID.map({ entry.mediaId < $0 }) ?? true else {
                    throw TrackerHistoryError.incompleteSnapshot
                }
                observations.append(try entry.observation())
                previousMediaID = entry.mediaId
            }
            if !page.pageInfo.hasNextPage {
                try await validateScope()
                try Task.checkCancellation()
                return try .init(
                    trackerID: "anilist", connectionID: connectionID,
                    observations: observations, completeness: .exhaustedPagination
                )
            }
        }
        throw TrackerHistoryError.incompleteSnapshot
    }

    private func historyQuery<Value: Decodable>(
        _ query: String, variables: [String: AniListVariable], accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        try await validateScope()
        var endpoint = try Endpoint(
            method: .post, path: "",
            headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json", "Accept": "application/json"]
        ).jsonBody(AniListGraphQLBodyWithVars(query: query, variables: variables))
        endpoint.redirectPolicy = .sameOrigin
        endpoint.maximumResponseBytes = 8 * 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        let (data, response) = try await http.send(endpoint, baseURL: config.apiBaseURL)
        try Task.checkCancellation()
        try await validateScope()
        guard response.statusCode == 200, data.count <= 8 * 1_024 * 1_024 else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        let envelope: HistoryErrors
        do { envelope = try JSONDecoder().decode(HistoryErrors.self, from: data) }
        catch {
            PlozzLog.networking.error("AniList history response could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
        if let errors = envelope.errors, !errors.isEmpty {
            PlozzLog.networking.error("AniList history query was rejected")
            if errors.contains(where: { $0.status == 401 }) { throw AppError.unauthorized }
            if errors.contains(where: { $0.status == 429 }) { throw AppError.rateLimited(retryAfter: nil) }
            throw AppError.invalidResponse
        }
        let result: AniListGraphQLResponse<Value>
        do { result = try JSONDecoder().decode(AniListGraphQLResponse<Value>.self, from: data) }
        catch {
            PlozzLog.networking.error("AniList history data could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
        guard let value = result.data else { throw TrackerHistoryError.incompleteSnapshot }
        return value
    }
}

private struct HistoryErrors: Decodable { let errors: [AniListGraphQLError]? }

private struct HistoryOwnerResponse: Decodable {
    struct Owner: Decodable { let id: Int }
    let Viewer: Owner
}

private struct HistoryPageResponse: Decodable {
    struct PageValue: Decodable {
        struct Info: Decodable {
            let currentPage: Int
            let perPage: Int
            let hasNextPage: Bool
        }
        let pageInfo: Info
        let mediaList: [AniListHistoryEntry]
    }
    let Viewer: HistoryOwnerResponse.Owner
    let Page: PageValue
}

struct AniListHistoryEntry: Decodable {
    struct Media: Decodable {
        let id: Int
        let idMal: Int?
        let type: String
        let format: String?
        let title: AniListTitle?
    }
    let id: Int
    let userId: Int
    let mediaId: Int
    let status: String?
    let progress: Int?
    let `repeat`: Int?
    let score: Double?
    let updatedAt: Int?
    let media: Media

    func observation() throws -> TrackerHistoryObservation {
        guard id > 0, userId > 0, mediaId > 0, media.id == mediaId, media.type == "ANIME",
              media.idMal.map({ $0 > 0 }) ?? true, updatedAt.map({ $0 >= 0 }) ?? true else {
            throw TrackerHistoryError.invalidObservation
        }
        let state: TrackerAnimeListProgress.Status?
        switch status {
        case "CURRENT": state = .watching
        case "PLANNING": state = .planning
        case "COMPLETED": state = .completed
        case "DROPPED": state = .dropped
        case "PAUSED": state = .paused
        case "REPEATING": state = .rewatching
        case nil: state = nil
        default: throw TrackerHistoryError.invalidObservation
        }
        var identities: [MediaIdentity] = [.external(source: "anilist", value: String(mediaId))]
        if let mal = media.idMal { identities.append(.external(source: "myanimelist", value: String(mal))) }
        return try .init(
            recordID: "list/\(id)", kind: media.format == "MOVIE" ? .movie : .series,
            identities: identities, sourceTitle: media.title?.english ?? media.title?.romaji,
            fact: .animeList(try .init(
                status: state, episodesWatched: progress, repeats: `repeat`, score: score,
                updatedAt: updatedAt.map { Date(timeIntervalSince1970: Double($0)) }
            ))
        )
    }
}
