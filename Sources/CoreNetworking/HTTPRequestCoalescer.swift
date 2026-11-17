import CoreModels
import Foundation

/// Shares only overlapping GET transfers with identical authentication and transport policy.
///
/// Home fan-out routinely asks the same question more than once — a library
/// inventory requested by the row that needs it and again by the row that
/// publishes behind it, or the same series metadata fetched for recency and for
/// identity. `SharedAsyncRequests` joins those callers to one transfer while
/// keeping each reader independently cancellable: a caller that walks away
/// exits promptly, and the bytes stop when nobody needs them.
public actor HTTPRequestCoalescer {
    public static let shared = HTTPRequestCoalescer()

    public struct Key: Hashable, Sendable {
        public let method: String
        public let url: String
        public let headers: String
        /// Transport lane identity. Sessions have different timeouts and
        /// connection pools, so a discovery probe must never join a
        /// default-lane transfer.
        public let lane: String
        /// A request that must not follow redirects cannot inherit another
        /// caller's permission to follow them.
        public let redirectPolicy: Endpoint.RedirectPolicy

        public init(
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

    public struct Payload: @unchecked Sendable {
        public let data: Data
        public let response: URLResponse

        public init(data: Data, response: URLResponse) {
            self.data = data
            self.response = response
        }
    }

    private let requests = SharedAsyncRequests<Key, Payload>()

    public init() {}

    /// Returns the shared transfer's payload and whether this caller joined an
    /// already-running one.
    public func perform(
        key: Key,
        operation: @escaping @Sendable () async throws -> Payload
    ) async throws -> (payload: Payload, joined: Bool) {
        let result = try await requests.perform(key: key, operation: operation)
        return (result.value, result.joined)
    }

    /// Number of transfers currently shared. Test seam.
    func inFlightCount() async -> Int { await requests.inFlightCount }
    func waitingReaderCount() async -> Int { await requests.waitingReaderCount }
}
