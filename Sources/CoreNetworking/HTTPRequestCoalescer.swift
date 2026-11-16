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
///   cancel the bytes another caller is still waiting for. The last departure
///   cancels it, and each departing caller resumes without waiting for the bytes.
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

    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private struct Waiter {
        let continuation: CheckedContinuation<(payload: Payload, joined: Bool), Error>
        let joined: Bool
    }

    private var entries: [Key: Entry] = [:]

    public init() {}

    /// Returns the shared transfer's payload and whether this caller joined an
    /// already-running one. Consumers own their waits; the entry owns the work.
    public func perform(
        key: Key,
        operation: @escaping @Sendable () async throws -> Payload
    ) async throws -> (payload: Payload, joined: Bool) {
        let waiterID = UUID()
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if entries[key] != nil {
                    entries[key]?.waiters[waiterID] = Waiter(continuation: continuation, joined: true)
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<Payload, Error>
                        do {
                            result = .success(try await operation())
                        } catch {
                            result = .failure(error)
                        }
                        complete(key, id: id, result: result)
                    }
                    entries[key] = Entry(
                        id: id, task: task,
                        waiters: [waiterID: Waiter(continuation: continuation, joined: false)]
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(key, waiterID: waiterID) }
        }
        // Completion may have won actor admission just before cancellation.
        try Task.checkCancellation()
        return result
    }

    /// Number of transfers currently shared. Test seam.
    func inFlightCount() -> Int {
        entries.count
    }

    func waiterCount(for key: Key) -> Int {
        entries[key]?.waiters.count ?? 0
    }

    private func cancel(_ key: Key, waiterID: UUID) {
        guard let waiter = entries[key]?.waiters.removeValue(forKey: waiterID) else { return }
        if let entry = entries[key], entry.waiters.isEmpty {
            entries.removeValue(forKey: key)
            entry.task.cancel()
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func complete(_ key: Key, id: UUID, result: Result<Payload, Error>) {
        // A cancelled transfer can finish after its replacement started.
        guard entries[key]?.id == id, let entry = entries.removeValue(forKey: key) else { return }
        for waiter in entry.waiters.values {
            waiter.continuation.resume(with: result.map { ($0, waiter.joined) })
        }
    }
}
