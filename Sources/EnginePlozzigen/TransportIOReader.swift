#if canImport(AetherEngine)
import Foundation
import os
import AetherEngine
import MediaTransportCore

public typealias TransportByteSource = MediaTransportByteSource

private final class TransportInflightRead: @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var isCancelled = false
        var result: Result<Data, Error>?
    }

    let offset: Int64
    let length: Int
    let isPrefetch: Bool
    private let semaphore = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(offset: Int64, length: Int, isPrefetch: Bool = false) {
        self.offset = offset
        self.length = length
        self.isPrefetch = isPrefetch
    }

    func contains(_ position: Int64) -> Bool {
        position >= offset && position - offset < Int64(length)
    }

    var isCancelled: Bool { state.withLock { $0.isCancelled } }

    func attach(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            if state.result == nil, !state.isCancelled { state.task = task }
            return state.isCancelled
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.isCancelled = true
            state.result = nil
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
        semaphore.signal()
    }

    func finish(_ result: Result<Data, Error>) {
        state.withLock { state in
            if !state.isCancelled { state.result = result }
            state.task = nil
        }
        semaphore.signal()
    }

    func wait() -> Result<Data, Error> {
        if state.withLock({ $0.result == nil && !$0.isCancelled }) {
            semaphore.wait()
        }
        return state.withLock {
            $0.isCancelled ? .failure(MediaTransportError.cancelled) : $0.result!
        }
    }
}

/// Explicit playback teardown must also close clones still held by preview hosts.
private final class TransportReaderGroup: @unchecked Sendable {
    private final class WeakReader {
        weak var value: TransportIOReader?
        init(_ value: TransportIOReader) { self.value = value }
    }

    private let lock = NSLock()
    private var readers: [WeakReader] = []
    private var isClosed = false

    func register(_ reader: TransportIOReader) -> Bool {
        let accepted = lock.withLock {
            guard !isClosed else { return false }
            readers.removeAll { $0.value == nil }
            readers.append(WeakReader(reader))
            return true
        }
        if !accepted { reader.close() }
        return accepted
    }

    func closeAll() {
        let current = lock.withLock {
            isClosed = true
            let current = readers.compactMap(\.value)
            readers.removeAll()
            return current
        }
        current.forEach { $0.close() }
    }
}

public final class TransportIOReader: IOReader, @unchecked Sendable {
    public let discImageProbeEnabled: Bool

    private struct ReaderState {
        var position: Int64 = 0
        var isClosed = false
        /// In-memory read-ahead window. `bufferData` holds the bytes of the file
        /// starting at absolute offset `bufferStart`; empty when nothing is cached.
        /// ffmpeg's small (256 KB) AVIO reads are served from here so one large
        /// underlying transport round-trip satisfies many demux reads.
        var bufferStart: Int64 = 0
        var bufferData = Data()
        var probeWindows: [(start: Int64, data: Data)] = []
        var pendingRead: TransportInflightRead?
        var demandRead: TransportInflightRead?

        /// Bytes of `bufferData` available from `position` forward, or 0 on a miss.
        func bufferedAhead(from offset: Int64) -> Int {
            guard !bufferData.isEmpty else { return 0 }
            let delta = offset - bufferStart
            guard delta >= 0, delta < Int64(bufferData.count) else { return 0 }
            return bufferData.count - Int(delta)
        }

        mutating func window(containing offset: Int64) -> (start: Int64, data: Data)? {
            if bufferedAhead(from: offset) > 0 {
                return (bufferStart, bufferData)
            }
            guard let index = probeWindows.lastIndex(where: {
                offset >= $0.start && offset - $0.start < Int64($0.data.count)
            }) else { return nil }
            let window = probeWindows.remove(at: index)
            probeWindows.append(window)
            return window
        }
    }

    private let cursor: MediaTransportSourceCursor
    private let lease: MediaTransportSourceLease
    private let resolvedSource: MediaTransportResolvedSource?
    private let readerGroup: TransportReaderGroup
    private let readerState = OSAllocatedUnfairLock(initialState: ReaderState())
    private let avseekSize: Int32 = 65_536

    /// Existing window/chunk limits remain unchanged for transports that do not
    /// advertise efficient larger requests.
    static let defaultReadAheadWindow = 4 * 1024 * 1024  // 4 MB
    private static let defaultBackendChunk = 1024 * 1024
    private static let maximumReadAheadWindow = 32 * 1024 * 1024
    private static let minimumPrefetchWindow = 16 * 1024 * 1024
    private static let probeWindowSize = 64 * 1024
    private static let containerProbeWindowSize = 256 * 1024
    private static let maximumProbeWindows = 8
    private let readAheadWindow: Int
    private let maxBackendChunk: Int

    public convenience init(source: TransportByteSource, discImageProbeEnabled: Bool = true) {
        self.init(
            source: source,
            readAheadWindow: Self.defaultReadAheadWindow,
            discImageProbeEnabled: discImageProbeEnabled
        )
    }

    init(source: TransportByteSource, readAheadWindow: Int, discImageProbeEnabled: Bool = true) {
        self.discImageProbeEnabled = discImageProbeEnabled
        let lease = MediaTransportSourceLease(source: source)
        self.lease = lease
        self.resolvedSource = nil
        self.cursor = lease.makeCursor()!
        self.readAheadWindow = max(1, readAheadWindow)
        self.maxBackendChunk = min(max(1, lease.preferredReadSize), Self.maximumReadAheadWindow)
        self.readerGroup = TransportReaderGroup()
        _ = readerGroup.register(self)
    }

    public init(resolvedSource: MediaTransportResolvedSource, discImageProbeEnabled: Bool = true) {
        self.discImageProbeEnabled = discImageProbeEnabled
        self.resolvedSource = resolvedSource
        self.lease = resolvedSource.sourceLease
        self.cursor = resolvedSource.sourceLease.makeCursor()!
        self.readAheadWindow = Self.defaultReadAheadWindow
        self.maxBackendChunk = min(max(1, lease.preferredReadSize), Self.maximumReadAheadWindow)
        self.readerGroup = TransportReaderGroup()
        _ = readerGroup.register(self)
    }

    private init(
        cursor: MediaTransportSourceCursor,
        lease: MediaTransportSourceLease,
        resolvedSource: MediaTransportResolvedSource?,
        readAheadWindow: Int,
        discImageProbeEnabled: Bool,
        readerGroup: TransportReaderGroup
    ) {
        self.discImageProbeEnabled = discImageProbeEnabled
        self.cursor = cursor
        self.lease = lease
        self.resolvedSource = resolvedSource
        self.readAheadWindow = readAheadWindow
        self.maxBackendChunk = min(max(1, lease.preferredReadSize), Self.maximumReadAheadWindow)
        self.readerGroup = readerGroup
    }

    deinit {
        close()
    }

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let requestedLength = Int(size)

        // Fast path: serve from the in-memory read-ahead window without touching
        // the transport. `.hit` copies bytes out and advances the cursor.
        enum Probe { case closed, miss(offset: Int64), hit(count: Int) }
        let probe: Probe = readerState.withLock { state in
            guard !state.isClosed, state.demandRead == nil else { return .closed }
            let offset = state.position
            guard let window = state.window(containing: offset) else { return .miss(offset: offset) }
            let start = Int(offset - window.start)
            let ahead = window.data.count - start
            let count = min(ahead, requestedLength)
            window.data.withUnsafeBytes { raw in
                buffer.update(from: raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: count)
            }
            state.position = offset + Int64(count)
            return .hit(count: count)
        }
        switch probe {
        case .closed: return -1
        case .hit(let count):
            prefetchIfNeeded()
            return Int32(count)
        case .miss(let offset):
            return fetchAndServe(into: buffer, offset: offset, requestedLength: requestedLength)
        }
    }

    /// Small, scattered disc probes must not fetch movie-sized windows. Grow
    /// only when consuming contiguous windows; a random miss starts small again.
    private func fetchAndServe(
        into buffer: UnsafeMutablePointer<UInt8>,
        offset: Int64,
        requestedLength: Int
    ) -> Int32 {
        let byteSize = lease.byteSize
        let remaining = byteSize > offset ? Int(min(byteSize - offset, Int64(Int.max))) : 0
        guard remaining > 0 else { return 0 }  // at/past EOF
        let selected = readerState.withLock { state -> (TransportInflightRead, Bool, TransportInflightRead?)? in
            guard !state.isClosed, state.position == offset, state.demandRead == nil else { return nil }
            if let pending = state.pendingRead, pending.contains(offset) {
                state.demandRead = pending
                return (pending, false, nil)
            }
            let discarded = state.pendingRead
            let length: Int
            if maxBackendChunk > Self.defaultBackendChunk {
                let precedingWindowSize: Int
                if !state.bufferData.isEmpty, offset == state.bufferStart + Int64(state.bufferData.count) {
                    precedingWindowSize = state.bufferData.count
                } else if !discImageProbeEnabled, let cached = state.probeWindows.last(where: {
                    offset == $0.start + Int64($0.data.count)
                }) {
                    // Replaying the cached header after an index seek must not
                    // restart the sequential growth staircase.
                    precedingWindowSize = cached.data.count
                } else {
                    precedingWindowSize = 0
                }
                var window = precedingWindowSize > 0
                    ? min(precedingWindowSize * 4, maxBackendChunk) : Self.probeWindowSize
                // Ordinary containers can store their index at EOF. Finish a
                // bounded tail in one request instead of a slow growth staircase.
                if !discImageProbeEnabled, requestedLength >= Self.containerProbeWindowSize,
                   remaining <= Self.defaultReadAheadWindow {
                    window = max(window, remaining)
                }
                length = min(max(requestedLength, window), maxBackendChunk, remaining)
                state.bufferData = Data()
            } else {
                length = min(max(requestedLength, readAheadWindow), remaining)
            }
            let operation = TransportInflightRead(offset: offset, length: length)
            state.pendingRead = operation
            state.demandRead = operation
            return (operation, true, discarded)
        }
        guard let (operation, startsNewRead, discarded) = selected else { return -1 }
        discarded?.cancel()
        if startsNewRead { start(operation) }
        let outcome = operation.wait()
        let result = readerState.withLock { state -> Int32 in
            guard !state.isClosed, state.demandRead === operation, state.position == offset else { return -1 }
            state.demandRead = nil
            switch outcome {
            case .failure:
                // Keep the failed window until cancel or an out-of-window seek. AVIO
                // reads must not silently retry a rejected speculative request.
                if !operation.isPrefetch { state.pendingRead = nil }
                return -1
            case .success(let data):
                state.pendingRead = nil
                let start = Int(offset - operation.offset)
                guard start < data.count else { return 0 }
                let readCount = min(data.count - start, requestedLength)
                data.withUnsafeBytes { raw in
                    buffer.update(from: raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: readCount)
                }
                state.bufferStart = operation.offset
                state.bufferData = data
                if maxBackendChunk > Self.defaultBackendChunk, data.count <= Self.containerProbeWindowSize {
                    state.probeWindows.removeAll { $0.start == operation.offset }
                    state.probeWindows.append((operation.offset, data))
                    if state.probeWindows.count > Self.maximumProbeWindows {
                        state.probeWindows.removeFirst()
                    }
                }
                state.position = offset + Int64(readCount)
                return Int32(readCount)
            }
        }
        if result > 0 { prefetchIfNeeded() }
        return result
    }

    private func prefetchIfNeeded() {
        let operation = readerState.withLock { state -> TransportInflightRead? in
            guard !state.isClosed, state.pendingRead == nil, state.demandRead == nil,
                  maxBackendChunk > Self.defaultBackendChunk,
                  state.bufferData.count >= Self.minimumPrefetchWindow,
                  state.position - state.bufferStart >= Int64(state.bufferData.count / 2) else { return nil }
            let end = state.bufferStart + Int64(state.bufferData.count)
            guard state.position <= end, end < lease.byteSize else { return nil }
            let length = Int(min(Int64(min(state.bufferData.count * 4, maxBackendChunk)), lease.byteSize - end))
            let operation = TransportInflightRead(offset: end, length: length, isPrefetch: true)
            state.pendingRead = operation
            return operation
        }
        if let operation { start(operation) }
    }

    private func start(_ operation: TransportInflightRead) {
        let chunkSize = maxBackendChunk
        let task = Task.detached(priority: .userInitiated) { [cursor] in
            do {
                guard !operation.isCancelled else { throw MediaTransportError.cancelled }
                var assembled = Data()
                var cursorOffset = operation.offset
                // Fill the window with bounded reads, concatenating partial reads
                // (a backend may cap each read below the chunk size). Stop only on
                // an empty read (EOF / nothing more) or cancellation; the demux
                // re-reads any remainder and short reads are handled downstream.
                while assembled.count < operation.length {
                    try Task.checkCancellation()
                    let want = min(chunkSize, operation.length - assembled.count)
                    let piece = try await cursor.read(at: cursorOffset, length: want)
                    guard piece.count <= want else {
                        throw MediaTransportError.protocolViolation(reason: "source exceeded requested read length")
                    }
                    if piece.isEmpty { break }
                    if assembled.isEmpty {
                        assembled = piece
                    } else {
                        assembled.append(piece)
                    }
                    cursorOffset += Int64(piece.count)
                }
                try Task.checkCancellation()
                operation.finish(.success(assembled))
            } catch {
                operation.finish(.failure(error))
            }
        }
        operation.attach(task)
    }


    public func seek(offset: Int64, whence: Int32) -> Int64 {
        let result = readerState.withLock { state -> (Int64, TransportInflightRead?) in
            guard !state.isClosed else { return (-1, nil) }
            let candidate: Int64
            switch whence {
            case Int32(SEEK_SET):
                candidate = offset
            case Int32(SEEK_CUR):
                let (value, overflow) = state.position.addingReportingOverflow(offset)
                guard !overflow else { return (-1, nil) }
                candidate = value
            case Int32(SEEK_END):
                let (value, overflow) = lease.byteSize.addingReportingOverflow(offset)
                guard !overflow else { return (-1, nil) }
                candidate = value
            case avseekSize:
                return (lease.byteSize, nil)
            default:
                return (-1, nil)
            }
            guard candidate >= 0 else { return (-1, nil) }
            let discarded: TransportInflightRead?
            // A seek within the current buffer still needs the same next window.
            // Cancelling it here turns cached demux probes into repeated HTTP work.
            let keepsReadAhead = state.pendingRead?.contains(candidate) == true
                || (state.pendingRead?.isPrefetch == true && state.bufferedAhead(from: candidate) > 0)
            if candidate != state.position,
               state.demandRead != nil || !keepsReadAhead {
                discarded = state.pendingRead
                state.pendingRead = nil
                state.demandRead = nil
            } else {
                discarded = nil
            }
            state.position = candidate
            return (candidate, discarded)
        }
        result.1?.cancel()
        return result.0
    }

    public func cancel() {
        let pending = readerState.withLock { state in
            let pending = state.pendingRead
            state.pendingRead = nil
            state.demandRead = nil
            return pending
        }
        pending?.cancel()
    }

    public func makeIndependentReader() -> IOReader? {
        guard !readerState.withLock({ $0.isClosed }),
              let cursor = cursor.clone()
        else {
            return nil
        }
        let reader = TransportIOReader(
            cursor: cursor,
            lease: lease,
            resolvedSource: resolvedSource,
            readAheadWindow: readAheadWindow,
            discImageProbeEnabled: discImageProbeEnabled,
            readerGroup: readerGroup
        )
        return readerGroup.register(reader) ? reader : nil
    }

    /// Called only when the owning playback ends, not for a demuxer reopen.
    func closeAllReaders() {
        readerGroup.closeAll()
    }

    public func close() {
        let shouldRelease = readerState.withLock { state in
            guard !state.isClosed else { return false }
            state.isClosed = true
            state.bufferData = Data()
            state.probeWindows.removeAll()
            return true
        }
        guard shouldRelease else { return }
        cancel()
        cursor.close()
    }

    public func waitForFinalShutdown() async {
        if let resolvedSource {
            await resolvedSource.waitForFinalShutdown()
        } else {
            await lease.waitForFinalShutdown()
        }
    }
}
#endif
