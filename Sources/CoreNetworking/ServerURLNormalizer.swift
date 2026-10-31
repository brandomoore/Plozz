import Foundation
import CoreModels

/// Helpers for turning messy user/discovery input into a usable base URL.
public enum ServerURLNormalizer {
    /// Credential-free manual discovery only; never reinterpret saved routes.
    /// Explicit HTTPS and ports are authoritative. Otherwise prefer HTTPS,
    /// followed by the legacy HTTP address and the other conventional HTTP port.
    public static func manualConnectionCandidates(_ raw: String, defaultPort: Int = 8096) throws -> [URL] {
        guard let parsed = normalize(raw, defaultPort: nil),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              (1...65535).contains(defaultPort) else { throw AppError.invalidResponse }
        components.scheme = scheme
        guard let original = components.url else { throw AppError.invalidResponse }
        guard scheme != "https" else { return [original] }

        components.scheme = "https"
        guard let secure = components.url else { throw AppError.invalidResponse }
        if components.port != nil { return [secure, original] }

        components.scheme = "http"
        components.port = defaultPort
        guard let direct = components.url else { throw AppError.invalidResponse }
        let http = raw.contains("://") ? [original, direct] : [direct, original]
        return ([secure] + http).reduce(into: []) { urls, url in
            if !urls.contains(url) { urls.append(url) }
        }
    }

    /// Only credential-free discovery may resolve a new API base. Authenticated
    /// requests continue to use the strict same-origin transport policy.
    public static func resolvedBaseURL(
        requested: URL, responseURL: URL?, endpointPath: String
    ) throws -> URL {
        guard let responseURL,
              var response = URLComponents(url: responseURL, resolvingAgainstBaseURL: false),
              let original = URLComponents(url: requested, resolvingAgainstBaseURL: false),
              original.user == nil, original.password == nil,
              original.query == nil, original.fragment == nil,
              response.user == nil, response.password == nil,
              response.query == nil, response.fragment == nil,
              let originalScheme = original.scheme, let originalHost = original.host,
              let responseScheme = response.scheme, let responseHost = response.host,
              let originalOrigin = try? NetworkOrigin(
                scheme: originalScheme, host: originalHost, port: original.port
              ),
              let responseOrigin = try? NetworkOrigin(
                scheme: responseScheme, host: responseHost, port: response.port
              ),
              originalOrigin == responseOrigin || (
                originalOrigin.scheme == "http" && responseOrigin.scheme == "https"
                    && originalOrigin.host == responseOrigin.host
              ) else { throw AppError.invalidResponse }
        guard !endpointPath.isEmpty, response.percentEncodedPath.hasSuffix(endpointPath) else {
            throw AppError.invalidResponse
        }
        response.percentEncodedPath = String(response.percentEncodedPath.dropLast(endpointPath.count))
        guard let resolved = response.url else { throw AppError.invalidResponse }
        return resolved
    }

    /// Normalises a user-entered host/URL into a canonical base `URL`.
    ///
    /// Rules:
    ///  * adds a scheme (`http://`) when none is present;
    ///  * defaults to `defaultPort` for scheme-less `http` hosts with no explicit
    ///    port (e.g. Jellyfin's `8096`, Overseerr/Jellyseerr's `5055`);
    ///  * strips trailing slashes;
    ///  * returns `nil` for input that can't form a valid host.
    ///
    /// Examples (`defaultPort: 8096`):
    ///  * `192.168.1.5`       → `http://192.168.1.5:8096`
    ///  * `jelly.example.com` → `http://jelly.example.com:8096`
    ///  * `https://m.tld/jf/` → `https://m.tld/jf`
    public static func normalize(_ raw: String, defaultPort: Int? = 8096) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hadScheme = trimmed.contains("://")
        // Preserve legacy normalization for saved addresses and service URLs.
        // Manual connection discovery tries alternatives before sign-in.
        let withScheme = hadScheme ? trimmed : "http://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Apply the service's default port only when the user typed a bare host
        // over plain http with no explicit port.
        if !hadScheme, components.port == nil, components.scheme == "http", let defaultPort {
            components.port = defaultPort
        }

        // Strip trailing slash from the path for a canonical form.
        if components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast())
        }

        return components.url
    }
}
