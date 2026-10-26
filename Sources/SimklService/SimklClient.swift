import Foundation
import CoreModels
import CoreNetworking

/// Low-level Simkl API calls.
struct SimklClient: Sendable {
    let config: SimklConfig
    let http: HTTPClient
    let gate: SimklRequestGate

    init(config: SimklConfig, http: HTTPClient, gate: SimklRequestGate = .shared) {
        self.config = config
        self.http = http
        self.gate = gate
    }

    private var baseURL: URL { config.apiBaseURL }

    func headers(accessToken: String? = nil) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "simkl-api-key": config.clientID ?? ""
        ]
        if let accessToken {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return headers
    }

    func send(
        _ endpoint: Endpoint, raw: Bool = false,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> (Data, HTTPURLResponse) {
        guard let clientID = config.clientID else { throw AppError.unauthorized }
        var request = endpoint
        for item in [
            URLQueryItem(name: "client_id", value: clientID),
            .init(name: "app-name", value: "Plozz"), .init(name: "app-version", value: "1.0")
        ] where !request.queryItems.contains(where: { $0.name == item.name }) {
            request.queryItems.append(item)
        }
        request.headers["simkl-api-key"] = clientID
        request.headers["User-Agent"] = "Plozz/1.0"
        if request.redirectPolicy == .follow { request.redirectPolicy = .sameOrigin }
        request.redactsURLForLogging = true
        if request.maximumResponseBytes == nil { request.maximumResponseBytes = 64 * 1_024 * 1_024 }
        let prepared = request
        return try await gate.run(clientID: clientID, method: request.method, validate: validate) { [http, baseURL] in
            do {
                if raw { return try await http.sendRaw(prepared, baseURL: baseURL) }
                return try await http.send(prepared, baseURL: baseURL)
            } catch is CancellationError {
                if prepared.reportsUndeliveredRequests { throw AppError.cancelled }
                throw CancellationError()
            }
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type, endpoint: Endpoint,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> Value {
        let (data, _) = try await send(endpoint, validate: validate)
        do { return try JSONDecoder.plozz.decode(type, from: data) }
        catch {
            PlozzLog.networking.error("Simkl response could not be decoded")
            throw AppError.decoding
        }
    }

    // MARK: - OAuth (PIN flow)

    /// `GET /oauth/pin?client_id=...` — request a device PIN code.
    func requestDeviceCode() async throws -> SimklDeviceCode {
        let endpoint = Endpoint(
            method: .get,
            path: "/oauth/pin",
            queryItems: [URLQueryItem(name: "client_id", value: config.clientID ?? "")],
            headers: headers()
        )
        return try await decode(SimklDeviceCode.self, endpoint: endpoint)
    }

    /// `GET /oauth/pin/{USER_CODE}?client_id=...` — poll for approval.
    /// Returns `nil` if still pending, or the access token string on success.
    func pollForToken(userCode: String) async throws -> String? {
        let endpoint = Endpoint(
            method: .get,
            path: "/oauth/pin/\(userCode)",
            queryItems: [URLQueryItem(name: "client_id", value: config.clientID ?? "")],
            headers: headers()
        )
        let (data, _) = try await send(endpoint)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // Success: {"result":"OK","access_token":"..."}
        if let token = json["access_token"] as? String {
            return token
        }
        // If the response contains "device_code", the original code expired/was consumed
        if json["device_code"] != nil {
            throw SimklPINExpiredError()
        }
        // Still pending: {"result":"KO","message":"Authorization pending"}
        return nil
    }

    // MARK: - User

    func userSettings(accessToken: String) async throws -> SimklUserSettings {
        let endpoint = Endpoint(method: .get, path: "/users/settings", headers: headers(accessToken: accessToken))
        return try await decode(SimklUserSettings.self, endpoint: endpoint)
    }

    // MARK: - History (scrobble)

    func historyResponse(
        path: String, query: [URLQueryItem] = [], accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> Data {
        guard let clientID = config.clientID, !clientID.isEmpty else { throw AppError.unauthorized }
        var requestHeaders = headers(accessToken: accessToken)
        requestHeaders["User-Agent"] = "Plozz/1.0"
        var endpoint = Endpoint(
            method: .get, path: path,
            queryItems: query + [
                .init(name: "client_id", value: clientID),
                .init(name: "app-name", value: "Plozz"),
                .init(name: "app-version", value: "1.0")
            ],
            headers: requestHeaders
        )
        endpoint.maximumResponseBytes = 64 * 1_024 * 1_024
        let (data, response) = try await send(endpoint, raw: true, validate: validate)
        switch response.statusCode {
        case 200:
            guard data.count <= 64 * 1_024 * 1_024 else { throw TrackerHistoryError.incompleteSnapshot }
            return data
        case 401, 403: throw AppError.unauthorized
        case 429:
            throw AppError.rateLimited(retryAfter: SimklRequestGate.retryAfter(response))
        case 400:
            struct Failure: Decodable { let error: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.error == "max_items" {
                throw SimklHistoryReadError.maxItems
            }
            throw AppError.invalidResponse
        default: throw AppError.invalidResponse
        }
    }

    /// `POST /sync/history` — adds items to the user's watch history.
    /// Simkl deduplicates server-side; posting the same episode twice is harmless.
    func addToHistory(
        body: SimklHistoryBody, accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        let endpoint = try Endpoint(method: .post, path: "/sync/history", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        _ = try await send(endpoint, validate: validate)
    }

    // MARK: - Watchlist ("plan to watch")

    /// `GET /sync/all-items/{type}/plantowatch` — the user's plan-to-watch list.
    ///
    /// Movies and shows are separate endpoints on Simkl, so this is called once
    /// per kind and the destination merges them by `added_to_watchlist_at`.
    func planToWatch(
        type: String,
        accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> SimklListResponse {
        let endpoint = Endpoint(
            method: .get,
            path: "/sync/all-items/\(type)/plantowatch",
            queryItems: [
                URLQueryItem(name: "client_id", value: config.clientID ?? "")
            ],
            headers: headers(accessToken: accessToken)
        )
        return try await decode(SimklListResponse.self, endpoint: endpoint, validate: validate)
    }

    /// `POST /sync/add-to-list` — place titles on a list (`plantowatch` here).
    func addToList(
        body: SimklListMutationBody,
        accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        let endpoint = try Endpoint(
            method: .post,
            path: "/sync/add-to-list",
            headers: headers(accessToken: accessToken)
        ).jsonBody(body)
        _ = try await send(endpoint, validate: validate)
    }

    /// `POST /sync/remove-from-list` — take titles off every list they are on.
    func removeFromList(
        body: SimklListMutationBody,
        accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        let endpoint = try Endpoint(
            method: .post,
            path: "/sync/remove-from-list",
            headers: headers(accessToken: accessToken)
        ).jsonBody(body)
        _ = try await send(endpoint, validate: validate)
    }

    // MARK: - Real-time scrobble

    /// `POST /scrobble/{action}` — reports real-time playback (start/pause/stop).
    /// Shows "Now Watching" on the user's Simkl dashboard and auto-marks watched
    /// on stop with progress >= 80%. Returns the raw response body for diagnostics.
    @discardableResult
    func scrobble(
        action: String, body: SimklScrobbleBody, accessToken: String,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> String {
        let endpoint = try Endpoint(
            method: .post,
            path: "/scrobble/\(action)",
            queryItems: [
                URLQueryItem(name: "client_id", value: config.clientID ?? ""),
                URLQueryItem(name: "app-name", value: "Plozz"),
                URLQueryItem(name: "app-version", value: "1.0")
            ],
            headers: headers(accessToken: accessToken)
        ).jsonBody(body)
        let (data, _) = try await send(endpoint, validate: validate)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Thrown when the PIN code has expired or been consumed.
struct SimklPINExpiredError: Error {}
