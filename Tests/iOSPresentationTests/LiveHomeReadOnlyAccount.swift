#if os(iOS)
import CoreModels
import CoreNetworking
import Foundation
import ProviderJellyfin
import ProviderPlex
import XCTest

enum LiveHomeReadOnlyAccount {
    static func broker() throws -> URL {
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_ROWS_BROKER"] else {
            throw XCTSkip("Requires an authorized, read-only internal Home broker.")
        }
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AppError.invalidResponse
        }
        return url
    }

    static func connect(_ kind: ProviderKind, http: LiveHomeReadOnlyHTTP) async throws -> ResolvedAccount {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: try broker().appendingPathComponent(kind.rawValue), timeoutInterval: 15
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard ["http", "https"].contains(config.baseURL.scheme), config.baseURL.host != nil,
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil, !config.token.isEmpty else {
            throw AppError.invalidResponse
        }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal Home", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        let accountID = "live-\(kind.rawValue)"
        let provider: any MediaProvider = kind == .plex
            ? PlexProvider(session: session, accountID: accountID, http: http)
            : JellyfinProvider(session: session, accountID: accountID, http: http)
        return ResolvedAccount(account: Account(id: accountID, from: session), provider: provider)
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
    }
}

actor LiveHomeReadOnlyHTTP: HTTPClient {
    private let wrapped = URLSessionHTTPClient()
    private var reads = 0
    private var blocked = 0

    func counts() -> (reads: Int, blocked: Int) { (reads, blocked) }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let path = endpoint.path.lowercased()
        guard endpoint.method == .get, endpoint.body == nil,
              !path.contains("/:/"), !path.contains("playbackinfo"),
              !path.contains("transcode"), !path.contains("/sessions") else {
            blocked += 1
            throw AppError.invalidResponse
        }
        reads += 1
        return try await wrapped.send(endpoint, baseURL: baseURL)
    }
}
#endif
