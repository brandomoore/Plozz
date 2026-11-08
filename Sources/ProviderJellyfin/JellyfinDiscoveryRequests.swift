import Foundation

/// Shares only overlapping discovery reads within one authenticated client/provider.
/// Completed values and failures are never cached.
actor JellyfinDiscoveryRequests<Value: Sendable> {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct Reader {
        let continuation: CheckedContinuation<Value, Error>
        let cancellation: Cancellation
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var readers: [UUID: Reader]
    }

    private var flights: [String: Flight] = [:]
    var waitingReaderCount: Int { flights.values.reduce(0) { $0 + $1.readers.count } }

    func run(key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let readerID = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                let reader = Reader(continuation: continuation, cancellation: cancellation)
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flights[key] != nil {
                    flights[key]?.readers[readerID] = reader
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        finish(key: key, id: id, result: result)
                    }
                    flights[key] = Flight(id: id, task: task, readers: [readerID: reader])
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(key: key, readerID: readerID) }
        }
    }

    private func cancel(key: String, readerID: UUID) {
        guard var flight = flights[key],
              let reader = flight.readers.removeValue(forKey: readerID) else { return }
        reader.continuation.resume(throwing: CancellationError())
        if flight.readers.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func finish(key: String, id: UUID, result: Result<Value, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key)
        for reader in flight.readers.values {
            if reader.cancellation.isCancelled {
                reader.continuation.resume(throwing: CancellationError())
            } else {
                reader.continuation.resume(with: result)
            }
        }
    }
}
