import Foundation
import CoreModels
import CoreNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Recording `HTTPClient` test double for Seerr. Matches stubbed responses by
/// path suffix and captures sent requests (path, headers, body) so tests can
/// assert on request payloads (e.g. the POST /request body).
final class SeerRecordingHTTPClient: HTTPClient, @unchecked Sendable {
    struct Sent {
        let baseURL: URL
        let method: HTTPMethod
        let path: String
        let queryItems: [URLQueryItem]
        let headers: [String: String]
        let body: Data?
        let redirectPolicy: Endpoint.RedirectPolicy
        let allowsAutomaticAddressRetry: Bool
        var json: [String: Any]? {
            guard let body else { return nil }
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Stub { var status: Int; var body: Data; var headers: [String: String] = [:] }

    private var responses: [String: [Stub]] = [:]
    var error: AppError?
    private(set) var sent: [Sent] = []
    private var requestCounts: [String: Int] = [:]
    private var suspensionRequestNumbers: [String: Int] = [:]
    private var suspensionArrivals: Set<String> = []
    private var suspensionArrivalWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var suspensionContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let lock = NSLock()

    func stub(pathSuffix: String, json: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        responses[pathSuffix] = [Stub(status: status, body: Data(json.utf8), headers: headers)]
    }

    func enqueueStub(pathSuffix: String, json: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        responses[pathSuffix, default: []].append(Stub(status: status, body: Data(json.utf8)))
    }

    func suspend(pathSuffix: String, onRequestNumber: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        suspensionRequestNumbers[pathSuffix] = onRequestNumber
    }

    func waitUntilSuspended(pathSuffix: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if suspensionArrivals.contains(pathSuffix) {
                lock.unlock()
                continuation.resume()
            } else {
                suspensionArrivalWaiters[pathSuffix, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    func resume(pathSuffix: String) {
        lock.lock()
        suspensionRequestNumbers.removeValue(forKey: pathSuffix)
        suspensionArrivals.remove(pathSuffix)
        let continuations = suspensionContinuations.removeValue(forKey: pathSuffix) ?? []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    var sentPaths: [String] { lock.lock(); defer { lock.unlock() }; return sent.map(\.path) }

    func lastSent(pathSuffix: String) -> Sent? {
        lock.lock(); defer { lock.unlock() }
        return sent.last { $0.path.hasSuffix(pathSuffix) }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await sendRaw(endpoint, baseURL: baseURL)
        switch response.statusCode {
        case 200...299: return (data, response)
        case 401, 403: throw AppError.unauthorized
        case 404: throw AppError.notFound
        case 409: throw AppError.conflict
        default: throw AppError.invalidResponse
        }
    }

    /// Records the request, then returns the stubbed `(data, response)` for **any**
    /// status (only an injected transport `error` or a missing stub throws) — so
    /// createRequest can inspect the status code + error body.
    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sent.append(
            Sent(
                baseURL: baseURL,
                method: endpoint.method,
                path: endpoint.path,
                queryItems: endpoint.queryItems,
                headers: endpoint.headers,
                body: endpoint.body,
                redirectPolicy: endpoint.redirectPolicy,
                allowsAutomaticAddressRetry: endpoint.allowsAutomaticAddressRetry
            )
        )
        if let error { lock.unlock(); throw error }
        let matchingSuffix = responses.keys
            .filter { endpoint.path.hasSuffix($0) }
            .max(by: { $0.count < $1.count })
        let match: Stub?
        var shouldSuspend = false
        if let matchingSuffix, var stubs = responses[matchingSuffix], let first = stubs.first {
            match = first
            if stubs.count > 1 {
                stubs.removeFirst()
                responses[matchingSuffix] = stubs
            }
            requestCounts[matchingSuffix, default: 0] += 1
            shouldSuspend = suspensionRequestNumbers[matchingSuffix] == requestCounts[matchingSuffix]
        } else {
            match = nil
        }
        lock.unlock()

        if shouldSuspend, let matchingSuffix {
            await withCheckedContinuation { continuation in
                lock.lock()
                if suspensionRequestNumbers[matchingSuffix] == requestCounts[matchingSuffix] {
                    suspensionContinuations[matchingSuffix, default: []].append(continuation)
                    suspensionArrivals.insert(matchingSuffix)
                    let waiters = suspensionArrivalWaiters.removeValue(forKey: matchingSuffix) ?? []
                    lock.unlock()
                    waiters.forEach { $0.resume() }
                } else {
                    lock.unlock()
                    continuation.resume()
                }
            }
        }

        guard let stub = match else { throw AppError.notFound }
        let response = HTTPURLResponse(url: baseURL, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        return (stub.body, response)
    }
}
