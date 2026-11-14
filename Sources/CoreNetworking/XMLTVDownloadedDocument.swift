import CoreModels
import Foundation

public struct XMLTVDownloadedDocument: Sendable {
    public let data: Data
    public let expiresAt: Date
    public let permitsPersistence: Bool
    public let cacheMetadata: XMLTVGuideCacheMetadata?

    public init(
        data: Data, expiresAt: Date, permitsPersistence: Bool,
        cacheMetadata: XMLTVGuideCacheMetadata? = nil
    ) {
        self.data = data
        self.expiresAt = expiresAt
        self.permitsPersistence = permitsPersistence
        self.cacheMetadata = cacheMetadata
    }
}

public enum XMLTVGuideResponse: Sendable {
    case document(XMLTVDownloadedDocument)
    case notModified(XMLTVGuideCacheMetadata)
}

/// Stored with the authorized parsed index, never in an unscoped URL cache.
public struct XMLTVGuideCacheMetadata: Codable, Equatable, Sendable {
    public static let maximumAge: TimeInterval = 12 * 3_600
    public static let emptyResultMaximumAge: TimeInterval = 60
    public let responseURL: URL
    public let etag: String?
    public let lastModified: String?
    public let cacheControl: String
    private let expiresHeader: String?
    public let checkedAt: Date
    public let expiresAt: Date

    public var permitsPersistence: Bool { !directiveNames.contains("no-store") }
    public var hasValidator: Bool { etag != nil || lastModified != nil }
    private var directiveNames: Set<String> {
        Set(cacheControl.lowercased().split(separator: ",").map {
            $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
        })
    }

    public init(
        response: HTTPURLResponse, previous: XMLTVGuideCacheMetadata? = nil, now: Date = Date()
    ) throws {
        guard let url = response.url, now.timeIntervalSince1970.isFinite else {
            throw URLError(.badServerResponse)
        }
        let previous = response.statusCode == 304 && previous?.responseURL == url ? previous : nil
        var invalidCachePolicy = false
        func header(_ name: String, fallback: String? = nil) -> String? {
            guard let value = response.value(forHTTPHeaderField: name) else { return fallback }
            guard value.utf8.count <= 8_192, !value.contains("\r"), !value.contains("\n") else {
                PlozzLog.networking.info("XMLTV_CACHE event=ignoredHeader field=\(name)")
                if name != "ETag", name != "Last-Modified" { invalidCachePolicy = true }
                return nil
            }
            return value.isEmpty ? nil : value
        }
        responseURL = url
        etag = header("ETag", fallback: previous?.etag)
        lastModified = header("Last-Modified", fallback: previous?.lastModified)
        let returnedCacheControl = header("Cache-Control", fallback: previous?.cacheControl) ?? ""
        expiresHeader = header("Expires", fallback: previous?.expiresHeader)
        checkedAt = now
        let serverDate = header("Date").flatMap(HTTPDate.parse) ?? now
        let age = header("Age").map { TimeInterval($0) ?? .infinity } ?? 0
        // An unusable cache policy must not hide no-store/no-cache instructions.
        // Continue with the XML, but neither persist nor reuse that response.
        cacheControl = invalidCachePolicy ? "no-store, no-cache" : returnedCacheControl
        let directives = cacheControl.lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let maxAges = directives.compactMap { directive -> TimeInterval? in
            let parts = directive.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].trimmingCharacters(in: .whitespaces) == "max-age" else { return nil }
            guard parts.count == 2,
                  let value = TimeInterval(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))),
                  value.isFinite else { return 0 }
            return max(0, value)
        }
        let expires = expiresHeader.map { HTTPDate.parse($0)?.timeIntervalSince(serverDate) ?? 0 }
        let lifetime = min(Self.maximumAge, maxAges.min() ?? expires ?? Self.maximumAge)
        let currentAge = max(max(0, age), now.timeIntervalSince(serverDate))
        let noCache = directives.contains {
            $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces) == "no-cache"
        }
        expiresAt = now.addingTimeInterval(noCache || !currentAge.isFinite ? 0 : max(0, lifetime - currentAge))
    }

    public func isFresh(at now: Date) -> Bool {
        permitsPersistence && now >= checkedAt && now < expiresAt
            && now.timeIntervalSince(checkedAt) < Self.maximumAge
    }

    /// Redirected resources own their validators; even another path on the same
    /// host must not receive them or validate the original index.
    public func applying(to request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "If-None-Match")
        request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        guard request.url == responseURL, permitsPersistence else { return request }
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        return request
    }
}
