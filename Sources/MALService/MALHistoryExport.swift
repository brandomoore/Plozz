import CoreModels
import CoreNetworking
import Foundation

public struct MALHistoryExportTarget: Codable, Hashable, Sendable {
    let userID: Int
    let mediaID: Int
}

extension MALClient {
    static func supportsHistoryExport(_ item: MediaItem) -> Bool {
        item.kind == .movie && exportID(item) != nil
    }

    func resolveHistoryExport(
        _ item: MediaItem, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> MALHistoryExportTarget {
        guard Self.supportsHistoryExport(item), let id = Self.exportID(item) else {
            throw TrackerHistoryExportError.unsupported
        }
        let (owner, _) = try await exportMovie(id, accessToken: accessToken, validateScope: validateScope)
        return .init(userID: owner, mediaID: id)
    }

    func historyExportState(
        _ target: MALHistoryExportTarget, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistoryExportState {
        let (owner, state) = try await exportMovie(
            target.mediaID, accessToken: accessToken, validateScope: validateScope
        )
        guard owner == target.userID else { throw TrackerHistoryError.scopeChanged }
        return state
    }

    func exportMovieCompletion(
        _ target: MALHistoryExportTarget, accessToken: String,
        authorize: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard target.mediaID > 0, target.userID > 0 else {
            throw TrackerHistoryExportError.notWritten(.invalidResponse)
        }
        var endpoint = Endpoint(
            method: .patch, path: "/anime/\(target.mediaID)/my_list_status",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"
            ],
            redirectPolicy: .sameOrigin
        )
        endpoint.body = formBody(["status": "completed"])
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
        let status: MALHistoryEntry.Status
        do { status = try JSONDecoder().decode(MALHistoryEntry.Status.self, from: data) }
        catch {
            PlozzLog.networking.error("MyAnimeList export acknowledgement could not be interpreted safely")
            throw TrackerHistoryExportError.uncertainWrite
        }
        guard data.count <= 1_024 * 1_024, status.status == "completed", status.is_rewatching == false else {
            throw TrackerHistoryExportError.uncertainWrite
        }
        // MAL's acknowledgement has no owner or title ID. The session must
        // independently read the exact authenticated target after dispatch.
    }

    private static func exportID(_ item: MediaItem) -> Int? {
        item.providerID(.myAnimeList).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    private func exportMovie(
        _ id: Int, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> (Int, TrackerHistoryExportState) {
        guard id > 0 else { throw TrackerHistoryExportError.unsupported }
        let owner: MALHistoryOwner = try await historyRead(
            path: "/users/@me", accessToken: accessToken, validateScope: validateScope
        )
        guard owner.id > 0 else { throw TrackerHistoryError.invalidObservation }
        let movie: MALExportMovie = try await historyRead(
            path: "/anime/\(id)",
            query: [.init(name: "fields", value:
                "id,title,media_type,my_list_status{status,score,num_episodes_watched,is_rewatching,num_times_rewatched,updated_at}")],
            accessToken: accessToken, validateScope: validateScope
        )
        guard movie.id == id else { throw TrackerHistoryError.invalidObservation }
        guard movie.media_type == "movie" else { throw TrackerHistoryExportError.unsupported }
        let observations: [TrackerHistoryObservation]
        if movie.hasListStatus {
            observations = try movie.observation().map { [$0] } ?? []
        } else {
            // An omitted optional field is not proof of absence. Fall back to
            // the complete authenticated list, never to an assumed empty entry.
            let snapshot = try await historySnapshot(
                accessToken: accessToken, connectionID: "history-export-target", validateScope: validateScope
            )
            observations = snapshot.observations.filter {
                $0.identities.contains(.external(source: "myanimelist", value: String(id)))
            }
            guard observations.count <= 1, observations.allSatisfy({ $0.kind == .movie }) else {
                throw TrackerHistoryError.invalidObservation
            }
        }
        let after: MALHistoryOwner = try await historyRead(
            path: "/users/@me", accessToken: accessToken, validateScope: validateScope
        )
        guard after.id == owner.id else { throw TrackerHistoryError.scopeChanged }
        return (owner.id, try .init(observations: observations))
    }
}

private struct MALExportMovie: Decodable {
    let id: Int
    let title: String?
    let media_type: String
    let hasListStatus: Bool
    let my_list_status: MALHistoryEntry.Status?

    private enum CodingKeys: String, CodingKey { case id, title, media_type, my_list_status }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasListStatus = values.contains(.my_list_status)
        id = try values.decode(Int.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        media_type = try values.decode(String.self, forKey: .media_type)
        my_list_status = try values.decodeIfPresent(MALHistoryEntry.Status.self, forKey: .my_list_status)
    }

    func observation() throws -> TrackerHistoryObservation? {
        guard let status = my_list_status else { return nil }
        guard status.is_rewatching != nil else { throw TrackerHistoryError.invalidObservation }
        return try MALHistoryEntry(
            node: .init(id: id, title: title, media_type: media_type), list_status: status
        ).observation()
    }
}
