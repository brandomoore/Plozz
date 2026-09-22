import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor SiloClient {
    let baseURL: URL
    let accountID: String
    let revision: CredentialRevision
    let profileID: String
    private let loginID: UUID
    private let store: any RotatingCredentialStoring
    private let http: any HTTPClient
    private var refresh: Task<SiloCredential, Error>?

    init(context: ProviderResolutionContext, store: any RotatingCredentialStoring, http: any HTTPClient) throws {
        let credential = try SiloCredential.decode(context.session.accessToken)
        guard context.session.server.provider == .silo,
              context.session.userID == "\(credential.accountID):\(credential.profileID)" else {
            throw AppError.unauthorized
        }
        baseURL = context.session.server.baseURL
        accountID = context.accountID
        revision = context.credentialRevision
        profileID = credential.profileID
        loginID = credential.loginID
        self.store = store
        self.http = http
    }

    private func currentCredential() throws -> (String, SiloCredential) {
        let raw = try store.credential(accountID: accountID, revision: revision)
        let credential = try SiloCredential.decode(raw)
        guard credential.loginID == loginID, credential.profileID == profileID else {
            throw AppError.unauthorized
        }
        return (raw, credential)
    }

    func validateLogin() throws { _ = try currentCredential() }

    func authorizedMediaURL(_ url: URL, sessionID: String) async throws -> URL {
        let credential = try await authorizedCredential()
        _ = try currentCredential()
        guard url.user == nil, url.password == nil else { throw AppError.unauthorized }
        guard let path = MediaProviderURLIdentity.relativeResourcePath(of: url, under: baseURL) else {
            // Distributed nodes retain their issued signed transport. Never
            // send this server's account bearer to another origin.
            return url
        }
        let stream = "/api/v2/stream/\(try SiloAPI.pathComponent(sessionID))"
        let hls = "/api/v2/playback/transcode/\(sessionID)/"
        guard path == stream || path.hasPrefix(stream + "/") || path.hasPrefix(hls),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil else { throw AppError.unauthorized }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let token = credential.accessToken.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw AppError.unauthorized
        }
        // Preserve the exact signed query bytes; only the account-token slot is
        // replaced. The immutable issued session keeps the chosen Silo profile.
        var fields = (components.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
        fields.removeAll {
            guard let name = $0.split(separator: "=", maxSplits: 1).first else { return false }
            return String(name).removingPercentEncoding?.lowercased() == "token"
        }
        fields.append("token=" + token)
        components.percentEncodedQuery = fields.joined(separator: "&")
        guard let authorized = components.url else { throw AppError.invalidResponse }
        return authorized
    }

    func downloadHeaders(deviceID: String) async throws -> [String: String] {
        let credential = try await authorizedCredential()
        _ = try currentCredential()
        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "X-Profile-Id": credential.profileID,
            "X-Silo-Device-Id": deviceID
        ]
        if let proof = credential.profileToken { headers["X-Profile-Token"] = proof }
        return headers
    }

    private func authorizedCredential(rejectedToken: String? = nil) async throws -> SiloCredential {
        if let refresh { return try await refresh.value }
        let (raw, credential) = try currentCredential()
        guard credential.refreshPending != true else { throw AppError.unauthorized }
        if let rejectedToken, credential.accessToken != rejectedToken { return credential }
        guard rejectedToken != nil || credential.expiresAt.timeIntervalSinceNow < 60 else { return credential }
        var pending = credential
        pending.refreshPending = true
        let pendingRaw = try pending.encoded()
        try store.rotateCredential(accountID: accountID, revision: revision, expected: raw, replacement: pendingRaw)
        let task = Task { [http, baseURL, store, accountID, revision] in
            struct Body: Encodable { let refresh_token: String }
            struct Refreshed: Decodable {
                let access_token: String
                let refresh_token: String
                let expires_in: Int
            }
            let endpoint = try SiloAPI.endpoint("/auth/refresh", method: .post)
                .jsonBody(Body(refresh_token: credential.refreshToken))
            // A refresh rotates credentials; never replay an uncertain exchange.
            let result = try await http.decode(Refreshed.self, from: endpoint, baseURL: baseURL, decoder: JSONDecoder())
            guard !result.access_token.isEmpty, !result.refresh_token.isEmpty, result.expires_in > 0 else {
                throw AppError.invalidResponse
            }
            var updated = credential
            updated.accessToken = result.access_token
            updated.refreshToken = result.refresh_token
            updated.expiresAt = Date().addingTimeInterval(TimeInterval(result.expires_in))
            updated.refreshPending = false
            try store.rotateCredential(accountID: accountID, revision: revision,
                                       expected: pendingRaw, replacement: updated.encoded())
            return updated
        }
        refresh = task
        defer { refresh = nil }
        return try await task.value
    }

    func request<T: Decodable & Sendable>(
        _ path: String, method: HTTPMethod = .get, query: [URLQueryItem] = [], body: Data? = nil,
        deviceID: String? = nil
    ) async throws -> T {
        let (data, _) = try await send(path, method: method, query: query, body: body, deviceID: deviceID)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            PlozzLog.networking.error("Silo response did not match \(String(describing: T.self))")
            throw AppError.decoding
        }
    }

    @discardableResult
    func send(
        _ path: String, method: HTTPMethod = .get, query: [URLQueryItem] = [], body: Data? = nil,
        deviceID: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let credential = try await authorizedCredential()
        _ = try currentCredential()
        var endpoint = SiloAPI.endpoint(path, method: method, query: query, token: credential.accessToken,
                                        profileID: credential.profileID, profileToken: credential.profileToken)
        endpoint.body = body
        if let deviceID { endpoint.headers["X-Silo-Device-Id"] = deviceID }
        if body != nil { endpoint.headers["Content-Type"] = "application/json" }
        var result = try await http.sendRaw(endpoint, baseURL: baseURL)
        if result.1.statusCode == 401, method == .get {
            let refreshed = try await authorizedCredential(rejectedToken: credential.accessToken)
            endpoint.headers["Authorization"] = "Bearer \(refreshed.accessToken)"
            result = try await http.sendRaw(endpoint, baseURL: baseURL)
        }
        if !(200...299).contains(result.1.statusCode) {
            let operation = path.hasPrefix("/catalog/items/") ? "catalog/item"
                : path.hasPrefix("/playback/") && path != "/playback/start" && path != "/playback/capabilities"
                    ? "playback/session" : path
            struct Problem: Decodable {
                struct Field: Decodable { let location: String; let code: String }
                let type: String?
                let errors: [Field]?
            }
            let problem = try? JSONDecoder().decode(Problem.self, from: result.0)
            let code = problem?.type.flatMap { URL(string: $0)?.lastPathComponent }
            let safeCode = code.flatMap { value -> String? in
                guard value.count <= 80, value.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }) else { return nil }
                return value
            } ?? "unclassified"
            let fields = (problem?.errors ?? []).prefix(6).compactMap { field -> String? in
                let value = field.location + ":" + field.code
                guard value.count <= 180, value.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [UInt8(45), 46, 58, 91, 93, 95].contains($0)
                }) else { return nil }
                return value
            }.joined(separator: ",")
            HandoffDiagnostics.emit("silo api rejected operation=\(operation) status=\(result.1.statusCode) problem=\(safeCode) fields=\(fields)")
        }
        switch result.1.statusCode {
        case 200...299: break
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        case 409, 412: throw AppError.conflict
        case 429:
            throw AppError.rateLimited(retryAfter: result.1.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        default: throw AppError.invalidResponse
        }
        try Task.checkCancellation()
        _ = try currentCredential()
        return result
    }
}
