import Foundation

/// Shares overlapping work, never completed values, with independently cancellable readers.
public actor SharedAsyncRequests<Key: Hashable & Sendable, Value: Sendable> {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct Reader {
        let continuation: CheckedContinuation<(value: Value, joined: Bool), Error>
        let cancellation: Cancellation
        let joined: Bool
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var readers: [UUID: Reader]
    }

    private var flights: [Key: Flight] = [:]
    public var waitingReaderCount: Int { flights.values.reduce(0) { $0 + $1.readers.count } }
    public var inFlightCount: Int { flights.count }
    public func contains(key: Key) -> Bool { flights[key] != nil }

    public init() {}

    public func run(key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await perform(key: key, operation: operation).value
    }

    public func perform(
        key: Key, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> (value: Value, joined: Bool) {
        let readerID = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: (value: Value, joined: Bool) = try await withCheckedThrowingContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let reader = Reader(
                    continuation: continuation, cancellation: cancellation, joined: flights[key] != nil
                )
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
            return result
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(key: key, readerID: readerID) }
        }
    }

    private func cancel(key: Key, readerID: UUID) {
        guard var flight = flights[key],
              let reader = flight.readers.removeValue(forKey: readerID) else { return }
        if flight.readers.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
        reader.continuation.resume(throwing: CancellationError())
    }

    private func finish(key: Key, id: UUID, result: Result<Value, Error>) {
        guard let flight = flights[key], flight.id == id else { return }
        flights.removeValue(forKey: key)
        for reader in flight.readers.values {
            if reader.cancellation.isCancelled {
                reader.continuation.resume(throwing: CancellationError())
            } else {
                reader.continuation.resume(with: result.map { ($0, reader.joined) })
            }
        }
    }
}
