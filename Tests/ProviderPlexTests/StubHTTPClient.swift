import Foundation
import CoreModels
import CoreNetworking
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configurable `HTTPClient` test double matching by path suffix, mirroring the
/// ProviderJellyfin test stub.
final class StubHTTPClient: HTTPClient {
    struct Stub {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    private struct Request {
        let endpoint: Endpoint
        let baseURL: URL
    }

    private struct State {
        var responses: [(suffix: String, stub: Stub)] = []
        var queues: [String: [Stub]] = [:]
        var error: AppError?
        var requests: [Request] = []
    }

    private let state = Mutex(State())

    var error: AppError? {
        get { state.withLock { $0.error } }
        set { state.withLock { $0.error = newValue } }
    }
    var sentPaths: [String] { state.withLock { $0.requests.map(\.endpoint.path) } }
    var sentMethods: [HTTPMethod] { state.withLock { $0.requests.map(\.endpoint.method) } }
    var sentQueryItems: [[URLQueryItem]] { state.withLock { $0.requests.map(\.endpoint.queryItems) } }
    var sentBaseURLs: [URL] { state.withLock { $0.requests.map(\.baseURL) } }

    func stub(
        pathSuffix: String,
        json: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) {
        state.withLock {
            $0.responses.append((
                pathSuffix,
                Stub(status: status, body: Data(json.utf8), headers: headers)
            ))
        }
    }

    /// Adds a sequence of responses returned in order for `suffix` (for polling).
    func stubSequence(pathSuffix: String, jsons: [String]) {
        state.withLock {
            $0.queues[pathSuffix, default: []].append(
                contentsOf: jsons.map { Stub(body: Data($0.utf8)) }
            )
        }
    }

    func stubSequence(
        pathSuffix: String,
        responses: [(json: String, status: Int)]
    ) {
        state.withLock {
            $0.queues[pathSuffix, default: []].append(
                contentsOf: responses.map {
                    Stub(status: $0.status, body: Data($0.json.utf8))
                }
            )
        }
    }

    /// All query items sent for the most recent request whose path ends in `suffix`.
    func queryItems(forPathSuffix suffix: String) -> [URLQueryItem]? {
        state.withLock {
            $0.requests.last { $0.endpoint.path.hasSuffix(suffix) }?.endpoint.queryItems
        }
    }

    /// The method of the most recent request whose path ends in `suffix`.
    func method(forPathSuffix suffix: String) -> HTTPMethod? {
        state.withLock {
            $0.requests.last { $0.endpoint.path.hasSuffix(suffix) }?.endpoint.method
        }
    }

    /// The base URL (host) of the most recent request whose path ends in `suffix`.
    func baseURL(forPathSuffix suffix: String) -> URL? {
        state.withLock {
            $0.requests.last { $0.endpoint.path.hasSuffix(suffix) }?.baseURL
        }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let result = try await sendRaw(endpoint, baseURL: baseURL)
        switch result.1.statusCode {
        case 200...299:
            return result
        case 401, 403:
            throw AppError.unauthorized
        case 404:
            throw AppError.notFound
        default:
            throw AppError.invalidResponse
        }
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let match = try state.withLock { state in
            state.requests.append(Request(endpoint: endpoint, baseURL: baseURL))
            if let error = state.error { throw error }
            if let key = state.queues.keys.first(where: { endpoint.path.hasSuffix($0) }),
               var queue = state.queues[key], !queue.isEmpty {
                let next = queue.removeFirst()
                state.queues[key] = queue
                return next
            }
            guard let match = state.responses.first(where: { endpoint.path.hasSuffix($0.suffix) })?.stub else {
                throw AppError.notFound
            }
            return match
        }
        return (
            match.body,
            HTTPURLResponse(
                url: baseURL,
                statusCode: match.status,
                httpVersion: nil,
                headerFields: match.headers
            )!
        )
    }
}
