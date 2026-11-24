import CoreModels
import CoreNetworking
import Foundation

public struct SimklHistoryExportTarget: Codable, Hashable, Sendable {
    let userID: Int
    let movieID: Int
}

@MainActor
final class SimklHistoryExportAdapter {
    private let client: SimklClient
    private let reader: SimklHistoryReader
    private let connectionID: String
    private var ownerID: Int?
    private var sources: [SimklHistoryExportTarget: MediaItem] = [:]

    init(client: SimklClient, connectionID: String) {
        self.client = client
        self.connectionID = connectionID
        reader = SimklHistoryReader(client: client, includesListStates: true)
    }

    static func supports(_ item: MediaItem) -> Bool {
        item.kind == .movie && lookupID(item) != nil
    }

    func snapshot(token: String, validate: @MainActor @escaping () throws -> Void) async throws -> TrackerHistorySnapshot {
        let owner = try await owner(token, validate)
        let result = try await reader.snapshot(accessToken: token, connectionID: connectionID, validateScope: validate)
        guard try await self.owner(token, validate) == owner else { throw TrackerHistoryError.scopeChanged }
        sources.removeAll(keepingCapacity: true)
        return result
    }

    func resolve(
        _ item: MediaItem, token: String, validate: @MainActor @escaping () throws -> Void
    ) async throws -> SimklHistoryExportTarget {
        guard Self.supports(item), let lookup = Self.lookupID(item) else { throw TrackerHistoryExportError.unsupported }
        let owner = try await owner(token, validate)
        var request = Endpoint(
            path: "/redirect", queryItems: [
                .init(name: "to", value: "simkl"), .init(name: "type", value: "movie"),
                .init(name: lookup.0, value: lookup.1)
            ], redirectPolicy: .doNotFollow
        )
        request.maximumResponseBytes = 64 * 1_024
        let (_, response) = try await client.send(request, raw: true) { try await validate() }
        try validate()
        switch response.statusCode {
        case 301: break
        case 404: throw TrackerHistoryExportError.unsupported
        case 401, 403: throw AppError.unauthorized
        case 429: throw AppError.rateLimited(retryAfter: SimklRequestGate.retryAfter(response))
        default: throw AppError.invalidResponse
        }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let url = URLComponents(string: location), url.scheme == "https", url.host == "simkl.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw TrackerHistoryExportError.unsupported }
        let parts = url.path.split(separator: "/")
        guard (2...3).contains(parts.count), parts[0] == "movies",
              let id = Int(parts[1]), id > 0 else { throw TrackerHistoryExportError.unsupported }
        let target = SimklHistoryExportTarget(userID: owner, movieID: id)
        try await requireMetadata(target, item: item, validate: validate)
        guard try await self.owner(token, validate) == owner else { throw TrackerHistoryError.scopeChanged }
        guard sources.count < 50 || sources[target] != nil else { throw TrackerHistoryError.invalidSelection }
        sources[target] = item
        return target
    }

    func state(
        _ target: SimklHistoryExportTarget, token: String, validate: @MainActor @escaping () throws -> Void
    ) async throws -> TrackerHistoryExportState {
        guard let item = sources[target], try await owner(token, validate) == target.userID else {
            throw TrackerHistoryError.scopeChanged
        }
        try await requireMetadata(target, item: item, validate: validate)
        let result = try await reader.snapshot(accessToken: token, connectionID: connectionID, validateScope: validate)
        guard try await owner(token, validate) == target.userID else { throw TrackerHistoryError.scopeChanged }
        return try .init(observations: result.observations.filter { $0.matchesHistoryExport(item) })
    }

    private func owner(_ token: String, _ validate: @MainActor @escaping () throws -> Void) async throws -> Int {
        let settings: SimklUserSettings = try await read("/users/settings", token: token, validate: validate)
        guard let id = settings.account.id, id > 0 else { throw TrackerHistoryError.invalidObservation }
        guard ownerID == nil || ownerID == id else { throw TrackerHistoryError.scopeChanged }
        ownerID = id
        return id
    }

    private func requireMetadata(
        _ target: SimklHistoryExportTarget, item: MediaItem, validate: @MainActor @escaping () throws -> Void
    ) async throws {
        struct Movie: Decodable { let type: String; let ids: SimklResponseIDs }
        let movie: Movie = try await read("/movies/\(target.movieID)", token: nil, validate: validate)
        guard movie.type == "movie", movie.ids.simkl == target.movieID,
              try TrackerHistoryObservation.matches(item, kind: .movie, identities: movie.ids.historyIdentities()) else {
            throw TrackerHistoryExportError.unsupported
        }
    }

    private func read<Value: Decodable>(
        _ path: String, token: String?, validate: @MainActor @escaping () throws -> Void
    ) async throws -> Value {
        var request = Endpoint(path: path, headers: client.headers(accessToken: token))
        request.maximumResponseBytes = 1_024 * 1_024
        let (data, response) = try await client.send(request, raw: true) { try await validate() }
        try validate()
        switch response.statusCode {
        case 200: break
        case 401, 403: throw AppError.unauthorized
        case 429: throw AppError.rateLimited(retryAfter: SimklRequestGate.retryAfter(response))
        default: throw AppError.invalidResponse
        }
        guard data.count <= 1_024 * 1_024 else { throw TrackerHistoryError.incompleteSnapshot }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch {
            PlozzLog.networking.error("Simkl export evidence could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
    }

    private static func lookupID(_ item: MediaItem) -> (String, String)? {
        for (name, namespace) in [("imdb", ProviderIDNamespace.imdb), ("tmdb", .tmdb)] {
            guard let value = item.providerID(namespace) else { continue }
            if name == "imdb" {
                if value.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil { return (name, value) }
            } else if let id = Int(value), id > 0 { return (name, String(id)) }
        }
        return nil
    }
}

private struct SimklExportAcknowledgement: Decodable {
    struct Added: Decodable {
        struct Status: Decodable {
            struct Request: Decodable {
                let type: String
                let ids: SimklResponseIDs
                let watchedAt: String
                enum CodingKeys: String, CodingKey { case type, ids, watchedAt = "watched_at" }
            }
            struct Response: Decodable {
                let status: String
                let kind: String
                let rewatchID: Int?
                let rewatchStatus: String?
                enum CodingKeys: String, CodingKey {
                    case status, kind = "simkl_type", rewatchID = "rewatch_id", rewatchStatus = "rewatch_status"
                }
            }
            let request: Request
            let response: Response
        }
        let movies: Int
        let shows: Int
        let episodes: Int
        let statuses: [Status]
    }
    struct Failure: Decodable { let ids: SimklResponseIDs? }
    let added: Added
    let notFound: [String: [Failure]]
    enum CodingKeys: String, CodingKey { case added, notFound = "not_found" }
}

extension SimklClient {
    func exportHistory(
        _ target: SimklHistoryExportTarget, date: Date?, token: String,
        authorize: @escaping @Sendable () async throws -> Void,
        validate: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard target.userID > 0, target.movieID > 0,
              date.map({ $0.timeIntervalSince1970.isFinite && $0 <= Date() && $0.timeIntervalSince1970 != 1 }) ?? true else {
            throw TrackerHistoryExportError.notWritten(.invalidResponse)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let watchedAt = date.map(formatter.string) ?? "1970-01-01T00:00:01Z"
        let body = SimklHistoryBody(movies: [
            .init(ids: .init(simkl: target.movieID), watchedAt: watchedAt, isRewatch: false)
        ])
        var request = try Endpoint(method: .post, path: "/sync/history", headers: headers(accessToken: token)).jsonBody(body)
        request.maximumResponseBytes = 1_024 * 1_024
        request.reportsUndeliveredRequests = true
        try await authorize()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request, raw: true) {
                do { try await validate() }
                catch { throw TrackerHistoryExportError.notWritten(error is CancellationError ? .cancelled : .conflict) }
            }
        } catch let error as TrackerHistoryExportError { throw error }
        catch let error as HTTPRequestNotSentError { throw TrackerHistoryExportError.notWritten(error.underlying) }
        catch is CancellationError { throw TrackerHistoryExportError.notWritten(.cancelled) }
        catch let error as AppError {
            if case .rateLimited = error { throw TrackerHistoryExportError.notWritten(error) }
            throw TrackerHistoryExportError.uncertainWrite
        } catch { throw TrackerHistoryExportError.uncertainWrite }
        switch response.statusCode {
        case 401, 403: throw TrackerHistoryExportError.notWritten(.unauthorized)
        case 429:
            throw TrackerHistoryExportError.notWritten(.rateLimited(
                retryAfter: SimklRequestGate.retryAfter(response)
            ))
        case 201: break
        default: throw TrackerHistoryExportError.uncertainWrite
        }
        let result: SimklExportAcknowledgement
        do { result = try JSONDecoder().decode(SimklExportAcknowledgement.self, from: data) }
        catch {
            PlozzLog.networking.error("Simkl export acknowledgement could not be interpreted safely")
            throw TrackerHistoryExportError.uncertainWrite
        }
        guard data.count <= 1_024 * 1_024, result.added.movies == 1, result.added.shows == 0,
              result.added.episodes == 0, result.added.statuses.count == 1,
              let status = result.added.statuses.first, status.request.type == "movie",
              status.request.ids.simkl == target.movieID, status.request.watchedAt == watchedAt,
              status.response.kind == "movie", status.response.status == "completed",
              status.response.rewatchID == nil, status.response.rewatchStatus == nil,
              Set(result.notFound.keys) == ["movies", "shows", "episodes"],
              result.notFound.values.allSatisfy(\.isEmpty) else { throw TrackerHistoryExportError.uncertainWrite }
    }
}
