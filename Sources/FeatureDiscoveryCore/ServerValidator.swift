import Foundation
import CoreModels
import CoreNetworking

/// Validates a manually-entered server URL by hitting Jellyfin's public
/// system-info endpoint. Provider-light on purpose: it depends only on
/// `CoreNetworking` so the discovery feature doesn't pull in a provider.
public struct ServerValidator: Sendable {
    private let http: HTTPClient
    private let manualHTTP: HTTPClient
    private let provider: ProviderKind
    private let diagnostics: ServerConnectionDiagnostics

    public init(
        provider: ProviderKind = .jellyfin,
        http: HTTPClient? = nil,
        diagnostics: ServerConnectionDiagnostics = .shared
    ) {
        self.provider = provider
        self.diagnostics = diagnostics
        self.http = http ?? URLSessionHTTPClient()
        self.manualHTTP = http ?? URLSessionHTTPClient(session: .plozzDiscovery)
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
        guard provider == .jellyfin || provider == .emby else {
            return try await validate(rawURL: rawURL, http: http, reportsServerTrustFailures: false)
        }
        return try await diagnostics.capture(
            provider: provider, stage: .addressValidation,
            baseURL: ServerURLNormalizer.normalize(rawURL, defaultPort: 8096)
        ) {
            try await validate(rawURL: rawURL, http: http, reportsServerTrustFailures: false)
        }
    }

    /// Resolves a new manual entry before credentials are requested. At most
    /// three public probes use the short discovery timeout; saved routes and
    /// UDP announcements continue to use exact-address validation.
    public func resolveManualAddress(_ rawURL: String) async throws -> MediaServer {
        guard provider == .jellyfin || provider == .emby else {
            return try await validate(rawURL: rawURL)
        }
        let candidates = try ServerURLNormalizer.manualConnectionCandidates(rawURL)
        var firstFailure: AppError?
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                let server = try await diagnostics.capture(
                    provider: provider, stage: .addressValidation, baseURL: candidate, candidate: index + 1
                ) {
                    try await validate(
                        rawURL: candidate.absoluteString, http: manualHTTP, reportsServerTrustFailures: true
                    )
                }
                try Task.checkCancellation()
                PlozzLog.discovery.info("Manual server address validated attempt=\(index + 1) scheme=\(server.baseURL.scheme ?? "")")
                return server
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || error as? AppError == .cancelled {
                    throw AppError.cancelled
                }
                if error is HTTPServerTrustFailure {
                    PlozzLog.discovery.error("Manual server discovery stopped after TLS trust rejection")
                    throw AppError.serverUnreachable
                }
                guard let failure = error as? AppError else { throw error }
                switch failure {
                case .serverUnreachable, .notFound, .invalidResponse, .decoding:
                    firstFailure = firstFailure ?? failure
                    PlozzLog.discovery.debug("Manual server probe failed attempt=\(index + 1) scheme=\(candidate.scheme ?? "")")
                default:
                    throw failure
                }
            }
        }
        PlozzLog.discovery.error("Manual server discovery found no usable address")
        throw firstFailure ?? AppError.serverUnreachable
    }

    private func validate(
        rawURL: String, http: HTTPClient, reportsServerTrustFailures: Bool
    ) async throws -> MediaServer {
        guard let baseURL = ServerURLNormalizer.normalize(rawURL, defaultPort: provider == .silo ? 8090 : 8096) else {
            throw AppError.invalidResponse
        }
        if provider == .silo {
            guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
                  baseURL.user == nil, baseURL.password == nil,
                  baseURL.query == nil, baseURL.fragment == nil else { throw AppError.invalidResponse }
            let info = try await SiloSetupRequest.decode(SiloInfo.self, endpoint: Endpoint(
                path: "/api/v2/system/info", redirectPolicy: .sameOrigin),
                baseURL: baseURL, http: http, stage: .validation)
            guard info.api_major == 2, !info.contract_digest.isEmpty else { throw AppError.invalidResponse }
            let capability = try await SiloSetupRequest.decode(SiloPairingCapability.self, endpoint: Endpoint(
                path: "/api/v2/auth/device/capability", redirectPolicy: .sameOrigin),
                baseURL: baseURL, http: http, stage: .capability)
            guard capability.protocol_versions.contains(2),
                  ["available", "disabled", "not_configured", "unsupported"].contains(capability.state) else {
                throw AppError.invalidResponse
            }
            return MediaServer(id: baseURL.absoluteString, name: "Silo", baseURL: baseURL,
                               provider: .silo, version: info.server_version)
        }
        var endpoint = Endpoint(path: "/System/Info/Public")
        endpoint.reportsServerTrustFailures = reportsServerTrustFailures
        let (info, response) = try await http.decodeResponse(PublicInfo.self, from: endpoint, baseURL: baseURL)
        let resolvedURL = try ServerURLNormalizer.resolvedBaseURL(
            requested: baseURL, responseURL: response.url, endpointPath: endpoint.path
        )
        // Guard against non-Jellyfin endpoints answering with arbitrary JSON.
        guard info.Id != nil || info.ServerName != nil || info.ProductName != nil else {
            throw AppError.invalidResponse
        }
        return MediaServer(
            id: info.Id ?? resolvedURL.absoluteString,
            name: info.ServerName ?? resolvedURL.host ?? "\(provider.displayName) Server",
            baseURL: resolvedURL,
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
