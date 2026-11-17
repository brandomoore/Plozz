import Foundation
import CoreNetworking

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
            value = current
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
