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
    let historyRead: TraktHistoryReadAttempt?

    init(config: TraktConfig, http: HTTPClient, historyRead: TraktHistoryReadAttempt? = nil) {
        self.config = config
        self.http = http
        self.historyRead = historyRead
    }

    private var baseURL: URL { config.apiBaseURL }

    /// Headers required on every Trakt request. The bearer token is optional —
    /// OAuth endpoints are unauthenticated.
    func headers(accessToken: String? = nil) -> [String: String] {
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

    func oauthError(data: Data, response: HTTPURLResponse) -> AppError {
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
            let (data, _) = try await http.send(endpoint, baseURL: baseURL)
            recordScrobbleResponse(action: action, body: body, data: data)
        } catch AppError.conflict {
            // 409 = already scrobbled = success.
        }
    }

    private func recordScrobbleResponse(action: String, body: TraktScrobbleBody, data: Data) {
        guard HandoffDiagnostics.isEnabled else { return }
        let safeAction = ["start", "pause", "stop"].contains(action) ? action : "unknown"
        let request = "TRAKT_SCROBBLE requestedAction=\(safeAction) requested={\(body.diagnosticDescription)}"
        do {
            let receipt = try JSONDecoder().decode(ScrobbleReceipt.self, from: data)
            let acknowledged = TraktScrobbleBody(
                movie: receipt.movie,
                show: receipt.show,
                episode: receipt.episode,
                progress: receipt.progress
            )
            let message = "\(request) responseAction=\(receipt.action.rawValue) response={\(acknowledged.diagnosticDescription)}"
            PlozzLog.playback.info(message)
            HandoffDiagnostics.emit(message)
        } catch {
            // Receipt diagnostics must not retry an already accepted write.
            let message = "\(request) response=unreadable"
            PlozzLog.playback.error(message)
            HandoffDiagnostics.emit(message)
        }
    }

    private struct ScrobbleReceipt: Decodable {
        enum Action: String, Decodable {
            case start, pause, scrobble
        }

        let action: Action
        let progress: Double
        let movie: TraktMovieRef?
        let show: TraktShowRef?
        let episode: TraktEpisodeRef?
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

    func historySnapshot(
        accessToken: String, connectionID: String,
        cache: TraktHistoryCache? = nil, cacheScope: String? = nil,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> TrackerHistorySnapshot {
        let before = try await historyActivity(accessToken: accessToken, validateScope: validateScope)
        var entries: [TraktHistoryGroup: TraktHistoryCache.Entry] = [:]
        if let cache, let cacheScope { entries = await cache.load(scope: cacheScope) }
        var updates: [TraktHistoryGroup: TraktHistoryCache.Entry] = [:]
        for playback in [false, true] {
            let groups = TraktHistoryGroup.allCases.filter { $0.playback == playback }
            let changed = groups.filter { entries[$0]?.stamp != $0.stamp(before) }
            if changed.isEmpty { continue }
            if groups.allSatisfy({ entries[$0] == nil }) {
                let all: [TraktHistoryRecord]
                do {
                    all = try await paginatedGET(
                        path: playback ? "/sync/playback" : "/users/me/history", accessToken: accessToken,
                        requiresCompleteEvidence: true, reportCorrectedWatchTotal: !playback, validateScope: validateScope
                    )
                } catch let correction as TraktCorrectedWatchTotal {
                    all = try await verifyWatchRanges(correction, accessToken: accessToken, validateScope: validateScope)
                }
                guard all.allSatisfy({ $0.type == "movie" || $0.type == "episode" }) else {
                    throw TrackerHistoryError.invalidObservation
                }
                for group in groups {
                    updates[group] = try .init(group, stamp: group.stamp(before), records: all.filter { $0.type == group.type })
                }
            } else {
                for group in changed {
                    let records = try await refreshedRecords(
                        group, prior: entries[group], revision: group.stamp(before), token: accessToken, validate: validateScope
                    )
                    updates[group] = try .init(group, stamp: group.stamp(before), records: records)
                }
            }
        }
        if !updates.isEmpty {
            let after = try await historyActivity(accessToken: accessToken, validateScope: validateScope)
            guard before.sameHistory(as: after) else { throw TraktHistoryDiagnostics.incomplete("activity", "changed-during-read") }
            entries.merge(updates) { _, new in new }
        }
        let snapshot = try TrackerHistorySnapshot(
            trackerID: "trakt", connectionID: connectionID, observations: TraktHistoryGroup.allCases.flatMap { entries[$0]?.observations ?? [] },
            completeness: .apiCount(entries.values.reduce(0) { $0 + $1.records.count }),
            isStillCurrent: { try await self.historyActivity(accessToken: accessToken, validateScope: validateScope).sameHistory(as: before) }
        )
        try await validateScope()
        if !updates.isEmpty, let cache, let cacheScope { await cache.save(updates, scope: cacheScope) }
        await historyRead?.reportSnapshotRequests()
        return snapshot
    }

    private func historyActivity(
        accessToken: String, validateScope: @Sendable () async throws -> Void
    ) async throws -> TraktHistoryActivity {
        try Task.checkCancellation()
        try await validateScope()
        let endpoint = Endpoint(method: .get, path: "/sync/last_activities", headers: headers(accessToken: accessToken))
        let (data, response) = try await readPage(endpoint, validate: validateScope)
        try Task.checkCancellation()
        try await validateScope()
        guard response.statusCode == 200 else { throw oauthError(data: data, response: response) }
        let activity: TraktHistoryActivity
        do { activity = try JSONDecoder().decode(TraktHistoryActivity.self, from: data) }
        catch { throw AppError.decoding }
        try activity.validate()
        return activity
    }

    private func watchlistGET<T: Decodable & TraktPageIdentifiable>(
        path: String,
        accessToken: String
    ) async throws -> [T] {
        try await paginatedGET(path: path, accessToken: accessToken, requiresCompleteEvidence: false, validateScope: {})
    }

    func paginatedGET<T: Decodable & TraktPageIdentifiable>(
        path: String, accessToken: String?, requiresCompleteEvidence: Bool,
        query: [URLQueryItem] = [], maximumResponseBytes: Int? = nil,
        reportCorrectedWatchTotal: Bool = false,
        validateScope: @Sendable () async throws -> Void
    ) async throws -> [T] {
        let limit = historyRead != nil && (path == "/users/me/history" || path.hasPrefix("/users/me/history/")) ? 250 : 100
        let maximumPages = 100_000 / limit
        var page = 1
        var result: [T] = []
        var seenIDs: Set<Int> = []
        var expectedItemCount: Int?
        var expectedPageCount: Int?
        while page <= maximumPages {
            try Task.checkCancellation()
            try await validateScope()
            var endpoint = Endpoint(
                method: .get,
                path: path,
                queryItems: query + [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "limit", value: String(limit)),
                ],
                headers: headers(accessToken: accessToken)
            )
            if let maximumResponseBytes {
                endpoint.maximumResponseBytes = maximumResponseBytes
                endpoint.redirectPolicy = .sameOrigin
                endpoint.redactsURLForLogging = true
            }
            if path.hasPrefix("/users/me/history/") {
                endpoint.redirectPolicy = .sameOrigin
                endpoint.redactsURLForLogging = true
            }
            let (data, response) = try await readPage(endpoint, validate: validateScope)
            try Task.checkCancellation()
            try await validateScope()
            if let maximumResponseBytes, data.count > maximumResponseBytes {
                throw TrackerHistoryError.incompleteSnapshot
            }
            if requiresCompleteEvidence {
                guard response.statusCode == 200 else { throw oauthError(data: data, response: response) }
            } else {
                try validateWatchlistStatus(response, idempotentMutation: false)
            }
            let entries: [T]
            do {
                entries = try JSONDecoder.plozz.decode([T].self, from: data)
            } catch {
                throw AppError.decoding
            }
            if requiresCompleteEvidence {
                // Log only fixed labels, not the request path, account, headers or media records.
                let source: StaticString = path == "/users/me/history" ? "watches" : path == "/sync/playback" ? "playback" : "other"
                guard response.value(forHTTPHeaderField: "X-Pagination-Page").flatMap(Int.init) == page,
                      response.value(forHTTPHeaderField: "X-Pagination-Limit").flatMap(Int.init) == limit,
                      let count = response.value(forHTTPHeaderField: "X-Pagination-Item-Count").flatMap(Int.init),
                      let pages = response.value(forHTTPHeaderField: "X-Pagination-Page-Count").flatMap(Int.init) else {
                    throw TraktHistoryDiagnostics.incomplete(source, "pagination-headers")
                }
                // Some unfiltered watch histories advertise a larger total until the last page.
                // Never return that read. Supply only its IDs for a separately verified read.
                if reportCorrectedWatchTotal, let original = expectedItemCount, count < original,
                   expectedPageCount == pages, page == pages, page > 1,
                   !entries.isEmpty, entries.count <= limit, seenIDs.count + entries.count == count {
                    let ids = seenIDs.union(entries.map(\.id))
                    guard ids.count == count else { throw TraktHistoryDiagnostics.incomplete(source, "duplicate-record") }
                    throw TraktCorrectedWatchTotal(ids: ids)
                }
                guard (0...(limit * maximumPages)).contains(count),
                      (expectedItemCount == nil || expectedItemCount == count),
                      (expectedPageCount == nil || expectedPageCount == pages) else {
                    throw TraktHistoryDiagnostics.incomplete(source, "pagination-totals")
                }
                guard (count == 0 && page == 1 && (pages == 0 || pages == 1))
                        || (count > 0 && pages == (count + limit - 1) / limit && page <= pages),
                      entries.count == min(limit, max(0, count - (page - 1) * limit)) else {
                    throw TraktHistoryDiagnostics.incomplete(source, "page-size")
                }
                guard Set(entries.map(\.id)).count == entries.count,
                      entries.allSatisfy({ !seenIDs.contains($0.id) }) else {
                    throw TraktHistoryDiagnostics.incomplete(source, "duplicate-record")
                }
                if path == "/users/me/history", pages > 0 {
                    await TrackerHistoryReadDetail.report?(query.isEmpty ? .watches(page: page, total: pages)
                        : .verifyingRange(page: page, total: pages))
                } else { await TrackerHistoryReadDetail.report?(nil) }
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
        if requiresCompleteEvidence { throw TrackerHistoryError.incompleteSnapshot }
        throw WatchlistDestinationError.transient
    }

    static func parseTimestamp(_ value: String) -> Date? {
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

protocol TraktPageIdentifiable: Sendable {
    var id: Int { get }
}

extension TraktWatchlistMovieEntry: TraktPageIdentifiable {}
extension TraktWatchlistShowEntry: TraktPageIdentifiable {}
extension TraktHistoryRecord: TraktPageIdentifiable {}
