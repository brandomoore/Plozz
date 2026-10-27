import CoreModels
import CoreNetworking
import Foundation

/// Serializes probe-capable requests. Cancelling a reader must not free a slot
/// while Jellyfin may still be doing the corresponding server-side work.
public actor PlaybackInfoRequestCoordinator {
    public static let shared = PlaybackInfoRequestCoordinator()

    struct Key: Hashable, Sendable {
        let scope: UUID
        let userID: String
        let itemID: String
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct Reader {
        let continuation: CheckedContinuation<PlaybackInfoResponse, Error>
        let cancellation: Cancellation
    }

    private struct Work {
        let server: String
        let sharesInventory: Bool
        let admission: AsyncStream<Void>.Continuation
        var waiters: [UUID: Reader]
        var started = false
    }

    private struct Backoff {
        let until: ContinuousClock.Instant
        let error: AppError
    }

    private let backoff: Duration
    private var work: [Key: Work] = [:]
    private var queues: [String: [Key]] = [:]
    private var active: [String: Key] = [:]
    private var blocked: [String: Backoff] = [:]

    var waitingReaderCount: Int { work.values.reduce(0) { $0 + $1.waiters.count } }

    public init() {
        backoff = .seconds(30)
    }

    init(backoff: Duration) {
        self.backoff = backoff
    }

    func run(
        server: String,
        inventoryKey: Key? = nil,
        operation: @escaping @Sendable () async throws -> PlaybackInfoResponse
    ) async throws -> PlaybackInfoResponse {
        try Task.checkCancellation()
        let key = inventoryKey ?? Key(scope: UUID(), userID: "", itemID: "")
        let waiter = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let reader = Reader(continuation: continuation, cancellation: cancellation)
                if cancellation.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let pause = blocked[server], ContinuousClock.now < pause.until {
                    PlozzLog.networking.error("Playback preparation paused after an unresolved server request.")
                    continuation.resume(throwing: pause.error)
                } else if work[key] != nil {
                    work[key]?.waiters[waiter] = reader
                } else if queues[server, default: []].count >= 16 {
                    PlozzLog.networking.error("Playback preparation queue is full.")
                    continuation.resume(throwing: AppError.rateLimited(retryAfter: nil))
                } else {
                    blocked.removeValue(forKey: server)
                    let (admission, permission) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    work[key] = Work(
                        server: server, sharesInventory: inventoryKey != nil,
                        admission: permission, waiters: [waiter: reader]
                    )
                    // Create the worker in its caller's task-local context, not
                    // the preceding request's diagnostics/authorization scope.
                    Task {
                        for await _ in admission {
                            let result: Result<PlaybackInfoResponse, Error>
                            do { result = .success(try await operation()) }
                            catch { result = .failure(error) }
                            finish(key: key, result: result)
                        }
                    }
                    queues[server, default: []].append(key)
                    startNext(server: server)
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(waiter: waiter, key: key) }
        }
    }

    private func startNext(server: String) {
        guard active[server] == nil, var queue = queues[server], !queue.isEmpty else { return }
        let key = queue.removeFirst()
        queues[server] = queue.isEmpty ? nil : queue
        guard var entry = work[key] else { return }
        let cancelled = entry.waiters.filter { $0.value.cancellation.isCancelled }
        for (id, reader) in cancelled {
            entry.waiters.removeValue(forKey: id)
            reader.continuation.resume(throwing: CancellationError())
        }
        guard !entry.waiters.isEmpty else {
            entry.admission.finish()
            work.removeValue(forKey: key)
            startNext(server: server)
            return
        }
        entry.started = true
        work[key] = entry
        active[server] = key
        entry.admission.yield(())
        entry.admission.finish()
    }

    private func cancel(waiter: UUID, key: Key) {
        guard var entry = work[key] else { return }
        // A started POST owns a playback session in its response. Deliver that
        // response to the cancelled caller so its existing lease cleanup runs.
        guard entry.sharesInventory || !entry.started else { return }
        entry.waiters.removeValue(forKey: waiter)?.continuation.resume(throwing: CancellationError())
        if entry.waiters.isEmpty, !entry.started {
            entry.admission.finish()
            work.removeValue(forKey: key)
            queues[entry.server]?.removeAll { $0 == key }
            if queues[entry.server]?.isEmpty == true { queues.removeValue(forKey: entry.server) }
        } else {
            work[key] = entry
        }
    }

    private func finish(key: Key, result: Result<PlaybackInfoResponse, Error>) {
        guard let entry = work.removeValue(forKey: key) else { return }
        active.removeValue(forKey: entry.server)
        if case .failure(let error) = result, let transportError = unresolvedWorkError(error) {
            var delay = backoff
            if case .rateLimited(let retryAfter) = transportError, let retryAfter,
               retryAfter.isFinite, retryAfter > 0 {
                // A malformed remote value must not overflow Duration/Instant.
                delay = max(delay, .seconds(min(retryAfter, Double(Int32.max))))
            }
            blocked[entry.server] = Backoff(until: .now.advanced(by: delay), error: transportError)
            let queued = queues.removeValue(forKey: entry.server) ?? []
            for pending in queued {
                guard let abandoned = work.removeValue(forKey: pending) else { continue }
                abandoned.admission.finish()
                abandoned.waiters.values.forEach {
                    $0.continuation.resume(throwing: transportError)
                }
            }
            PlozzLog.networking.error("Playback preparation stopped queued requests after an unresolved response.")
        }
        entry.waiters.values.forEach { $0.continuation.resume(with: result) }
        startNext(server: entry.server)
    }

    private func unresolvedWorkError(_ error: Error) -> AppError? {
        if let app = error as? AppError {
            switch app {
            case .serverUnreachable, .cancelled: return .serverUnreachable
            // HTTP 5xx (including proxy timeouts) maps to invalidResponse.
            case .rateLimited, .invalidResponse, .decoding: return app
            default: return nil
            }
        }
        if let url = error as? URLError, [.timedOut, .networkConnectionLost, .cancelled].contains(url.code) {
            return .serverUnreachable
        }
        if let streaming = error as? StreamingQualityError {
            switch streaming {
            case .serverHTTP(let status) where status == 408 || (500...599).contains(status):
                return .invalidResponse
            case .malformedResponse: return .decoding
            default: return nil
            }
        }
        return nil
    }
}
