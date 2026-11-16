import CoreModels
import CoreNetworking
import Foundation

public struct SeerLoginMethods: Decodable, Sendable, Hashable {
    public var initialized: Bool?
    public var mediaServerType: Int?
    public var mediaServerLogin: Bool?
    public var localLogin: Bool?
    public var jellyfinQuickConnect: Bool?
}

public struct SeerAuthenticatedAccount: Sendable {
    public let baseURL: URL
    public let credential: SeerAccountConnection.Credential
    public let user: SeerUser
    public var mediaUserID: String?
}

/// A fresh, cookie-isolated login transaction. Passwords are never persisted.
public actor SeerAuthentication {
    public enum Failure: Error, Equatable {
        case quickConnectUnavailable
    }

    private let baseURL: URL
    private let http: HTTPClient
    private var cookies: [String: String] = [:]
    private var expiry = Date().addingTimeInterval(30 * 86_400)

    public init(baseURL: URL, http: HTTPClient = SeerAuthentication.makeHTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    public nonisolated static func makeHTTPClient(timeout: TimeInterval = 30) -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = min(20, timeout)
        configuration.timeoutIntervalForResource = timeout
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }

    public func methods() async throws -> SeerLoginMethods {
        let value = try await decoded(SeerLoginMethods.self, endpoint: Endpoint(path: "/api/v1/settings/public"))
        guard value.initialized == true else { throw AppError.invalidResponse }
        return value
    }

    public func setupMethods() async throws -> SeerLoginMethods {
        try await checkingQuickConnectSupport(for: methods())
    }

    func checkingQuickConnectSupport(for methods: SeerLoginMethods) async throws -> SeerLoginMethods {
        var value = methods
        guard value.mediaServerLogin == true, value.mediaServerType == 2 else { return value }
        let endpoint = Endpoint(
            path: "/api/v1/auth/jellyfin/quickconnect/check",
            redirectPolicy: .sameOrigin, allowsAutomaticAddressRetry: false
        )
        let (_, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        try Task.checkCancellation()
        switch response.statusCode {
        // A missing secret is rejected before this read-only route contacts Jellyfin.
        case 400: value.jellyfinQuickConnect = true
        case 404: value.jellyfinQuickConnect = false
        case 401, 403: throw AppError.unauthorized
        default: throw AppError.invalidResponse
        }
        return value
    }

    public func password(username: String, password: String, local: Bool) async throws -> SeerAuthenticatedAccount {
        let methods = try await methods()
        if local {
            guard methods.localLogin == true else { throw AppError.unauthorized }
        } else {
            guard methods.mediaServerLogin == true,
                  methods.mediaServerType == 2 || methods.mediaServerType == 3 else { throw AppError.unauthorized }
        }
        let body = local ? ["email": username, "password": password] : ["username": username, "password": password]
        _ = try await send(try Endpoint(method: .post, path: local ? "/api/v1/auth/local" : "/api/v1/auth/jellyfin").jsonBody(body))
        return try await authenticated()
    }

    public func plex(token: String) async throws -> SeerAuthenticatedAccount {
        let methods = try await methods()
        guard methods.mediaServerLogin == true, methods.mediaServerType == 1 else { throw AppError.unauthorized }
        _ = try await send(try Endpoint(method: .post, path: "/api/v1/auth/plex").jsonBody(["authToken": token]))
        return try await authenticated()
    }

    public func jellyfin(
        approve: @Sendable (String) async throws -> Void
    ) async throws -> SeerAuthenticatedAccount {
        let methods = try await methods()
        guard methods.mediaServerLogin == true, methods.mediaServerType == 2 else { throw AppError.unauthorized }
        struct Challenge: Decodable { let code: String; let secret: String }
        let challenge: Challenge
        do {
            challenge = try await decoded(Challenge.self, endpoint: Endpoint(method: .post, path: "/api/v1/auth/jellyfin/quickconnect/initiate"))
        } catch AppError.notFound {
            throw Failure.quickConnectUnavailable
        }
        try Task.checkCancellation()
        try await approve(challenge.code)
        try Task.checkCancellation()
        _ = try await send(try Endpoint(method: .post, path: "/api/v1/auth/jellyfin/quickconnect/authenticate").jsonBody(["secret": challenge.secret]))
        return try await authenticated()
    }

    public func apiKey(_ key: String) async throws -> SeerAuthenticatedAccount {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.unauthorized }
        _ = try await methods()
        let dto = try await decoded(SeerUserDTO.self, endpoint: Endpoint(path: "/api/v1/auth/me", headers: ["X-Api-Key": key]))
        guard dto.id > 0 else { throw AppError.invalidResponse }
        let user = SeerUser.from(dto, baseURL: baseURL, serverIdentity: SeerServerIdentity(baseURL: baseURL))
        return .init(baseURL: baseURL, credential: .apiKey(key: key, userID: nil, userName: user.name), user: user)
    }

    private func authenticated() async throws -> SeerAuthenticatedAccount {
        try Task.checkCancellation()
        let dto = try await decoded(SeerUserDTO.self, endpoint: Endpoint(path: "/api/v1/auth/me"))
        guard dto.id > 0, let sessionCookie = cookies["connect.sid"], !sessionCookie.isEmpty,
              let permissions = dto.permissions else { throw AppError.invalidResponse }
        let user = SeerUser.from(dto, baseURL: baseURL, serverIdentity: SeerServerIdentity(baseURL: baseURL))
        let session = SeerSessionCredential(
            cookie: cookieHeader, csrfToken: cookies["XSRF-TOKEN"]?.removingPercentEncoding,
            userID: user.id, name: user.name, permissions: permissions, expiresAt: expiry
        )
        return .init(
            baseURL: baseURL, credential: .session(session), user: user,
            mediaUserID: dto.jellyfinUserId ?? dto.plexId.map(String.init)
        )
    }

    private var cookieHeader: String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func decoded<T: Decodable>(_ type: T.Type, endpoint: Endpoint) async throws -> T {
        let data = try await send(endpoint)
        return try JSONDecoder().decode(type, from: data)
    }

    private func send(_ endpoint: Endpoint) async throws -> Data {
        guard SeerServerIdentity(baseURL: baseURL) != nil else { throw AppError.invalidResponse }
        try Task.checkCancellation()
        var endpoint = endpoint
        endpoint.redirectPolicy = .sameOrigin
        endpoint.allowsAutomaticAddressRetry = false
        endpoint.headers["Cookie"] = cookieHeader
        if let token = cookies["XSRF-TOKEN"]?.removingPercentEncoding { endpoint.headers["X-XSRF-TOKEN"] = token }
        let (data, response) = try await http.sendRaw(endpoint, baseURL: baseURL)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let apiURL = baseURL.appendingPathComponent("api/v1/")
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url ?? apiURL)
            where ["connect.sid", "_csrf", "XSRF-TOKEN"].contains(cookie.name) {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = baseURL.host?.lowercased() ?? ""
            let path = apiURL.path
            guard host == domain || host.hasSuffix("." + domain),
                  !cookie.isSecure || baseURL.scheme?.lowercased() == "https",
                  path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            else { continue }
            if let expires = cookie.expiresDate, expires <= Date() {
                cookies.removeValue(forKey: cookie.name)
                continue
            }
            cookies[cookie.name] = cookie.value
            if let expires = cookie.expiresDate { expiry = min(expiry, expires) }
        }
        switch response.statusCode {
        case 200...299: return data
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        default: throw AppError.invalidResponse
        }
    }
}

/// All Seerr traffic uses the selected credential and refuses cross-origin redirects.
struct SeerCredentialHTTPClient: HTTPClient {
    let underlying: HTTPClient
    let config: SeerConfig

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try validateDestination(endpoint, baseURL: baseURL)
        return try await underlying.send(try authenticated(endpoint), baseURL: baseURL)
    }
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try validateDestination(endpoint, baseURL: baseURL)
        return try await underlying.sendRaw(try authenticated(endpoint), baseURL: baseURL)
    }
    private func validateDestination(_ endpoint: Endpoint, baseURL: URL) throws {
        guard config.baseURL.flatMap(SeerServerIdentity.init(baseURL:)) == SeerServerIdentity(baseURL: baseURL),
              endpoint.path.hasPrefix("/api/v1/"),
              !endpoint.path.contains("..") else { throw AppError.unauthorized }
    }
    private func authenticated(_ endpoint: Endpoint) throws -> Endpoint {
        var result = endpoint
        result.redirectPolicy = .sameOrigin
        result.allowsAutomaticAddressRetry = false
        if let session = config.session {
            guard session.expiresAt > Date() else { throw AppError.unauthorized }
            result.headers.removeValue(forKey: "X-Api-Key")
            result.headers.removeValue(forKey: "X-API-User")
            result.headers["Cookie"] = session.cookie
            result.headers["X-XSRF-TOKEN"] = session.csrfToken
        }
        return result
    }
}
