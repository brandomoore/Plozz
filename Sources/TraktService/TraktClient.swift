import Foundation
import CoreModels
import CoreNetworking

/// Low-level Trakt API calls, built on the shared `HTTPClient`.
///
/// Centralises Trakt's required headers (`trakt-api-version`, `trakt-api-key`,
/// and the bearer `Authorization`) and the OAuth + scrobble endpoints. All
/// request bodies are JSON; tokens are never logged (the `HTTPClient` redacts
/// `Authorization`).
struct TraktClient: Sendable {
    let config: TraktConfig
    let http: HTTPClient

    init(config: TraktConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL { config.apiBaseURL }

    /// Headers required on every Trakt request. The bearer token is optional —
    /// OAuth endpoints are unauthenticated.
    private func headers(accessToken: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": config.clientID ?? ""
        ]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return headers
    }

    // MARK: - OAuth (device code)

    /// `POST /oauth/device/code` — begins the device-code flow.
    func requestDeviceCode() async throws -> TraktDeviceCode {
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/code", headers: headers())
            .jsonBody(["client_id": config.clientID ?? ""])
        return try await http.decode(TraktDeviceCode.self, from: endpoint, baseURL: config.authBaseURL)
    }

    /// `POST /oauth/device/token` — exchanges a device code for tokens once the
    /// user approves. Throws (HTTP 4xx) while still pending; the caller polls.
    func requestToken(deviceCode: String) async throws -> TraktTokenResponse {
        let body = [
            "code": deviceCode,
            "client_id": config.clientID ?? ""
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/device/token", headers: headers())
            .jsonBody(body)
        let (data, response) = try await http.sendRaw(endpoint, baseURL: config.authBaseURL)
        switch response.statusCode {
        case 200:
            return try decodeToken(data)
        case 400:
            throw TraktDeviceAuthorizationError.pending
        case 404, 409:
            throw AppError.invalidResponse
        case 410:
            throw AppError.quickConnectExpired
        case 418:
            throw AppError.cancelled
        default:
            throw oauthError(data: data, response: response)
        }
    }

    func exchangeCode(_ code: String, verifier: String) async throws -> TraktTokenResponse {
        try await tokenRequest([
            "client_id": config.clientID ?? "",
            "redirect_uri": config.redirectURI.absoluteString,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
        ])
    }

    /// `POST /oauth/token` — refreshes an expired access token.
    func refreshToken(_ refreshToken: String) async throws -> TraktTokenResponse {
        let body = [
            "refresh_token": refreshToken,
            "client_id": config.clientID ?? "",
            "redirect_uri": config.redirectURI.absoluteString,
            "grant_type": "refresh_token"
        ]
        return try await tokenRequest(body)
    }

    /// `POST /oauth/revoke` — invalidates the token server-side on disconnect.
    func revoke(accessToken: String) async throws {
        let body = [
            "token": accessToken,
            "client_id": config.clientID ?? ""
        ]
        let endpoint = try Endpoint(method: .post, path: "/oauth/revoke", headers: headers())
            .jsonBody(body)
        _ = try await http.send(endpoint, baseURL: config.authBaseURL)
    }

    private func tokenRequest(_ body: [String: String]) async throws -> TraktTokenResponse {
        var endpoint = try Endpoint(method: .post, path: "/oauth/token", headers: headers())
            .jsonBody(body)
        endpoint.reportsUndeliveredRequests = body["grant_type"] == "refresh_token"
        let (data, response) = try await http.sendRaw(endpoint, baseURL: config.authBaseURL)
        guard response.statusCode == 200 else {
            throw oauthError(data: data, response: response)
        }
        return try decodeToken(data)
    }

    private func decodeToken(_ data: Data) throws -> TraktTokenResponse {
        guard let response = try? JSONDecoder.plozz.decode(TraktTokenResponse.self, from: data),
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              response.expiresIn.isFinite, response.expiresIn > 0,
              response.createdAt.isFinite else { throw AppError.decoding }
        return response
    }

    private func oauthError(data: Data, response: HTTPURLResponse) -> AppError {
        struct OAuthError: Decodable { let error: String }
        if response.statusCode == 400,
           (try? JSONDecoder().decode(OAuthError.self, from: data).error) == "invalid_grant" {
            return .unauthorized
        }
        switch response.statusCode {
        case 401, 403: return .unauthorized
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            let seconds = header.flatMap(TimeInterval.init)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let dateSeconds = header.flatMap { formatter.date(from: $0)?.timeIntervalSinceNow }
            return .rateLimited(retryAfter: (seconds ?? dateSeconds).flatMap {
                $0.isFinite ? max(0, $0) : nil
            })
        default: return .invalidResponse
        }
    }

    // MARK: - User

    /// `GET /users/settings` — the connected user's profile (for display).
    func userSettings(accessToken: String) async throws -> TraktUserSettings {
        let endpoint = Endpoint(method: .get, path: "/users/settings", headers: headers(accessToken: accessToken))
        return try await http.decode(TraktUserSettings.self, from: endpoint, baseURL: baseURL)
    }

    // MARK: - Scrobble

    /// `POST /scrobble/{action}` — records playback state. A `stop` past Trakt's
    /// watched threshold (80%) adds the item to the user's history.
    ///
    /// A `409 Conflict` is **success, not failure**: Trakt returns it when the
    /// item was already scrobbled within its cooldown window (account-scoped,
    /// client-agnostic self-dedupe), which is exactly the "already recorded"
    /// outcome we want. Swallowing it here means a duplicate scrobble (e.g. a
    /// server-side Trakt plugin beat us, or our own outbox retried) is treated as
    /// confirmed — no phantom error, no retry.
    func scrobble(action: String, body: TraktScrobbleBody, accessToken: String) async throws {
        let endpoint = try Endpoint(method: .post, path: "/scrobble/\(action)", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        do {
            _ = try await http.send(endpoint, baseURL: baseURL)
        } catch AppError.conflict {
            // 409 = already scrobbled = success.
        }
    }

    // MARK: - Watchlist

    func watchlist(
        accessToken: String
    ) async throws -> [TraktWatchlistItem] {
        async let movieEntries: [TraktWatchlistMovieEntry] = watchlistGET(
            path: "/sync/watchlist/movies/added/desc",
            accessToken: accessToken
        )
        async let showEntries: [TraktWatchlistShowEntry] = watchlistGET(
            path: "/sync/watchlist/shows/added/desc",
            accessToken: accessToken
        )
        let (movies, shows) = try await (movieEntries, showEntries)
        var items: [TraktWatchlistItem] = []
        for (providerOrder, entry) in movies.enumerated() {
            guard let listedAt = Self.parseTimestamp(entry.listedAt) else {
                throw WatchlistDestinationError.transient
            }
            items.append(TraktWatchlistItem(
                id: entry.id,
                listedAt: listedAt,
                kind: .movie,
                title: entry.movie,
                providerOrder: providerOrder
            ))
        }
        for (providerOrder, entry) in shows.enumerated() {
            guard let listedAt = Self.parseTimestamp(entry.listedAt) else {
                throw WatchlistDestinationError.transient
            }
            items.append(TraktWatchlistItem(
                id: entry.id,
                listedAt: listedAt,
                kind: .series,
                title: entry.show,
                providerOrder: providerOrder
            ))
        }
        return items.sorted {
            if $0.listedAt != $1.listedAt {
                return $0.listedAt > $1.listedAt
            }
            if $0.kind == $1.kind {
                return $0.providerOrder < $1.providerOrder
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    func setWatchlisted(
        _ present: Bool,
        kind: MediaItemKind,
        ids: TraktWatchlistIDs,
        accessToken: String
    ) async throws {
        guard !ids.isEmpty, kind == .movie || kind == .series else {
            throw WatchlistDestinationError.unsupportedIdentity
        }
        let title = TraktWatchlistTitle(ids: ids)
        let body = TraktWatchlistMutationBody(
            movies: kind == .movie ? [title] : nil,
            shows: kind == .series ? [title] : nil
        )
        let endpoint = try Endpoint(
            method: .post,
            path: present ? "/sync/watchlist" : "/sync/watchlist/remove",
            headers: headers(accessToken: accessToken)
        ).jsonBody(body)
        let (_, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        try validateWatchlistStatus(response, idempotentMutation: true)
    }

    private func watchlistGET<T: Decodable & TraktWatchlistIdentifiable>(
        path: String,
        accessToken: String
    ) async throws -> [T] {
        let limit = 100
        let maximumPages = 1_000
        var page = 1
        var result: [T] = []
        var seenIDs: Set<Int> = []
        var expectedItemCount: Int?
        var expectedPageCount: Int?
        while page <= maximumPages {
            let endpoint = Endpoint(
                method: .get,
                path: path,
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "limit", value: String(limit)),
                ],
                headers: headers(accessToken: accessToken)
            )
            let (data, response) = try await http.sendRaw(
                endpoint,
                baseURL: baseURL
            )
            try validateWatchlistStatus(response, idempotentMutation: false)
            let entries: [T]
            do {
                entries = try JSONDecoder.plozz.decode([T].self, from: data)
            } catch {
                throw AppError.decoding
            }
            for entry in entries {
                guard seenIDs.insert(entry.id).inserted else {
                    throw WatchlistDestinationError.transient
                }
                result.append(entry)
            }
            let itemCount = response.value(
                forHTTPHeaderField: "X-Pagination-Item-Count"
            ).flatMap(Int.init)
            if expectedItemCount != nil, itemCount == nil {
                throw WatchlistDestinationError.transient
            }

            if let itemCount {
                guard expectedItemCount == nil || expectedItemCount == itemCount else {
                    throw WatchlistDestinationError.transient
                }
                expectedItemCount = itemCount
            }
            let pageCount = response.value(
                forHTTPHeaderField: "X-Pagination-Page-Count"
            ).flatMap(Int.init)
            if expectedPageCount != nil, pageCount == nil {
                throw WatchlistDestinationError.transient
            }
            if let pageCount {
                guard expectedPageCount == nil || expectedPageCount == pageCount else {
                    throw WatchlistDestinationError.transient
                }
                expectedPageCount = pageCount
                if pageCount == 0, entries.isEmpty {
                    guard expectedItemCount == nil || expectedItemCount == 0 else {
                        throw WatchlistDestinationError.transient
                    }
                    return result
                }
                guard pageCount >= page else {
                    throw WatchlistDestinationError.transient
                }
                if page >= pageCount {
                    guard expectedItemCount == nil
                            || expectedItemCount == result.count else {
                        throw WatchlistDestinationError.transient
                    }
                    return result
                }
            } else {
                if entries.count < limit { return result }
                throw WatchlistDestinationError.transient
            }
            page += 1
        }
        throw WatchlistDestinationError.transient
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private func validateWatchlistStatus(
        _ response: HTTPURLResponse,
        idempotentMutation: Bool
    ) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw WatchlistDestinationError.authenticationRequired
        case 404:
            throw WatchlistDestinationError.unsupportedIdentity
        case 409 where idempotentMutation:
            return
        case 429:
            throw WatchlistDestinationError.rateLimited(
                retryAfter: response.value(
                    forHTTPHeaderField: "Retry-After"
                ).flatMap(TimeInterval.init)
            )
        case 500...599:
            throw WatchlistDestinationError.transient
        default:
            throw WatchlistDestinationError.permanent
        }
    }

}

private protocol TraktWatchlistIdentifiable {
    var id: Int { get }
}

extension TraktWatchlistMovieEntry: TraktWatchlistIdentifiable {}
extension TraktWatchlistShowEntry: TraktWatchlistIdentifiable {}
