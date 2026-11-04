import Foundation

/// Local debug evidence only; never included in automatic diagnostic uploads.
final class PlaybackTraceRecorder: @unchecked Sendable {
    static let segmentBytes = 1_024 * 1_024
    static let segmentCount = 4
    static let failureBytes = 512 * 1_024
    static let failureCount = 3
    static let exportBytes = 64 * 1_024
    static let recordBytes = 16 * 1_024
    static let pendingBytes = 256 * 1_024

    enum StorageIssue: String, Sendable {
        case locationUnavailable, writeFailed, snapshotFailed, queueOverflow
    }

    private struct Pending {
        let data: Data
        let failure: Bool
        let attempt: UUID?
    }

    private let directory: URL?
    private let limit: Int
    private let failureLimit: Int
    private let report: @Sendable (StorageIssue) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var pendingSize = 0
    private var scheduled = false
    private var dropped = 0
    private var handle: FileHandle?
    private var size = 0
    private var lastFailureAttempt: UUID?

    init(
        directory: URL?, segmentBytes: Int = PlaybackTraceRecorder.segmentBytes,
        failureBytes: Int = PlaybackTraceRecorder.failureBytes,
        queue: DispatchQueue = DispatchQueue(label: "com.plozz.playbackTrace", qos: .utility),
        report: @escaping @Sendable (StorageIssue) -> Void
    ) {
        precondition(segmentBytes >= 128 && failureBytes >= 128)
        self.directory = directory
        self.queue = queue
        limit = segmentBytes
        failureLimit = failureBytes
        self.report = report
    }

    deinit { try? handle?.close() }

    func append(_ line: String, failure: Bool = false, attempt: UUID? = nil, timestamp: Date = Date()) {
        let prefix = String(format: "%.3f PLZXHAND ", timestamp.timeIntervalSince1970)
        let cap = min(Self.recordBytes, limit, failureLimit)
        let raw = Data((prefix + line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        let data: Data
        if raw.count > cap {
            var bytes = Data(raw.prefix(cap - 16))
            while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
            bytes.append(Data(" [truncated]\n".utf8))
            data = bytes
        } else {
            data = raw
        }
        lock.lock()
        if failure {
            while pendingSize + data.count > Self.pendingBytes || pending.count >= 512 {
                guard let index = pending.firstIndex(where: { !$0.failure }) else { break }
                pendingSize -= pending.remove(at: index).data.count
                dropped = min(dropped + 1, 1_000_000_000)
            }
        }
        if pendingSize + data.count <= Self.pendingBytes, pending.count < 512 {
            pending.append(Pending(data: data, failure: failure, attempt: attempt))
            pendingSize += data.count
        } else {
            dropped = min(dropped + 1, 1_000_000_000)
        }
        if !scheduled {
            scheduled = true
            queue.async { self.drain() }
        }
        lock.unlock()
    }

    /// Existing consumers keep a 64 KiB tail rather than exporting the whole archive.
    func snapshot() -> String {
        queue.sync {
            drain()
            do { return String(decoding: try tail(maximumBytes: Self.exportBytes), as: UTF8.self) }
            catch { report(.snapshotFailed); return "" }
        }
    }

    private func drain() {
        lock.lock()
        let batch = pending
        let lost = dropped
        pending.removeAll(keepingCapacity: true)
        pendingSize = 0
        dropped = 0
        scheduled = false
        lock.unlock()
        if lost > 0 { report(.queueOverflow) }
        guard let directory else {
            if !batch.isEmpty { report(.locationUnavailable) }
            return
        }
        for entry in batch {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try openIfNeeded()
                if size + entry.data.count > limit {
                    try handle?.close()
                    handle = nil
                    try rotate(prefix: "playback-trace", count: Self.segmentCount)
                    size = 0
                    try openIfNeeded()
                }
                try handle?.write(contentsOf: entry.data)
                size += entry.data.count
                if entry.failure {
                    let evidence = try tail(maximumBytes: failureLimit)
                    // A timeout and its typed failure describe the same attempt.
                    if entry.attempt == nil || entry.attempt != lastFailureAttempt {
                        try rotate(prefix: "playback-failure", count: Self.failureCount)
                    }
                    try evidence.write(
                        to: path(prefix: "playback-failure", index: 0), options: .atomic
                    )
                    lastFailureAttempt = entry.attempt
                }
            } catch {
                try? handle?.close()
                handle = nil
                report(.writeFailed)
            }
        }
    }

    private func path(prefix: String, index: Int) -> URL {
        directory!.appendingPathComponent(index == 0 ? "\(prefix).log" : "\(prefix).\(index).log")
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let url = path(prefix: "playback-trace", index: 0)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let file = try FileHandle(forWritingTo: url)
        do {
            let end = try file.seekToEnd()
            if end > UInt64(limit) {
                // Discard only the oversized current segment from an older configuration.
                try file.truncate(atOffset: 0)
                try file.seek(toOffset: 0)
                size = 0
            } else {
                size = Int(end)
            }
            handle = file
        } catch {
            try? file.close()
            throw error
        }
    }

    private func rotate(prefix: String, count: Int) throws {
        let manager = FileManager.default
        let oldest = path(prefix: prefix, index: count - 1)
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: count - 2, through: 0, by: -1) {
            let source = path(prefix: prefix, index: index)
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: path(prefix: prefix, index: index + 1))
            }
        }
    }

    private func tail(maximumBytes: Int) throws -> Data {
        guard directory != nil else { return Data() }
        var result = Data()
        for index in 0..<Self.segmentCount {
            let url = path(prefix: "playback-trace", index: index)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let length = try file.seekToEnd()
            let count = min(UInt64(maximumBytes - result.count), length)
            try file.seek(toOffset: length - count)
            var bytes = try file.read(upToCount: Int(count)) ?? Data()
            if count < length, let newline = bytes.firstIndex(of: 10) {
                bytes.removeSubrange(...newline)
            }
            bytes.append(result)
            result = bytes
            if count < length || result.count == maximumBytes { break }
        }
        return result
    }
}
