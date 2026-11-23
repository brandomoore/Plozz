import CoreModels
import CoreNetworking
import Foundation

public struct AniListHistoryExportTarget: Codable, Hashable, Sendable {
    let userID: Int
    let mediaID: Int
}

extension AniListClient {
    static func supportsHistoryExport(_ item: MediaItem) -> Bool {
        item.kind == .movie && (exportID(item, .aniList) != nil || exportID(item, .myAnimeList) != nil)
    }

    func resolveHistoryExport(
        _ item: MediaItem, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> AniListHistoryExportTarget {
        guard Self.supportsHistoryExport(item) else { throw TrackerHistoryExportError.unsupported }
        let aniListID = Self.exportID(item, .aniList)
        let malID = Self.exportID(item, .myAnimeList)
        let result = try await exportMovie(
            mediaID: aniListID, malID: malID, accessToken: accessToken, validateScope: validateScope
        )
        guard let media = result.Media,
              aniListID.map({ $0 == media.id }) ?? true,
              malID.map({ $0 == media.idMal }) ?? true else {
            throw TrackerHistoryExportError.unsupported
        }
        return .init(userID: result.Viewer.id, mediaID: media.id)
    }

    func historyExportState(
        _ target: AniListHistoryExportTarget, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistoryExportState {
        let result = try await exportMovie(
            mediaID: target.mediaID, malID: nil, accessToken: accessToken, validateScope: validateScope
        )
        guard result.Viewer.id == target.userID else { throw TrackerHistoryError.scopeChanged }
        guard let media = result.Media, media.id == target.mediaID else {
            throw TrackerHistoryError.invalidObservation
        }
        let observations = try media.mediaListEntry.map { [try $0.observation()] } ?? []
        return try .init(observations: observations)
    }

    func exportMovieCompletion(
        _ target: AniListHistoryExportTarget, accessToken: String,
        authorize: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard target.mediaID > 0, target.userID > 0 else {
            throw TrackerHistoryExportError.notWritten(.invalidResponse)
        }
        // Only status changes. Dates, counts, scores, notes and episode progress
        // must not be reconstructed from a server's movie watched flag.
        var endpoint = try Endpoint(
            method: .post, path: "",
            headers: ["Authorization": "Bearer \(accessToken)", "Content-Type": "application/json", "Accept": "application/json"]
        ).jsonBody(AniListGraphQLBodyWithVars(
            query: """
            mutation ($mediaId: Int!) {
              SaveMediaListEntry(mediaId: $mediaId, status: COMPLETED) { id userId mediaId status }
            }
            """,
            variables: ["mediaId": .int(target.mediaID)]
        ))
        endpoint.redirectPolicy = .sameOrigin
        endpoint.maximumResponseBytes = 1_024 * 1_024
        endpoint.redactsURLForLogging = true
        endpoint.reportsUndeliveredRequests = true
        try Task.checkCancellation()
        try await authorize()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRaw(endpoint, baseURL: config.apiBaseURL)
        } catch let error as HTTPRequestNotSentError {
            throw TrackerHistoryExportError.notWritten(error.underlying)
        } catch {
            throw TrackerHistoryExportError.uncertainWrite
        }
        switch response.statusCode {
        case 401, 403: throw TrackerHistoryExportError.notWritten(.unauthorized)
        case 429: throw TrackerHistoryExportError.notWritten(.rateLimited(retryAfter: nil))
        case 200: break
        default: throw TrackerHistoryExportError.uncertainWrite
        }
        let envelope: AniListGraphQLResponse<MovieExportAcknowledgement>
        do { envelope = try JSONDecoder().decode(AniListGraphQLResponse<MovieExportAcknowledgement>.self, from: data) }
        catch {
            PlozzLog.networking.error("AniList export acknowledgement could not be interpreted safely")
            throw TrackerHistoryExportError.uncertainWrite
        }
        guard data.count <= 1_024 * 1_024, envelope.errors?.isEmpty ?? true,
              let entry = envelope.data?.SaveMediaListEntry, entry.id > 0,
              entry.userId == target.userID, entry.mediaId == target.mediaID, entry.status == "COMPLETED" else {
            throw TrackerHistoryExportError.uncertainWrite
        }
    }

    private static func exportID(_ item: MediaItem, _ namespace: ProviderIDNamespace) -> Int? {
        item.providerID(namespace).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    private func exportMovie(
        mediaID: Int?, malID: Int?, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> MovieExportResponse {
        let variables: [String: AniListVariable]
        if let mediaID, mediaID > 0 { variables = ["id": .int(mediaID)] }
        else if let malID, malID > 0 { variables = ["malId": .int(malID)] }
        else { throw TrackerHistoryExportError.unsupported }
        let result: MovieExportResponse = try await historyQuery(
            """
            query ($id: Int, $malId: Int) {
              Viewer { id }
              Media(id: $id, idMal: $malId, type: ANIME) {
                id idMal type format
                mediaListEntry {
                  id userId mediaId status progress repeat score(format: POINT_10_DECIMAL) updatedAt
                  media { id idMal type format title { romaji english } }
                }
              }
            }
            """,
            variables: variables, accessToken: accessToken, validateScope: validateScope
        )
        guard result.Viewer.id > 0 else { throw TrackerHistoryError.invalidObservation }
        guard let media = result.Media, media.type == "ANIME", media.format == "MOVIE" else {
            throw TrackerHistoryExportError.unsupported
        }
        guard media.id > 0, media.idMal.map({ $0 > 0 }) ?? true,
              mediaID.map({ $0 == media.id }) ?? true,
              malID.map({ $0 == media.idMal }) ?? true else {
            throw TrackerHistoryError.invalidObservation
        }
        if let entry = media.mediaListEntry {
            guard entry.userId == result.Viewer.id, entry.mediaId == media.id,
                  entry.media.idMal == media.idMal, entry.media.format == "MOVIE" else {
                throw TrackerHistoryError.invalidObservation
            }
            _ = try entry.observation()
        }
        return result
    }
}

private struct MovieExportResponse: Decodable {
    struct Owner: Decodable { let id: Int }
    struct MediaValue: Decodable {
        let id: Int
        let idMal: Int?
        let type: String
        let format: String?
        let mediaListEntry: AniListHistoryEntry?

        private enum CodingKeys: String, CodingKey { case id, idMal, type, format, mediaListEntry }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.mediaListEntry) else { throw TrackerHistoryError.incompleteSnapshot }
            id = try values.decode(Int.self, forKey: .id)
            idMal = try values.decodeIfPresent(Int.self, forKey: .idMal)
            type = try values.decode(String.self, forKey: .type)
            format = try values.decodeIfPresent(String.self, forKey: .format)
            mediaListEntry = try values.decodeIfPresent(AniListHistoryEntry.self, forKey: .mediaListEntry)
        }
    }
    let Viewer: Owner
    let Media: MediaValue?
}

private struct MovieExportAcknowledgement: Decodable {
    struct Entry: Decodable {
        let id: Int
        let userId: Int
        let mediaId: Int
        let status: String
    }
    let SaveMediaListEntry: Entry?
}
