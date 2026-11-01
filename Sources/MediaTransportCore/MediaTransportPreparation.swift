import CoreModels
import Foundation

/// Describes optional warming, not decoded coverage or playback readiness.
public enum MediaTransportPreparationWarmupOutcome: Sendable, Equatable {
    case completed
    case interruptedForPlayback
}

/// Keep this handle only while the initiating detail/profile context is valid.
/// Cancellation (including deinitialization) affects only this reservation, never
/// a replacement or a source already claimed by playback.
public final class MediaTransportPreparation: Sendable {
    private let cancellation: @Sendable () -> Void
    private let consumption: @Sendable () -> Bool
    private let handoff: @Sendable () -> Void
    private let readiness: @Sendable () async throws -> Void
    private let outcome: @Sendable () -> MediaTransportPreparationWarmupOutcome?

    init(
        cancellation: @escaping @Sendable () -> Void,
        consumption: @escaping @Sendable () -> Bool,
        handoff: @escaping @Sendable () -> Void,
        readiness: @escaping @Sendable () async throws -> Void,
        outcome: @escaping @Sendable () -> MediaTransportPreparationWarmupOutcome?
    ) {
        self.cancellation = cancellation
        self.consumption = consumption
        self.handoff = handoff
        self.readiness = readiness
        self.outcome = outcome
    }

    /// True only after a fully revalidated source was transferred to resolve().
    /// This does not claim the engine opened a cursor or playback began.
    public var wasConsumed: Bool { consumption() }

    /// Nil until the source has successfully drained and sealed. Historical
    /// evidence only: an expired or consumed reservation cannot be claimed again.
    public var warmupOutcome: MediaTransportPreparationWarmupOutcome? { outcome() }

    /// Only pending tickets from beginPreparation can interrupt warming.
    /// This does not cancel opening, acquire playback admission or claim a source.
    public func requestPlaybackHandoff() { handoff() }

    /// Waits for successful sealing, including an intentional interrupted warmup.
    /// Does not claim the source. Cancellation cancels this ticket's generation.
    public func waitUntilReady() async throws { try await readiness() }

    public func cancel() { cancellation() }
    deinit { cancellation() }
}

/// Cancels only the optional borrower. The preparation worker keeps the original
/// source/session ownership and joins both callback and reads before publication.
final class MediaTransportPreparationWarmup: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var finished = false
    private var task: Task<Void, Error>?
    private var borrowed: MediaTransportPreparationBorrow?
    private var outcomeStorage: MediaTransportPreparationWarmupOutcome = .completed

    var outcome: MediaTransportPreparationWarmupOutcome { lock.withLock { outcomeStorage } }

    func requestPlaybackHandoff() {
        let current = lock.withLock { () -> (Task<Void, Error>?, MediaTransportPreparationBorrow?) in
            guard !finished else { return (nil, nil) }
            requested = true
            return (task, borrowed)
        }
        current.0?.cancel()
        current.1?.close()
    }

    private func cancelBorrower() {
        let current = lock.withLock { (task, borrowed) }
        current.0?.cancel()
        current.1?.close()
    }

    func run(
        borrowed: MediaTransportPreparationBorrow,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let work = lock.withLock { () -> Task<Void, Error>? in
            guard !requested else { return nil }
            let work = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try await operation()
            }
            self.task = work
            self.borrowed = borrowed
            return work
        }
        let result: Result<Void, Error> = await withTaskCancellationHandler {
            let result = await work?.result ?? .success(())
            await borrowed.shutdown()
            return result
        } onCancel: {
            self.cancelBorrower()
        }
        let interrupted = lock.withLock {
            finished = true
            task = nil
            self.borrowed = nil
            outcomeStorage = requested ? .interruptedForPlayback : .completed
            return requested
        }
        // A callback may translate a read failure to cancellation or swallow it.
        // Preserve the actual transport failure observed by the borrowed source.
        if let failure = borrowed.firstFailure { throw failure }
        if case .failure(let error) = result {
            guard interrupted, isPreparationCancellation(error) else { throw error }
        }
        try Task.checkCancellation()
    }
}

func isPreparationCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? MediaTransportError) == .cancelled
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
        var outcome: MediaTransportPreparationWarmupOutcome?
        let consumption = PreparationConsumption()
    }

    private struct Entry {
        let id: UUID
        let locator: NetworkFileLocator
        let work: Task<MediaTransportPreparedResource, Error>
        let drained: Task<Void, Never>
        let ready: PreparationSignal<Result<Void, Error>>
        let status: Status
        let warmup: MediaTransportPreparationWarmup?
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
        let handle = try begin(locator, operation: operation)
        try await handle.waitUntilReady()
        return handle
    }

    func begin(
        _ locator: NetworkFileLocator,
        warmup: MediaTransportPreparationWarmup? = nil,
        operation: @escaping @Sendable () async throws -> MediaTransportPreparedResource
    ) throws -> MediaTransportPreparation {
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
            entry = Entry(
                id: id, locator: locator, work: work, drained: drained, ready: ready,
                status: status, warmup: warmup
            )
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
        let consumption = status.consumption
        return MediaTransportPreparation(
            cancellation: { [self] in cancel(id: id) },
            consumption: { consumption.wasConsumed },
            handoff: { [self] in requestPlaybackHandoff(id: id) },
            readiness: { [self] in
                try await withTaskCancellationHandler {
                    try await ready.wait().get()
                    try Task.checkCancellation()
                    try lock.withLock {
                        if let error = status.error { throw error }
                    }
                } onCancel: {
                    self.cancel(id: id)
                }
            },
            outcome: { [self] in lock.withLock { status.outcome } }
        )
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
        requestPlaybackHandoff(id: candidate.id)
        return try await withTaskCancellationHandler {
            do {
                try await candidate.ready.wait().get()
            } catch {
                // A failed pending ticket carries its observed error to the
                // first exact Play, rather than turning into a silent cold miss.
                let expired = lock.withLock {
                    if let expiry = candidate.expiresAt, timing.now() >= expiry {
                        if entry?.id == candidate.id {
                            cancelLocked(error: MediaTransportError.cancelled, expired: true)
                        }
                        return true
                    }
                    if entry?.id == candidate.id {
                        entry?.timer?.cancel()
                        entry = nil
                    }
                    return candidate.status.expired
                }
                if expired {
                    await candidate.drained.value
                    try Task.checkCancellation()
                    return nil
                }
                throw error
            }
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

    private func requestPlaybackHandoff(id: UUID) {
        let warmup = lock.withLock {
            entry?.id == id ? entry?.warmup : nil
        }
        warmup?.requestPlaybackHandoff()
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
                current.status.outcome = current.warmup?.outcome ?? .completed
                current.resource = resource
                current.expiresAt = timing.now().advanced(by: timing.lifetime)
                current.timer = timer(after: timing.lifetime, id: id, error: .cancelled, expired: true)
                entry = current
                current.ready.resolve(.success(()))
            case .failure(let error):
                current.status.error = error
                cancelledDrain = current.drained
                if current.warmup != nil {
                    // Resource-free and bounded; cancellation/supersession or
                    // the first claim removes this failed pending ticket.
                    current.expiresAt = timing.now().advanced(by: timing.lifetime)
                    current.timer = timer(
                        after: timing.lifetime, id: id, error: .cancelled, expired: true
                    )
                    entry = current
                } else {
                    entry = nil
                }
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
