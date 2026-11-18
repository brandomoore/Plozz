import CoreModels
import Foundation

/// Shares only overlapping GET transfers with identical authentication and transport policy.
actor HTTPRequestCoalescer {
    static let shared = HTTPRequestCoalescer()

    struct Key: Hashable, Sendable {
        let method: String
        let url: String
        let headers: String
        let lane: String
        let redirectPolicy: Endpoint.RedirectPolicy

        init(
            method: String, url: String, headers: String, lane: String = "",
            redirectPolicy: Endpoint.RedirectPolicy = .follow
        ) {
            self.method = method
            self.url = url
            self.headers = headers
            self.lane = lane
            self.redirectPolicy = redirectPolicy
        }
    }

    struct Payload: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }

    private let requests = SharedAsyncRequests<Key, Payload>()

    func perform(
        key: Key,
        operation: @escaping @Sendable () async throws -> Payload
    ) async throws -> (payload: Payload, joined: Bool) {
        let result = try await requests.perform(key: key, operation: operation)
        return (result.value, result.joined)
    }

    func inFlightCount() async -> Int { await requests.inFlightCount }
    func waitingReaderCount() async -> Int { await requests.waitingReaderCount }
}
