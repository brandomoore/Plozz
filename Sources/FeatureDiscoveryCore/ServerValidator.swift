import Foundation
import CoreModels
import CoreNetworking

/// Validates a manually-entered server URL by hitting Jellyfin's public
/// system-info endpoint. Provider-light on purpose: it depends only on
/// `CoreNetworking` so the discovery feature doesn't pull in a provider.
public struct ServerValidator: Sendable {
    private let http: HTTPClient
    private let provider: ProviderKind

    public init(
        provider: ProviderKind = .jellyfin,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.provider = provider
        self.http = http
    }

    private struct PublicInfo: Decodable {
        let Id: String?
        let ServerName: String?
        let Version: String?
        let ProductName: String?
    }

    private struct SiloInfo: Decodable {
        let api_major: Int
        let server_version: String
        let contract_digest: String
    }

    private struct SiloPairingCapability: Decodable {
        let protocol_versions: [Int]
        let state: String
    }

    /// Normalises `rawURL`, confirms a Jellyfin server answers, and returns a
    /// fully-identified `MediaServer`.
    ///
    /// Throws `.serverUnreachable` / `.invalidResponse` on failure so the UI can
    /// show a friendly message.
    public func validate(rawURL: String) async throws -> MediaServer {
        guard let baseURL = ServerURLNormalizer.normalize(rawURL, defaultPort: provider == .silo ? 8090 : 8096) else {
            throw AppError.invalidResponse
        }
        if provider == .silo {
            guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
                  baseURL.user == nil, baseURL.password == nil,
                  baseURL.query == nil, baseURL.fragment == nil else { throw AppError.invalidResponse }
            let info = try await http.decode(SiloInfo.self, from: Endpoint(
                path: "/api/v2/system/info", redirectPolicy: .sameOrigin), baseURL: baseURL)
            guard info.api_major == 2, !info.contract_digest.isEmpty else { throw AppError.invalidResponse }
            let capability = try await http.decode(SiloPairingCapability.self, from: Endpoint(
                path: "/api/v2/auth/device/capability", redirectPolicy: .sameOrigin), baseURL: baseURL)
            guard capability.protocol_versions.contains(2),
                  ["available", "disabled", "not_configured", "unsupported"].contains(capability.state) else {
                throw AppError.invalidResponse
            }
            return MediaServer(id: baseURL.absoluteString, name: "Silo", baseURL: baseURL,
                               provider: .silo, version: info.server_version)
        }
        let endpoint = Endpoint(path: "/System/Info/Public")
        let info = try await http.decode(PublicInfo.self, from: endpoint, baseURL: baseURL)
        // Guard against non-Jellyfin endpoints answering with arbitrary JSON.
        guard info.Id != nil || info.ServerName != nil || info.ProductName != nil else {
            throw AppError.invalidResponse
        }
        return MediaServer(
            id: info.Id ?? baseURL.absoluteString,
            name: info.ServerName ?? baseURL.host ?? "\(provider.displayName) Server",
            baseURL: baseURL,
            provider: provider,
            version: info.Version
        )
    }

    /// Lightweight reachability check for an already-known server: returns
    /// `true` if the server answers its public system-info endpoint right now.
    ///
    /// Used to tell the user whether a saved server is actually online, even
    /// when UDP broadcast discovery turns up nothing (blocked broadcasts,
    /// different subnet, lossy Wi-Fi, etc.).
    public func isReachable(_ baseURL: URL) async -> Bool {
        if provider == .silo {
            return (try? await validate(rawURL: baseURL.absoluteString)) != nil
        }
        let endpoint = Endpoint(path: "/System/Info/Public")
        do {
            _ = try await http.send(endpoint, baseURL: baseURL)
            return true
        } catch {
            return false
        }
    }
}
