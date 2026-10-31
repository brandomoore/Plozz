import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// A description of a single HTTP request, independent of how it's executed.
///
/// Providers build `Endpoint`s and hand them to `HTTPClient`, which keeps the
/// transport (URLSession), header redaction, and error mapping in one place.
public struct Endpoint: Sendable {
    public enum RedirectPolicy: Equatable, Sendable {
        case follow
        case sameOrigin
        case doNotFollow
    }

    public var method: HTTPMethod
    /// Path relative to the server base URL, e.g. `/QuickConnect/Initiate`.
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    public var redirectPolicy: RedirectPolicy
    /// A GET that can initiate server work must not be replayed on another address.
    public var allowsAutomaticAddressRetry: Bool
    /// Preserve proof that a one-time mutation never reached HTTP transmission.
    public var reportsUndeliveredRequests: Bool = false
    /// Personal tracker routes can contain viewing identities even after token redaction.
    public var redactsURLForLogging: Bool = false
    /// Stop receiving before an untrusted response exceeds this byte budget.
    public var maximumResponseBytes: Int?
    /// Manual scheme discovery must distinguish rejected trust from an offline port.
    public var reportsServerTrustFailures: Bool = false

    public init(
        method: HTTPMethod = .get,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        redirectPolicy: RedirectPolicy = .follow,
        allowsAutomaticAddressRetry: Bool = true
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.redirectPolicy = redirectPolicy
        self.allowsAutomaticAddressRetry = allowsAutomaticAddressRetry
    }

    /// Convenience for a JSON `POST`/`GET` carrying an `Encodable` body.
    public func jsonBody<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> Endpoint {
        var copy = self
        copy.body = try encoder.encode(value)
        copy.headers["Content-Type"] = "application/json"
        return copy
    }
}
