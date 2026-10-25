import Foundation
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over the transport so providers can be unit-tested with a stub.
public protocol HTTPClient: Sendable {
    /// Sends `endpoint` against `baseURL`, returning raw data + response.
    /// Throws `AppError` for transport/status failures (non-2xx → mapped).
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse)

    /// Like `send`, but does **not** throw on a non-2xx HTTP status — it returns
    /// `(data, response)` so the caller can inspect the status code *and the
    /// error body*. Still throws for transport failures (unreachable/cancelled).
    ///
    /// Used where the server's error payload carries meaning the status code
    /// alone doesn't (e.g. Overseerr's request errors: "no default server",
    /// "quota exceeded", "no permission"). Has a default that falls back to
    /// `send`; conformers that need error-body access override it.
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse)
}

public struct HTTPRequestNotSentError: Error, Sendable {
    public let underlying: AppError

    public init(underlying: AppError) {
        self.underlying = underlying
    }
}

final class HTTPRequestDeliveryEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var hasTransactions = false
    private var requestStarted = false
    private var sentBody = false

    func recordTransactions(requestStarted values: [Bool]) {
        lock.lock()
        defer { lock.unlock() }
        hasTransactions = hasTransactions || !values.isEmpty
        requestStarted = requestStarted || values.contains(true)
    }

    func recordBodyBytes(_ count: Int64) {
        lock.lock()
        defer { lock.unlock() }
        sentBody = sentBody || count > 0
    }

    var confirmedNotSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasTransactions && !requestStarted && !sentBody
    }
}

class HTTPDeliveryTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let evidence: HTTPRequestDeliveryEvidence?

    init(evidence: HTTPRequestDeliveryEvidence?) {
        self.evidence = evidence
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        evidence?.recordBodyBytes(task.countOfBytesSent)
        evidence?.recordTransactions(requestStarted: metrics.transactionMetrics.map { transaction in
            let observedConnection = transaction.resourceFetchType == .networkLoad
            let observedHTTP = transaction.requestStartDate != nil || transaction.requestEndDate != nil
                || transaction.response != nil || transaction.responseStartDate != nil
                || transaction.responseEndDate != nil
            // Missing timing from an unknown/custom transport is not proof.
            return !observedConnection || observedHTTP
        })
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        evidence?.recordBodyBytes(totalBytesSent)
    }
}

public extension HTTPClient {
    /// Default: no distinct raw path — reuse `send` (which throws on non-2xx, so
    /// the error body is unavailable to conformers that don't override this).
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(endpoint, baseURL: baseURL)
    }

    /// Sends and decodes a JSON `Decodable`, mapping failures to `AppError`.
    func decode<T: Decodable>(
        _ type: T.Type,
        from endpoint: Endpoint,
        baseURL: URL,
        decoder: JSONDecoder = .plozz
    ) async throws -> T {
        try await decodeResponse(type, from: endpoint, baseURL: baseURL, decoder: decoder).value
    }

    func decodeResponse<T: Decodable>(
        _ type: T.Type,
        from endpoint: Endpoint,
        baseURL: URL,
        decoder: JSONDecoder = .plozz
    ) async throws -> (value: T, response: HTTPURLResponse) {
        let (data, response) = try await send(endpoint, baseURL: baseURL)
        let diagnostic = PerformanceDiagnostics.shared.begin(
            .serverDecode, provider: PerformanceDiagnostics.provider, metrics: .init(bytes: data.count)
        )
        do {
            let value = try decoder.decode(T.self, from: data)
            diagnostic?.finish(.succeeded)
            return (value, response)
        } catch {
            diagnostic?.finish(.failed)
            HTTPResponseDiagnostics.recordDecodeFailure(error, data: data, response: response)
            let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
            PlozzLog.networking.error(
                "Decode failed method=\(endpoint.method.rawValue) path=\(endpoint.path) "
                    + "type=\(String(describing: T.self)) status=\(response.statusCode) "
                    + "bytes=\(data.count) contentType=\(contentType) "
                    + "payload=\(HTTPDecodeDiagnostics.payloadShape(data)) "
                    + "error=\(HTTPDecodeDiagnostics.failureDescription(error))"
            )
            throw AppError.decoding
        }
    }
}

enum HTTPDecodeDiagnostics {
    static func failureDescription(_ error: Error) -> String {  // l10n:content — developer-facing decode diagnostic, only ever logged
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "keyNotFound(\(key.stringValue)) at \(codingPath(context.codingPath))"
        case let DecodingError.typeMismatch(type, context):
            return "typeMismatch(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case let DecodingError.valueNotFound(type, context):
            return "valueNotFound(\(String(describing: type))) at \(codingPath(context.codingPath))"
        case let DecodingError.dataCorrupted(context):
            return "dataCorrupted at \(codingPath(context.codingPath))"
        default:
            return String(describing: type(of: error))
        }
    }

    static func payloadShape(_ data: Data) -> String {
        guard !data.isEmpty else { return "empty" }
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return "nonJSON"
        }
        if let object = value as? [String: Any] {
            return "object(keys:\(object.keys.sorted().joined(separator: ",")))"
        }
        if let array = value as? [Any] {
            return "array(count:\(array.count))"
        }
        return String(describing: type(of: value))
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }
        return path.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }.joined(separator: ".")
    }
}

/// `URLSession`-backed `HTTPClient`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .plozzDefault) {
        self.session = session
    }

    public func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await sendRaw(endpoint, baseURL: baseURL)
        HTTPResponseDiagnostics.recordHTTPFailure(status: http.statusCode)
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 401, 403:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        case 409:
            throw AppError.conflict
        case 429:
            throw AppError.rateLimited(
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init)
            )
        default:
            throw AppError.invalidResponse
        }
    }

    /// Transport path shared by `send`: performs the request and returns
    /// `(data, response)` for **every** HTTP status (only transport failures
    /// throw), so callers that need the error body/status can inspect them.
    public func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        var request = try Self.makeRequest(endpoint, baseURL: baseURL)
        let started = HTTPResponseDiagnostics.isCapturing ? ProcessInfo.processInfo.systemUptime : nil
        var capturedStatus: Int?
        var capturedNetworkCode: Int?
        var capturedBytes = 0
        var capturedFormat = PlaybackFailureDiagnostic.Format.unknown
        defer {
            if let started {
                HTTPResponseDiagnostics.recordRequest(ResponseRequestDiagnostic(
                    route: HTTPResponseDiagnostics.route, method: endpoint.method.rawValue,
                    elapsedMilliseconds: Int((ProcessInfo.processInfo.systemUptime - started) * 1_000),
                    httpStatus: capturedStatus, urlErrorCode: capturedNetworkCode,
                    bytes: capturedBytes, format: capturedFormat,
                    requestTimeoutMilliseconds: Int(session.configuration.timeoutIntervalForRequest * 1_000),
                    resourceTimeoutMilliseconds: Int(session.configuration.timeoutIntervalForResource * 1_000)
                ))
            }
        }
        if endpoint.reportsUndeliveredRequests { request.cachePolicy = .reloadIgnoringLocalCacheData }
        let delivery = endpoint.reportsUndeliveredRequests ? HTTPRequestDeliveryEvidence() : nil

        let requestLabel = endpoint.redactsURLForLogging ? "<private>" : PlozzLog.redact(url: request.url ?? baseURL)
        PlozzLog.networking.debug("→ \(endpoint.method.rawValue) \(requestLabel)")

        let data: Data
        let response: URLResponse
        let diagnostic = PerformanceDiagnostics.shared.begin(
            .serverRequest, provider: PerformanceDiagnostics.provider
        )
        do {
            let delegate: (any URLSessionTaskDelegate)?
            switch endpoint.redirectPolicy {
            case .follow:
                delegate = delivery.map { HTTPDeliveryTaskDelegate(evidence: $0) }
            case .sameOrigin:
                delegate = SameOriginHTTPRedirectDelegate(url: request.url ?? baseURL, evidence: delivery)
            }
            if let limit = endpoint.maximumResponseBytes {
                guard limit > 0 else { throw AppError.invalidResponse }
                let (bytes, received) = try await session.bytes(for: request, delegate: delegate)
                defer { bytes.task.cancel() }
                guard received.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
                var receivedData = Data()
                for try await byte in bytes {
                    guard receivedData.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
                    receivedData.append(byte)
                }
                try Task.checkCancellation()
                (data, response) = (receivedData, received)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
        } catch let urlError as URLError {
            capturedNetworkCode = urlError.errorCode
            HTTPResponseDiagnostics.recordTransportFailure(urlError)
            diagnostic?.finish(
                urlError.code == .cancelled ? .cancelled : .failed,
                networkCode: urlError.errorCode
            )
            if delivery?.confirmedNotSent == true {
                throw HTTPRequestNotSentError(underlying: Self.map(urlError))
            }
            throw Self.map(urlError)
        } catch is CancellationError {
            diagnostic?.finish(.cancelled)
            throw AppError.cancelled
        } catch {
            diagnostic?.finish(.failed)
            throw AppError.serverUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            diagnostic?.finish(.failed)
            throw AppError.invalidResponse
        }
        capturedStatus = http.statusCode
        capturedBytes = data.count
        capturedFormat = data.isEmpty ? .empty : .init(mimeType: http.mimeType)
        diagnostic?.finish(
            (200...299).contains(http.statusCode) ? .succeeded : .failed,
            metrics: .init(bytes: data.count), httpStatus: http.statusCode
        )

        PlozzLog.networking.debug(
            "← \(http.statusCode) \(endpoint.method.rawValue) "
                + "\(requestLabel) bytes=\(data.count)"
        )
        return (data, http)
    }

    static func makeRequest(_ endpoint: Endpoint, baseURL: URL) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        // Append the endpoint path to any base path the server is hosted under.
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + endpoint.path
        if !endpoint.queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + endpoint.queryItems
        }
        guard let url = components.url else { throw AppError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func map(_ error: URLError) -> AppError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .dataLengthExceedsMaximum:
            return .invalidResponse
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
             .timedOut, .networkConnectionLost, .dnsLookupFailed, .secureConnectionFailed:
            return .serverUnreachable
        default:
            return .serverUnreachable
        }
    }
}

/// Per-task protection for endpoints carrying credentials or tuner ownership.
/// A blocked redirect is returned as its original non-success HTTP response.
final class SameOriginHTTPRedirectDelegate: HTTPDeliveryTaskDelegate, @unchecked Sendable {
    private let origin: NetworkOrigin?

    init(url: URL, evidence: HTTPRequestDeliveryEvidence? = nil) {
        self.origin = Self.origin(of: url)
        super.init(evidence: evidence)
    }

    func allowedRequest(_ request: URLRequest) -> URLRequest? {
        guard let origin, let url = request.url,
              Self.origin(of: url) == origin else { return nil }
        return request
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(allowedRequest(request))
    }

    private static func origin(of url: URL) -> NetworkOrigin? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme, let host = components.host else { return nil }
        return try? NetworkOrigin(scheme: scheme, host: host, port: components.port)
    }
}

public extension URLSession {
    /// Session tuned for tvOS: short-ish timeouts so the UI can fail fast and
    /// show a graceful "server unreachable" state instead of hanging.
    static var plozzDefault: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        // A detail open fans out a burst of enrichment requests (season prewarm,
        // trailers, ratings, cross-server discovery) to the SAME server host. With
        // the system default per-host cap (~6) those background requests can occupy
        // every socket and starve the next page's foreground fetch. A higher cap
        // keeps the pool from becoming the bottleneck on a fast LAN.
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Dedicated lane for FOREGROUND, user-blocking fetches — specifically opening
    /// a detail page (`item`/`metadata`). It has its OWN connection pool, so a
    /// critical-path fetch can NEVER be starved waiting for a free socket behind
    /// the background enrichment storm running on ``plozzDefault`` (season prewarm,
    /// trailers, ratings, cross-server discovery). `timeoutIntervalForRequest`
    /// does not count time spent queued for a connection, so a shared pool let a
    /// foreground fetch sit ~18s behind background work before `timeoutInterval-
    /// ForResource` (30s) would even fire — this isolated pool removes that queue
    /// entirely. Short timeouts so a genuinely slow server fails fast into a
    /// graceful error instead of a long blank hang.
    static var plozzInteractive: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Session for probing discovery candidates: very short timeouts so we can
    /// race several candidate URLs per server and fail fast on the wrong ones
    /// without stalling the scan. Does not wait for connectivity.
    static var plozzDiscovery: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }
}

public extension JSONDecoder {
    /// Decoder configured for Jellyfin's PascalCase JSON.
    static var plozz: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
