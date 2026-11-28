import CryptoKit
import Foundation

/// Stored only in the account's Keychain token, never in account/profile metadata.
public struct IPTVCredential: Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case playlist, xtream, file
    }

    public let mode: Mode
    public let address: URL
    public let username: String
    public let password: String
    public let headers: [String: String]
    public let guideURL: URL?
    private let additionalGuideURLs: [URL]?
    private let configuredGuideHeaders: [String: String]?
    private let discoversPlaylistGuides: Bool?
    /// Optional backup/mirror portal URLs for Xtream accounts; absent in older credentials.
    private var configuredAlternateAddresses: [URL]?
    public let identity: UUID
    public let catalogKey: Data

    public static let maximumAlternateAddresses = 15

    public init(
        mode: Mode, address: URL, username: String = "", password: String = "",
        headers: [String: String] = [:], guideURL: URL? = nil,
        additionalGuideURLs: [URL] = [], guideHeaders: [String: String] = [:],
        discoversPlaylistGuides: Bool = true,
        alternateAddresses: [URL] = [],
        identity: UUID = UUID()
    ) throws {
        guard let parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.fragment == nil,
              guideURL.map({ LiveTVPlaylistSource.isSupportedURL($0) }) != false,
              additionalGuideURLs.allSatisfy(LiveTVPlaylistSource.isSupportedURL),
              additionalGuideURLs.count < 32,
              guideURL != nil || guideHeaders.isEmpty,
              mode != .xtream || (!username.isEmpty && !password.isEmpty),
              mode == .xtream || alternateAddresses.isEmpty else {
            throw AppError.invalidResponse
        }
        var clean = parts
        if mode == .xtream {
            if clean.path.lowercased().hasSuffix(".php") {
                clean.path = (clean.path as NSString).deletingLastPathComponent
            }
            while clean.path.hasSuffix("/") { clean.path.removeLast() }
            clean.query = nil
        }
        var resolvedHeaders = headers
        if let user = parts.user {
            guard mode == .playlist,
                  !headers.keys.contains(where: { $0.lowercased() == "authorization" }) else {
                throw AppError.invalidResponse
            }
            resolvedHeaders["Authorization"] = "Basic " + Data(
                (user + ":" + (parts.password ?? "")).utf8
            ).base64EncodedString()
            clean.user = nil
            clean.password = nil
        }
        guard let url = clean.url else { throw AppError.invalidResponse }
        let normalizedAlternates = try Self.normalizeAlternateAddresses(alternateAddresses, primary: url)
        try Self.validate(headers: resolvedHeaders)
        try Self.validate(headers: guideHeaders)
        self.mode = mode
        self.address = url
        self.username = username
        self.password = password
        self.headers = resolvedHeaders
        self.guideURL = guideURL
        self.additionalGuideURLs = additionalGuideURLs
        configuredGuideHeaders = guideHeaders
        self.discoversPlaylistGuides = discoversPlaylistGuides
        configuredAlternateAddresses = normalizedAlternates.isEmpty ? nil : normalizedAlternates
        self.identity = identity
        catalogKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public var description: String { "IPTVCredential(<redacted>)" } // l10n:content

    public func encoded() throws -> String {
        let value = try JSONEncoder().encode(self).base64EncodedString()
        guard value.utf8.count <= 1_048_576 else { throw AppError.invalidResponse }
        return value
    }

    public static func decode(_ value: String) throws -> Self {
        guard value.utf8.count <= 1_048_576, let data = Data(base64Encoded: value) else { throw AppError.unauthorized }
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw AppError.unauthorized }
        guard result.catalogKey.count == 32, LiveTVPlaylistSource.isSupportedURL(result.address),
              result.guideURL.map(LiveTVPlaylistSource.isSupportedURL) != false,
              (result.additionalGuideURLs ?? []).allSatisfy(LiveTVPlaylistSource.isSupportedURL),
              (result.additionalGuideURLs ?? []).count < 32,
              areValidAlternateAddresses(result.configuredAlternateAddresses ?? [], primary: result.address, mode: result.mode),
              result.mode != .xtream || (!result.username.isEmpty && !result.password.isEmpty) else {
            throw AppError.unauthorized
        }
        try validate(headers: result.headers)
        try validate(headers: result.configuredGuideHeaders ?? [:])
        return result
    }

    public static func validate(headers: [String: String]) throws {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let forbidden: Set<String> = [
            "host", "content-length", "transfer-encoding", "connection", "proxy-authorization",
            "proxy-connection", "upgrade", "te", "trailer"
        ]
        var names = Set<String>()
        guard headers.count <= 32, headers.allSatisfy({ name, value in
            !name.isEmpty && name.utf8.count <= 128 && value.utf8.count <= 16_384
                && name.unicodeScalars.allSatisfy(allowed.contains)
                && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && !forbidden.contains(name.lowercased()) && names.insert(name.lowercased()).inserted
        }) else { throw AppError.invalidResponse }
    }

    public func headers(for url: URL) -> [String: String] {
        portalAddresses.contains(where: { Self.sameOrigin($0, url) }) ? headers : [:]
    }

    /// Backup/mirror portal URLs configured for an Xtream account.
    public var alternateAddresses: [URL] { configuredAlternateAddresses ?? [] }

    /// Primary portal address followed by any configured backup portal addresses.
    public var portalAddresses: [URL] {
        mode == .xtream ? [address] + alternateAddresses : [address]
    }

    /// The same credential, identity and catalogue key included, with another set of Xtream backup portal addresses.
    public func replacingAlternateAddresses(_ urls: [URL]) throws -> IPTVCredential {
        guard mode == .xtream else { throw AppError.invalidResponse }
        let normalized = try Self.normalizeAlternateAddresses(urls, primary: address)
        var copy = self
        copy.configuredAlternateAddresses = normalized.isEmpty ? nil : normalized
        return copy
    }

    /// Normalizes an Xtream portal address (scheme/host required, strips trailing slashes, `.php` file, and query).
    public static func normalizedXtreamAddress(_ url: URL) throws -> URL {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.fragment == nil,
              parts.user == nil, parts.password == nil else {
            throw AppError.invalidResponse
        }
        var clean = parts
        if clean.path.lowercased().hasSuffix(".php") {
            clean.path = (clean.path as NSString).deletingLastPathComponent
        }
        while clean.path.hasSuffix("/") { clean.path.removeLast() }
        clean.query = nil
        guard let normalized = clean.url, LiveTVPlaylistSource.isSupportedURL(normalized) else {
            throw AppError.invalidResponse
        }
        return normalized
    }

    private static func normalizeAlternateAddresses(_ urls: [URL], primary: URL) throws -> [URL] {
        guard urls.count <= maximumAlternateAddresses else { throw AppError.invalidResponse }
        var seen = Set<String>([canonicalPortalKey(primary)])
        var result: [URL] = []
        for raw in urls {
            let normalized = try normalizedXtreamAddress(raw)
            let key = canonicalPortalKey(normalized)
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func areValidAlternateAddresses(_ urls: [URL], primary: URL, mode: Mode) -> Bool {
        guard mode == .xtream || urls.isEmpty else { return false }
        guard urls.count <= maximumAlternateAddresses else { return false }
        var seen = Set<String>([canonicalPortalKey(primary)])
        for url in urls {
            guard LiveTVPlaylistSource.isSupportedURL(url),
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil else { return false }
            let key = canonicalPortalKey(url)
            guard seen.insert(key).inserted else { return false }
        }
        return true
    }

    private static func canonicalPortalKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host):\(port)\(path)"
    }

    public var explicitGuideURLs: [URL] { (guideURL.map { [$0] } ?? []) + (additionalGuideURLs ?? []) }
    public var explicitGuideHeaders: [String: String] { configuredGuideHeaders ?? [:] }
    /// Retained for decoding old credentials and identifying catalogues imported with discovery disabled.
    public var automaticallyDiscoversGuides: Bool { discoversPlaylistGuides ?? true }

    public func guideHeaders(for url: URL) -> [String: String] {
        var result = headers(for: url)
        if let guideURL, Self.sameOrigin(guideURL, url) {
            for (name, value) in configuredGuideHeaders ?? [:] {
                result = result.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
                result[name] = value
            }
        }
        return result
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80))
                == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }
}
