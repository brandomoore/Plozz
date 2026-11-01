import CoreModels
import Foundation

/// Keep this handle only while the initiating detail/profile context is valid.
/// Cancellation (including deinitialization) affects only this reservation, never
/// a replacement or a source already claimed by playback.
public final class MediaTransportPreparation: Sendable {
    private let cancellation: @Sendable () -> Void
    private let consumption: @Sendable () -> Bool

    init(
        cancellation: @escaping @Sendable () -> Void,
        consumption: @escaping @Sendable () -> Bool
    ) {
        self.cancellation = cancellation
        self.consumption = consumption
    }

    /// True only after a fully revalidated source was transferred to resolve().
    /// This does not claim the engine opened a cursor or playback began.
    public var wasConsumed: Bool { consumption() }

    public func cancel() { cancellation() }
    deinit { cancellation() }
}

fileprivate final class PreparationConsumption: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    var wasConsumed: Bool { lock.withLock { consumed } }
    func markConsumed() { lock.withLock { consumed = true } }
}

struct MediaTransportPreparationTiming: Sendable {
    /// Deadline for opening and read-only position-aware probing, not the TTL.
    /// Timeout cancels work; cleanup still waits for in-flight reads to drain.
    static let defaultTimeout: Duration = .seconds(30)

    var lifetime: Duration = .seconds(30)
    var timeout: Duration = MediaTransportPreparationTiming.defaultTimeout
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// Multiple Play/prepare callers can observe completion without owning its
/// resource. Resolving a signal never transfers a lease.
private final class PreparationSignal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let value: Value? = lock.withLock {
                if let value = self.value { return value }
                waiters.append(continuation)
                return nil
            }
            if let value { continuation.resume(returning: value) }
        }
    }

    func resolve(_ value: Value) {
        let waiters = lock.withLock {
            guard self.value == nil else { return [CheckedContinuation<Value, Never>]() }
            self.value = value
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(returning: value) }
    }
}

/// Separate ownership from the resolved object so transferring an unclaimed
/// source cannot trigger an old resolved object's close-on-deinit.
final class MediaTransportPreparedResource: @unchecked Sendable {
    private struct Ownership {
        let source: MediaTransportSourceLease
        let session: MediaTransportResolverLease
    }

    private let lock = NSLock()
    private var ownership: Ownership?
    private var releaseTask: Task<Void, Never>?
    private let disposition = PreparationSignal<Void>()
    private var consumption: PreparationConsumption?

    init(source: MediaTransportSourceLease, session: MediaTransportResolverLease) {
        ownership = Ownership(source: source, session: session)
    }

    deinit { discard() }

    var sessionLease: MediaTransportResolverLease {
        lock.withLock { ownership!.session }
    }

    fileprivate func trackConsumption(_ consumption: PreparationConsumption) {
        lock.withLock { self.consumption = consumption }
    }

    func transfer(playbackLease: MediaIOPlaybackLease?) -> MediaTransportResolvedSource {
        let owned = lock.withLock {
            let owned = ownership!
            ownership = nil
            consumption?.markConsumed()
            return owned
        }
        disposition.resolve(())
        return MediaTransportResolvedSource(
            sourceLease: owned.source,
            sessionLease: owned.session,
            playbackLease: playbackLease,
            wasPrepared: true
        )
    }

    @discardableResult
    func discard() -> Task<Void, Never> {
        lock.withLock {
            if let releaseTask { return releaseTask }
            let owned = ownership
            ownership = nil
            let disposition = disposition
            let task = Task.detached {
                if let owned {
                    owned.source.close()
                    await owned.source.waitForFinalShutdown()
                    owned.session.release()
                }
                disposition.resolve(())
            }
            releaseTask = task
            return task
        }
    }

    func waitForDisposition() async { await disposition.wait() }
}

/// One reservation across resolver copies. Superseded operations drain before
/// the next preparation opens; a late completion can only dispose its own source.
final class MediaTransportPreparationCoordinator: @unchecked Sendable {
    /// Accessed only under the coordinator lock, including after entry removal.
    private final class Status: @unchecked Sendable {
        var error: Error?
        var expired = false
        var claimed = false
        let consumption = PreparationConsumption()
    }

    private struct Entry {
        let id: UUID
        let locator: NetworkFileLocator
        let work: Task<MediaTransportPreparedResource, Error>
        let drained: Task<Void, Never>
        let ready: PreparationSignal<Result<Void, Error>>
        let status: Status
        var timer: Task<Void, Never>?
        var resource: MediaTransportPreparedResource?
        var expiresAt: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private let timing: MediaTransportPreparationTiming
    private var entry: Entry?
    private var cancelledDrain: Task<Void, Never>?

    init(timing: MediaTransportPreparationTiming) { self.timing = timing }

    deinit {
        entry?.work.cancel()
        entry?.timer?.cancel()
        entry?.resource?.discard()
        entry?.ready.resolve(.failure(MediaTransportError.cancelled))
    }

    func prepare(
        _ locator: NetworkFileLocator,
        operation: @escaping @Sendable () async throws -> MediaTransportPreparedResource
    ) async throws -> MediaTransportPreparation {
        try Task.checkCancellation()
        let (id, ready, status) = lock.withLock {
            cancelLocked(error: MediaTransportError.cancelled)
            let id = UUID()
            let priorDrain = cancelledDrain
            let ready = PreparationSignal<Result<Void, Error>>()
            let status = Status()
            let work = Task.detached(priority: .utility) {
                await priorDrain?.value
                try Task.checkCancellation()
                return try await operation()
            }
            let drained = Task.detached {
                if case .success(let resource) = await work.result {
                    await resource.waitForDisposition()
                }
            }
            entry = Entry(id: id, locator: locator, work: work, drained: drained, ready: ready, status: status)
            entry?.timer = timer(after: timing.timeout, id: id, error: .timeout)
            Task { [weak self] in
                let result = await work.result
                guard let self else {
                    if case .success(let resource) = result { await resource.discard().value }
                    return
                }
                self.complete(id: id, result: result)
            }
            return (id, ready, status)
        }
        return try await withTaskCancellationHandler {
            try await ready.wait().get()
            try Task.checkCancellation()
            try lock.withLock {
                if let error = status.error { throw error }
            }
            let consumption = status.consumption
            return MediaTransportPreparation(
                cancellation: { [self] in cancel(id: id) },
                consumption: { consumption.wasConsumed }
            )
        } onCancel: {
            self.cancel(id: id)
        }
    }

    /// Taking a reservation is single-use. The caller now owns cleanup through
    /// validation, admission and transfer; the browsing handle can no longer
    /// close it. Probe resolvers never call this method.
    func claim(_ locator: NetworkFileLocator) async throws -> MediaTransportPreparedResource? {
        let candidate = lock.withLock { () -> Entry? in
            guard entry?.locator == locator else { return nil }
            return entry
        }
        guard let candidate else {
            // A previous cancelled open must drain before an ordinary open can
            // race it. A ready reservation for a different file is left alone.
            let drain = lock.withLock { cancelledDrain }
            await drain?.value
            try Task.checkCancellation()
            return nil
        }
        return try await withTaskCancellationHandler {
            try await candidate.ready.wait().get()
            try Task.checkCancellation()
            let claimed = try lock.withLock { () throws -> MediaTransportPreparedResource? in
                if candidate.status.expired || candidate.status.claimed { return nil }
                if let error = candidate.status.error { throw error }
                guard let current = entry, current.id == candidate.id else {
                    throw MediaTransportError.cancelled
                }
                guard let expiry = current.expiresAt, timing.now() < expiry else {
                    cancelLocked(error: MediaTransportError.cancelled, expired: true)
                    return nil
                }
                entry = nil
                current.status.claimed = true
                current.timer?.cancel()
                return current.resource
            }
            if claimed == nil {
                await candidate.drained.value
                try Task.checkCancellation()
            }
            return claimed
        } onCancel: {
            self.cancel(id: candidate.id)
        }
    }

    func cancel(locator: NetworkFileLocator) {
        lock.withLock {
            guard entry?.locator == locator else { return }
            cancelLocked(error: MediaTransportError.cancelled)
        }
    }

    private func cancel(id: UUID) {
        lock.withLock {
            guard entry?.id == id else { return }
            cancelLocked(error: MediaTransportError.cancelled)
        }
    }

    private func cancelLocked(error: Error, expired: Bool = false) {
        guard let current = entry else { return }
        entry = nil
        current.status.error = error
        current.status.expired = expired
        current.work.cancel()
        current.timer?.cancel()
        current.resource?.discard()
        current.ready.resolve(.failure(error))
        cancelledDrain = current.drained
    }

    private func complete(id: UUID, result: Result<MediaTransportPreparedResource, Error>) {
        lock.withLock {
            guard var current = entry, current.id == id else {
                if case .success(let resource) = result { resource.discard() }
                return
            }
            current.timer?.cancel()
            switch result {
            case .success(let resource):
                resource.trackConsumption(current.status.consumption)
                current.resource = resource
                current.expiresAt = timing.now().advanced(by: timing.lifetime)
                current.timer = timer(after: timing.lifetime, id: id, error: .cancelled, expired: true)
                entry = current
                current.ready.resolve(.success(()))
            case .failure(let error):
                entry = nil
                current.status.error = error
                cancelledDrain = current.drained
                current.ready.resolve(.failure(error))
            }
        }
    }

    private func timer(
        after duration: Duration,
        id: UUID,
        error: MediaTransportError,
        expired: Bool = false
    ) -> Task<Void, Never> {
        let sleep = timing.sleep
        return Task { [weak self] in
            do { try await sleep(duration) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock {
                guard self.entry?.id == id else { return }
                self.cancelLocked(error: error, expired: expired)
            }
        }
    }
}
