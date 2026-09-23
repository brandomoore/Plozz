import Foundation
import CoreModels
import CoreNetworking

public enum SiloAuthenticationError: Error, Sendable {
    case unsupportedServer
    case pairingUnavailable
    case incorrectPIN
    case pairingDenied
}

public struct SiloCredential: Codable, Sendable, CustomStringConvertible {
    public let loginID: UUID
    public let accountID: String
    public let profileID: String
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public let profileToken: String?
    public var refreshPending: Bool?

    public var description: String { "SiloCredential(<redacted>)" }

    public init(tokens: SiloTokenPair, profile: SiloProfile, profileToken: String?) {
        loginID = UUID()
        accountID = tokens.user.id
        profileID = profile.id
        accessToken = tokens.access_token
        refreshToken = tokens.refresh_token
        expiresAt = tokens.receivedAt.addingTimeInterval(TimeInterval(tokens.expires_in))
        self.profileToken = profileToken
    }

    public func encoded() throws -> String {
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
            throw AppError.invalidResponse
        }
        return value
    }

    public static func decode(_ value: String) throws -> Self {
        guard let data = value.data(using: .utf8) else { throw AppError.unauthorized }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw AppError.unauthorized }
    }
}

public struct SiloAccountIdentity: Decodable, Sendable {
    public let id: String
    public let username: String
}

public struct SiloTokenPair: Decodable, Sendable, CustomStringConvertible {
    public let receivedAt = Date()
    public let access_token: String
    public let refresh_token: String
    public let expires_in: Int
    public let user: SiloAccountIdentity
    public var description: String { "SiloTokenPair(<redacted>)" }
}

public struct SiloProfile: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let has_pin: Bool
    public let is_child: Bool
}

public struct SiloDeviceChallenge: Decodable, Sendable, CustomStringConvertible {
    public let device_code: String
    public let user_code: String
    public let match_code: String
    public let verification_uri: String
    public let verification_uri_complete: String
    public let expires_in: Int
    public let interval: Int
    public var description: String { "SiloDeviceChallenge(<redacted>)" }
}

public struct SiloDevicePoll: Decodable, Sendable, CustomStringConvertible {
    public let status: String
    public let poll_after: Int
    public let temporary: Bool
    public let tokens: SiloTokenPair?
    public var description: String { "SiloDevicePoll(status: \(status), credentials: <redacted>)" }
}

public struct SiloAuthentication: Sendable {
    public let baseURL: URL
    let http: any HTTPClient

    public init(baseURL: URL, http: any HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.http = http
    }

    public func validateServer() async throws {
        struct Info: Decodable { let api_major: Int }
        do {
            let info: Info = try await request("/system/info")
            guard info.api_major == 2 else { throw SiloAuthenticationError.unsupportedServer }
        } catch AppError.notFound {
            throw SiloAuthenticationError.unsupportedServer
        }
    }

    public func beginPairing(platform: String) async throws -> SiloDeviceChallenge {
        struct Capability: Decodable {
            let state: String
            let protocol_versions: [Int]
            let allowed: Bool?
        }
        let capability: Capability = try await request("/auth/device/capability")
        guard capability.state == "available", capability.allowed != false,
              capability.protocol_versions.contains(2) else {
            throw SiloAuthenticationError.pairingUnavailable
        }
        struct Body: Encodable {
            let device_name = "Plozz"
            let device_platform: String
            let client_purpose = "device_login"
            let temporary = false
        }
        return try await request("/auth/device/start", method: .post, body: Body(device_platform: platform))
    }

    public func poll(_ challenge: SiloDeviceChallenge) async throws -> SiloDevicePoll {
        struct Body: Encodable { let device_code: String }
        return try await request("/auth/device/poll", method: .post, body: Body(device_code: challenge.device_code))
    }

    public func profiles(token: String) async throws -> [SiloProfile] {
        var profiles: [SiloProfile] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page: SiloCollection<SiloProfile> = try await request(
                "/profiles", token: token,
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            profiles += page.items
            cursor = try page.nextCursor()
            if let cursor, !seen.insert(cursor).inserted { throw AppError.invalidResponse }
        } while cursor != nil
        return profiles
    }

    public func verifyPIN(_ pin: String, profile: SiloProfile, token: String) async throws -> String? {
        struct Body: Encodable { let pin: String }
        struct Verification: Decodable { let valid: Bool; let profile_token: String? }
        let result: Verification = try await request(
            "/profiles/\(try SiloAPI.pathComponent(profile.id))/verify-pin",
            method: .post, body: Body(pin: pin), token: token)
        guard result.valid, let proof = result.profile_token, !proof.isEmpty else {
            throw SiloAuthenticationError.incorrectPIN
        }
        return proof
    }

    public func makeSession(
        tokens: SiloTokenPair, profile: SiloProfile, profileToken: String?, deviceID: String
    ) async throws -> UserSession {
        guard !profile.has_pin || profileToken?.isEmpty == false else { throw AppError.unauthorized }
        let credential = SiloCredential(tokens: tokens, profile: profile, profileToken: profileToken)
        let capabilities: SiloPlaybackCapabilities = try await request(
            "/playback/capabilities", token: tokens.access_token,
            profileID: profile.id, profileToken: profileToken)
        guard let installationID = capabilities.installation_id, !installationID.isEmpty else {
            throw AppError.invalidResponse
        }
        return UserSession(
            server: MediaServer(id: installationID, name: baseURL.host ?? "Silo", baseURL: baseURL, provider: .silo),
            userID: "\(tokens.user.id):\(profile.id)",
            userName: profile.name,
            deviceID: deviceID,
            accessToken: try credential.encoded())
    }

    func request<T: Decodable>(
        _ path: String, token: String? = nil, profileID: String? = nil,
        profileToken: String? = nil, query: [URLQueryItem] = []
    ) async throws -> T {
        let endpoint = SiloAPI.endpoint(path, query: query, token: token, profileID: profileID, profileToken: profileToken)
        return try await http.decode(T.self, from: endpoint, baseURL: baseURL, decoder: JSONDecoder())
    }

    func request<T: Decodable, B: Encodable>(
        _ path: String, method: HTTPMethod, body: B, token: String? = nil
    ) async throws -> T {
        let endpoint = try SiloAPI.endpoint(path, method: method, token: token).jsonBody(body)
        return try await http.decode(T.self, from: endpoint, baseURL: baseURL, decoder: JSONDecoder())
    }
}

enum SiloAPI {
    static func endpoint(
        _ path: String, method: HTTPMethod = .get, query: [URLQueryItem] = [],
        token: String? = nil, profileID: String? = nil, profileToken: String? = nil
    ) -> Endpoint {
        var headers = ["Accept": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let profileID { headers["X-Profile-Id"] = profileID }
        if let profileToken { headers["X-Profile-Token"] = profileToken }
        return Endpoint(method: method, path: "/api/v2" + path, queryItems: query,
                        headers: headers, redirectPolicy: .sameOrigin)
    }

    static func pathComponent(_ id: String) throws -> String {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != "..",
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError.invalidResponse
        }
        return id
    }
}

struct SiloPage: Decodable, Sendable {
    let has_more: Bool
    let next_cursor: String?
}

struct SiloCollection<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let page: SiloPage?

    func nextCursor() throws -> String? {
        guard page?.has_more == true else { return nil }
        guard let cursor = page?.next_cursor, !cursor.isEmpty else { throw AppError.invalidResponse }
        return cursor
    }
}

struct SiloPlaybackCapabilities: Decodable, Sendable {
    let installation_id: String?
    let protocol_versions: [Int]
    let features: [String]
    let deliveries: [String]
    let state: String
    let allowed: Bool
}
