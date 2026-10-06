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
    public let identity: UUID
    public let catalogKey: Data

    public init(
        mode: Mode, address: URL, username: String = "", password: String = "",
        headers: [String: String] = [:], guideURL: URL? = nil,
        additionalGuideURLs: [URL] = [], guideHeaders: [String: String] = [:],
        discoversPlaylistGuides: Bool = true,
        identity: UUID = UUID()
    ) throws {
        guard let parts = URLComponents(url: address, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.fragment == nil,
              guideURL.map({ LiveTVPlaylistSource.isSupportedURL($0) }) != false,
              additionalGuideURLs.allSatisfy(LiveTVPlaylistSource.isSupportedURL),
              additionalGuideURLs.count < 32,
              guideURL != nil || guideHeaders.isEmpty,
              mode != .xtream || (!username.isEmpty && !password.isEmpty) else {
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
        Self.sameOrigin(address, url) ? headers : [:]
    }

    public var explicitGuideURLs: [URL] { (guideURL.map { [$0] } ?? []) + (additionalGuideURLs ?? []) }
    public var explicitGuideHeaders: [String: String] { configuredGuideHeaders ?? [:] }
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
