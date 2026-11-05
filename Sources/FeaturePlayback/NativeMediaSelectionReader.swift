#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreNetworking
import Foundation

/// Bounded native selection IPC for the host's caption and audio controls.
public final class NativeMediaSelectionReader: @unchecked Sendable {
    /// An immutable option descriptor; nil means a confirmed empty selection.
    public struct Snapshot: @unchecked Sendable {
        public let option: AVMediaSelectionOption?
    }

    public static let shared = NativeMediaSelectionReader()
    private let lock = NSLock()
    private var running = 0
    private var loggedUnavailable = false
    private static let deadlines = DispatchQueue(label: "Plozz.native-selection-deadlines")

    /// A nil snapshot means the service was unavailable, not that subtitles were turned off.
    @MainActor
    public func read(item: AVPlayerItem, group: AVMediaSelectionGroup) async -> Snapshot? {
        await read(timeout: 0.5) {
            Snapshot(option: item.currentMediaSelection.selectedMediaOption(in: group))
        }
    }

    func read(timeout: TimeInterval, query: @escaping @Sendable () -> Snapshot) async -> Snapshot? {
        guard !Task.isCancelled else { return nil }
        let admitted = lock.withLock {
            guard running < 2 else { return false }
            running += 1
            return true
        }
        guard admitted else { logUnavailable(); return nil }
        let completion = Completion()
        let result: Snapshot? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                Self.deadlines.asyncAfter(deadline: .now() + timeout) { completion.finish(nil) }
                let worker = Thread { [self] in
                    let value = query()
                    // Timeout/cancellation only releases the waiter, never a blocked native lane.
                    lock.withLock { running -= 1 }
                    completion.finish(value)
                }
                worker.name = "Plozz.native-selection"
                worker.qualityOfService = .utility
                worker.start()
            }
        } onCancel: { completion.finish(nil) }
        guard !Task.isCancelled else { return nil }
        if result == nil { logUnavailable() }
        return result
    }

    private func logUnavailable() {
        let shouldLog = lock.withLock {
            guard !loggedUnavailable else { return false }
            loggedUnavailable = true
            return true
        }
        if shouldLog {
            PlozzLog.playback.error("Native media selection unavailable: read timed out or reader lanes occupied.")
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var result: Snapshot?
        private var continuation: CheckedContinuation<Snapshot?, Never>?

        func install(_ continuation: CheckedContinuation<Snapshot?, Never>) {
            let completed = lock.withLock {
                if finished { return true }
                self.continuation = continuation
                return false
            }
            if completed { continuation.resume(returning: result) }
        }

        func finish(_ value: Snapshot?) {
            let callback = lock.withLock {
                guard !finished else { return nil as CheckedContinuation<Snapshot?, Never>? }
                finished = true
                result = value
                let callback = continuation
                continuation = nil
                return callback
            }
            callback?.resume(returning: value)
        }
    }
}
#endif
