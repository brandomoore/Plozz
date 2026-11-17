import Foundation
import CoreNetworking
import Observation

/// A held adjustment previews locally when the engine cannot apply it without seeking.
public struct PlayerAudioSyncAdjustment {
    public static let range: ClosedRange<TimeInterval> = -2...2
    public static let step: TimeInterval = 0.01
    public private(set) var value: TimeInterval?
    private var repeats = 0

    public init() {}

    public mutating func set(_ seconds: TimeInterval) {
        guard seconds.isFinite else {
            PlozzLog.playback.error("Ignoring non-finite audio sync adjustment.")
            return
        }
        value = min(Self.range.upperBound, max(Self.range.lowerBound, (seconds * 100).rounded() / 100))
    }

    @discardableResult
    public mutating func nudge(from current: TimeInterval, forward: Bool, repeating: Bool) -> TimeInterval {
        if !repeating {
            value = value ?? current
            repeats = 0
        } else {
            repeats += 1
        }

        let step = repeats >= 12 ? 0.05 : Self.step
        set((value ?? current) + (forward ? step : -step))
        return value ?? current
    }

    public mutating func finish(cancelled: Bool = false) -> TimeInterval? {
        defer {
            value = nil
            repeats = 0
        }
        return cancelled ? nil : value
    }
}

/// Keeps feedback immediate while coalescing any seek/reload until input settles.
@MainActor @Observable
public final class PlayerAudioSyncEditor {
    private var adjustment = PlayerAudioSyncAdjustment()
    private var editing = false
    private var needsCommit = false
    @ObservationIgnored private(set) var commitTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public var value: TimeInterval? { adjustment.value }

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    deinit { commitTask?.cancel() }

    public func beginEditing() {
        editing = true
        cancelScheduledCommit()
    }

    public func nudge(from current: TimeInterval, forward: Bool, repeating: Bool,
                      applyLive: (TimeInterval) -> Bool, commit: @escaping (TimeInterval) -> Void) {
        beginEditing()
        let next = adjustment.nudge(from: current, forward: forward, repeating: repeating)
        change(to: next, current: current, applyLive: applyLive, commit: commit)
    }

    public func change(to seconds: TimeInterval, current: TimeInterval,
                       applyLive: (TimeInterval) -> Bool, commit: @escaping (TimeInterval) -> Void) {
        guard seconds.isFinite else {
            PlozzLog.playback.error("Ignoring non-finite audio sync adjustment.")
            return
        }
        cancelScheduledCommit()
        adjustment.set(seconds)
        guard let value else { return }
        needsCommit = value != current && !applyLive(value)
        if !editing { settle(commit: commit) }
    }

    public func endEditing(cancelled: Bool = false, commit: @escaping (TimeInterval) -> Void) {
        editing = false
        if cancelled { cancel() }
        else { settle(commit: commit) }
    }

    public func cancel() {
        cancelScheduledCommit()
        editing = false
        needsCommit = false
        _ = adjustment.finish(cancelled: true)
    }

    private func settle(commit: @escaping (TimeInterval) -> Void) {
        cancelScheduledCommit()
        guard needsCommit else {
            _ = adjustment.finish()
            return
        }
        let sleep = sleep
        commitTask = Task { [weak self] in
            do { try await sleep(.milliseconds(600)) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                PlozzLog.playback.error("Audio sync adjustment wait failed.")
                self?.cancel()
                return
            }
            guard !Task.isCancelled, let self, !self.editing else { return }
            self.commitTask = nil
            self.needsCommit = false
            if let value = self.adjustment.finish() { commit(value) }
        }
    }

    private func cancelScheduledCommit() {
        commitTask?.cancel()
        commitTask = nil
    }
}
