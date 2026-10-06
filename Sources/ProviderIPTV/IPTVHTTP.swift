import CoreModels
import CoreNetworking
import Foundation

final class IPTVHTTP: Sendable {
    private let session: URLSession
    private let redirects: IPTVRedirects

    init(
        configuration: URLSessionConfiguration? = nil, resourceTimeout: TimeInterval = 1_800,
        sensitiveValues: [String] = []
    ) {
        let configuration = configuration ?? .ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = resourceTimeout
        redirects = IPTVRedirects(sensitiveValues: sensitiveValues)
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }
    func cancel() { session.invalidateAndCancel() }

    func bytes(url: URL, headers: [String: String], method: String = "GET") async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard LiveTVPlaylistSource.isSupportedURL(url) else { throw IPTVError.invalidAddress }
        try IPTVCredential.validate(headers: headers)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw IPTVError.malformed
        }
        guard (200...299).contains(response.statusCode) else {
            bytes.task.cancel()
            if response.statusCode == 401 || response.statusCode == 403 { throw IPTVError.authentication }
            if (300...399).contains(response.statusCode) { throw LiveTVSourceImportError.redirectBlocked }
            if response.statusCode == 404 { throw AppError.notFound }
            if response.statusCode == 429 {
                throw AppError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
            }
            throw AppError.invalidResponse
        }
        return (bytes, response)
    }
}

private final class IPTVRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    let sensitiveValues: [String]

    init(sensitiveValues: [String]) { self.sensitiveValues = sensitiveValues }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(IPTVRedirectPolicy.request(
            request, previous: response.url, original: task.originalRequest, sensitiveValues: sensitiveValues
        ))
    }
}

enum IPTVRedirectPolicy {
    static func request(
        _ request: URLRequest, previous: URL?, original: URLRequest?, sensitiveValues: [String] = []
    ) -> URLRequest? {
        guard let next = request.url, let previous,
              LiveTVPlaylistSource.isSupportedURL(next),
              !(previous.scheme?.lowercased() == "https" && next.scheme?.lowercased() != "https") else {
            return nil
        }
        if IPTVCredential.sameOrigin(previous, next),
           IPTVCredential.sameOrigin(original?.url ?? previous, next) {
            return request
        }
        // A CDN may issue its own signed redirect. Never carry account headers
        // or a copied account query into that different origin.
        let secrets = sensitiveValues + protectedValues(
            url: original?.url ?? previous, headers: original?.allHTTPHeaderFields ?? [:]
        )
        let destination = next.absoluteString.removingPercentEncoding ?? next.absoluteString
        guard !secrets.contains(where: { !$0.isEmpty && destination.contains($0) }) else {
            return nil
        }
        var clean = URLRequest(url: next)
        clean.timeoutInterval = request.timeoutInterval
        clean.httpMethod = request.httpMethod
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for header in ["Range", "If-Range"] {
            clean.setValue(request.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        return clean
    }

    static func protectedValues(url: URL, headers: [String: String]) -> [String] {
        var secrets = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { SensitiveQueryPolicy.isSensitive($0.name) }.compactMap(\.value) ?? []
        )
        for (name, value) in headers {
            if name.lowercased() == "authorization", value.lowercased().hasPrefix("bearer ") {
                secrets.append(String(value.dropFirst(7)))
            } else if name.lowercased() == "authorization", value.lowercased().hasPrefix("basic "),
                      let bytes = Data(base64Encoded: String(value.dropFirst(6))),
                      let pair = String(data: bytes, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                secrets.append(String(pair[pair.index(after: colon)...]))
            } else if name.lowercased() == "cookie" {
                secrets += value.split(separator: ";").compactMap { field in
                    guard let equals = field.firstIndex(of: "=") else { return nil }
                    return field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                }
            } else if !["accept", "accept-encoding", "user-agent", "range", "if-range"].contains(name.lowercased()) {
                secrets.append(value)
            }
        }
        return secrets.filter { !$0.isEmpty }
    }
}

enum IPTVValue: Decodable, Sendable {
    case text(String), number(Double), boolean(Bool), object([String: IPTVValue]), array([IPTVValue]), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let array = try? value.decode([IPTVValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: IPTVValue].self)) }
    }

    var text: String? {
        switch self {
        case .text(let value): value
        case .number(let value) where value.isFinite:
            value.rounded() == value && abs(value) < Double(Int64.max) ? String(Int64(value)) : String(value)
        case .boolean(let value): value ? "1" : "0"
        default: nil
        }
    }
    var object: [String: IPTVValue] { if case .object(let value) = self { value } else { [:] } }
    var array: [IPTVValue] { if case .array(let value) = self { value } else { [] } }
}

typealias IPTVObject = [String: IPTVValue]

extension IPTVObject {
    func text(_ key: String) -> String? { self[key]?.text.flatMap { $0.isEmpty ? nil : $0 } }
    func number(_ key: String) -> Double? { text(key).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    func integer(_ key: String) -> Int? { text(key).flatMap(Int.init) }
    func object(_ key: String) -> IPTVObject { self[key]?.object ?? [:] }
    func array(_ key: String) -> [IPTVValue] { self[key]?.array ?? [] }
}
