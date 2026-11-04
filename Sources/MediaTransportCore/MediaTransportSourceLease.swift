import Foundation

public protocol MediaTransportByteSource: AnyObject, Sendable {
    var byteSize: Int64 { get }
    /// False for streaming compatibility without a content-change validator.
    /// Ranged bytes may be buffered within this lease, not persisted for reuse.
    /// Whole-response downloads require the separate whole-file contract below.
    var supportsPersistentByteReuse: Bool { get }
    /// Efficient bounded request size. Larger values opt readers into adaptive
    /// sequential read-ahead; the source still enforces its own protocol limits.
    var preferredReadSize: Int { get }
    /// Returns up to `length` bytes. A short positive read is not EOF (for
    /// example, a validated preparation window may end mid-request). Callers
    /// advance by the returned count; an empty result denotes EOF.
    func read(at offset: Int64, length: Int) async throws -> Data
    func shutdown() async
}

public extension MediaTransportByteSource {
    var preferredReadSize: Int { 1024 * 1024 }
    var supportsPersistentByteReuse: Bool { true }
}

/// A separate persistence contract: one complete response may be saved, but
/// partial/ranged bytes must never be reused across attempts.
public protocol MediaTransportWholeFileByteSource: MediaTransportByteSource {
    func readWholeFile(consume: @escaping @Sendable (Data) async throws -> Void) async throws
}

/// Optional lock-only transition from preparation to playback. Called after all
/// borrowed preparation reads drain, before the reservation is published, even
/// without a source preparer. Freeze bounded validated caches here; do no I/O.
public protocol MediaTransportPreparationFinalizingByteSource: MediaTransportByteSource {
    func finishPreparation()
}

/// Optional specialization for transports that require a distinct underlying
/// channel per logical cursor. A cancelled read may tear down that cursor's
/// channel without disrupting cloned cursors that share the same lease.
public protocol MediaTransportCursorIsolatedByteSource: MediaTransportByteSource {
    func read(
        cursorID: UUID,
        at offset: Int64,
        length: Int
    ) async throws -> Data
    func release(cursorID: UUID) async
}

/// Reference-counted ownership for a random-access source.
///
/// Cursors are independent. Closing or cancelling one cursor never closes
/// another, and the source shuts down exactly once after the final cursor and
/// every read already admitted by the lease have drained. A lease that never
/// creates a cursor owns the source until `close()` or deinitialization.
/// Internal preparation cursors borrow, rather than claim, that initial
/// ownership; closing a probe cannot close a future playback reservation.
public final class MediaTransportSourceLease: @unchecked Sendable {
    private struct State {
        var hasUnclaimedLease = true
        var cursorIDs: Set<UUID> = []
        var operationCount = 0
        var isDraining = false
        var shutdownStarted = false
        var shutdownComplete = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let source: any MediaTransportByteSource
    private let lock = NSLock()
    private var state = State()

    public init(source: any MediaTransportByteSource) {
        self.source = source
    }

    deinit {
        let shouldShutdown = lock.withLock {
            guard state.hasUnclaimedLease, !state.shutdownStarted else { return false }
            state.hasUnclaimedLease = false
            state.isDraining = true
            state.shutdownStarted = true
            return true
        }
        if shouldShutdown {
            let source = self.source
            Task.detached(priority: .utility) {
                await source.shutdown()
            }
        }
    }

    public var byteSize: Int64 { source.byteSize }
    public var preferredReadSize: Int { source.preferredReadSize }
    public var supportsPersistentByteReuse: Bool { source.supportsPersistentByteReuse }
    public var supportsWholeFileRead: Bool { source is any MediaTransportWholeFileByteSource }

    fileprivate func readWholeFile(
        consume: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        guard let source = source as? any MediaTransportWholeFileByteSource else {
            throw MediaTransportError.invalidInput(reason: "whole-file transfer unavailable")
        }
        try await source.readWholeFile(consume: consume)
    }

    func finishPreparation() {
        (source as? any MediaTransportPreparationFinalizingByteSource)?.finishPreparation()
    }

    public func makeCursor() -> MediaTransportSourceCursor? {
        let id = UUID()
        let admitted = lock.withLock {
            guard !state.isDraining else { return false }
            state.hasUnclaimedLease = false
            state.cursorIDs.insert(id)
            return true
        }
        return admitted ? MediaTransportSourceCursor(id: id, lease: self) : nil
    }

    /// Preparation alone may borrow a cursor without consuming the initial
    /// ownership. The resolver drains this borrow before publishing the lease.
    func makePreparationBorrow() throws -> MediaTransportPreparationBorrow {
        let id = UUID()
        try lock.withLock {
            guard state.hasUnclaimedLease, !state.isDraining,
                  state.cursorIDs.isEmpty, state.operationCount == 0 else {
                throw MediaTransportError.invalidInput(reason: "source is not available for preparation")
            }
            state.cursorIDs.insert(id)
        }
        return MediaTransportPreparationBorrow(
            cursor: MediaTransportSourceCursor(id: id, lease: self),
            preferredReadSize: preferredReadSize
        )
    }

    public func close() {
        let shouldShutdown = lock.withLock {
            guard state.hasUnclaimedLease else { return false }
            state.hasUnclaimedLease = false
            state.isDraining = true
            return markShutdownIfReady()
        }
        if shouldShutdown {
            startShutdown()
        }
    }

    public func waitForFinalShutdown() async {
        close()
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                guard !state.shutdownComplete else { return true }
                state.waiters.append(continuation)
                return false
            }
            if complete {
                continuation.resume()
            }
        }
    }

    fileprivate func beginOperation(cursorID: UUID) -> Bool {
        lock.withLock {
            guard state.cursorIDs.contains(cursorID), !state.isDraining else {
                return false
            }
            state.operationCount += 1
            return true
        }
    }

    fileprivate func read(
        cursorID: UUID,
        at offset: Int64,
        length: Int
    ) async throws -> Data {
        if let isolatedSource = source as? any MediaTransportCursorIsolatedByteSource {
            return try await isolatedSource.read(
                cursorID: cursorID,
                at: offset,
                length: length
            )
        }
        return try await source.read(at: offset, length: length)
    }

    fileprivate func endOperation() {
        let shouldShutdown = lock.withLock {
            precondition(state.operationCount > 0)
            state.operationCount -= 1
            return markShutdownIfReady()
        }
        if shouldShutdown {
            startShutdown()
        }
    }

    fileprivate func release(cursorID: UUID) {
        let outcome = lock.withLock { () -> (released: Bool, shouldShutdown: Bool) in
            guard state.cursorIDs.remove(cursorID) != nil else {
                return (false, false)
            }
            if state.cursorIDs.isEmpty, !state.hasUnclaimedLease {
                state.isDraining = true
            }
            return (true, markShutdownIfReady())
        }
        guard outcome.released else { return }
        if let isolatedSource = source as? any MediaTransportCursorIsolatedByteSource {
            Task.detached(priority: .utility) {
                await isolatedSource.release(cursorID: cursorID)
            }
        }
        if outcome.shouldShutdown {
            startShutdown()
        }
    }

    private func markShutdownIfReady() -> Bool {
        guard state.isDraining, state.cursorIDs.isEmpty,
              state.operationCount == 0, !state.shutdownStarted else {
            return false
        }
        state.shutdownStarted = true
        return true
    }

    private func startShutdown() {
        Task.detached(priority: .utility) { [self, source] in
            await source.shutdown()
            let waiters = lock.withLock {
                state.shutdownComplete = true
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
}

/// Closing a probe reader closes its borrowed cursor, not the underlying source.
/// The wrapper also joins reads that ignore cancellation before it reports
/// shutdown, and drops its cursor so a retained, closed wrapper pins no lease.
final class MediaTransportPreparationBorrow: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64
    let preferredReadSize: Int
    let supportsPersistentByteReuse: Bool
    private let lock = NSLock()
    private var cursor: MediaTransportSourceCursor?
    private var reads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var failure: Error?

    fileprivate init(cursor: MediaTransportSourceCursor, preferredReadSize: Int) {
        self.cursor = cursor
        self.byteSize = cursor.byteSize
        self.preferredReadSize = preferredReadSize
        self.supportsPersistentByteReuse = cursor.supportsPersistentByteReuse
    }

    deinit { close() }

    var firstFailure: Error? { lock.withLock { failure } }

    func read(at offset: Int64, length: Int) async throws -> Data {
        let cursor = try lock.withLock {
            guard let cursor = self.cursor else { throw MediaTransportError.cancelled }
            reads += 1
            return cursor
        }
        defer {
            let waiters = lock.withLock {
                reads -= 1
                guard reads == 0, self.cursor == nil else {
                    return [CheckedContinuation<Void, Never>]()
                }
                let waiters = self.waiters
                self.waiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
        do {
            return try await cursor.read(at: offset, length: length)
        } catch {
            if !isPreparationCancellation(error) {
                lock.withLock {
                    if failure == nil { failure = error }
                }
            }
            throw error
        }
    }

    func close() {
        lock.withLock {
            cursor?.close()
            cursor = nil
        }
    }

    func shutdown() async {
        close()
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                guard reads != 0 else { return true }
                waiters.append(continuation)
                return false
            }
            if complete { continuation.resume() }
        }
    }
}

public final class MediaTransportSourceCursor: @unchecked Sendable {
    private struct State {
        var isClosed = false
        var reads: [UUID: Task<Data, Error>] = [:]
    }

    private let id: UUID
    private let lease: MediaTransportSourceLease
    private let lock = NSLock()
    private var state = State()

    fileprivate init(id: UUID, lease: MediaTransportSourceLease) {
        self.id = id
        self.lease = lease
    }

    deinit {
        close()
    }

    public var byteSize: Int64 { lease.byteSize }
    public var supportsPersistentByteReuse: Bool { lease.supportsPersistentByteReuse }

    public func clone() -> MediaTransportSourceCursor? {
        guard !lock.withLock({ state.isClosed }) else { return nil }
        return lease.makeCursor()
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid byte range")
        }
        return try await performRead { [lease, id] in
            try await lease.read(cursorID: id, at: offset, length: length)
        }
    }

    public func readWholeFile(
        consume: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = try await performRead { [lease] in
            try await lease.readWholeFile(consume: consume)
            return Data()
        }
    }

    private func performRead(_ operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        guard lease.beginOperation(cursorID: id) else {
            throw MediaTransportError.cancelled
        }
        let operationID = UUID()
        let task = lock.withLock { () -> Task<Data, Error>? in
            guard !state.isClosed else { return nil }
            let task = Task.detached(priority: .userInitiated) {
                try await operation()
            }
            state.reads[operationID] = task
            return task
        }
        guard let task else {
            lease.endOperation()
            throw MediaTransportError.cancelled
        }
        defer {
            _ = lock.withLock { state.reads.removeValue(forKey: operationID) }
            lease.endOperation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels this cursor's current reads only. The cursor remains reusable.
    public func cancel() {
        let reads = lock.withLock { Array(state.reads.values) }
        reads.forEach { $0.cancel() }
    }

    public func close() {
        let shouldRelease = lock.withLock {
            guard !state.isClosed else { return false }
            state.isClosed = true
            return true
        }
        guard shouldRelease else { return }
        cancel()
        lease.release(cursorID: id)
    }
}
