import CoreModels
import Foundation

/// Shares one in-flight GET transfer between callers that asked for the exact
/// same URL with the same headers.
///
/// Home fan-out routinely asks the same question more than once — a library
/// inventory requested by the row that needs it and again by the row that
/// publishes behind it, or the same series metadata fetched for recency and for
/// identity. Those calls are independent and can overlap, so without a
/// coalescer each one opens its own connection and the server does the work
/// twice. Joining an in-flight transfer keeps the request shape unchanged while
/// removing the duplicate round trip.
///
/// Deliberately narrow:
/// * GET only. A mutating request must never be shared.
/// * Headers are part of the key, so two users/tokens never share a response.
/// * Only the transfer is shared. Each caller still decodes, validates and
///   reports its own diagnostics, so cancellation and error mapping stay
///   caller-local.
/// * The shared transfer is unstructured: one caller walking away does not
///   cancel the bytes another caller is still waiting for.
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
    /// already-running one. The last cancelled reader retires the transfer.
    public func perform(
        key: Key,
        operation: @escaping @Sendable () async throws -> Payload
    ) async throws -> (payload: Payload, joined: Bool) {
        let result = try await requests.perform(key: key, operation: operation)
        return (result.value, result.joined)
    }

    /// Number of transfers currently shared. Test seam.
    func inFlightCount() async -> Int {
        await requests.inFlightCount
    }

    func waitingReaderCount() async -> Int {
        await requests.waitingReaderCount
    }
}
