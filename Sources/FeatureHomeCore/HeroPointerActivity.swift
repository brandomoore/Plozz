import Foundation
import Observation

/// Holds carousel progress during pointer movement without controlling the player.
@MainActor
@Observable
public final class HeroPointerActivity {
    public static let idleDelay: TimeInterval = 1.5

    public private(set) var frozenGauge: HeroGaugeState?
    public private(set) var pauseID: UUID?
    // Mouse events extend the deadline without invalidating the hero on every pixel.
    @ObservationIgnored public private(set) var resumeDeadline: Date?
    @ObservationIgnored private var pauseStarted: Date?
    @ObservationIgnored private var deferredAdvance = false

    public var isPaused: Bool { frozenGauge != nil }

    public struct Resumption {
        public let pausedDuration: TimeInterval
        public let advanceAfterTrailer: Bool
    }

    public init() {}

    public func recordMovement(at now: Date, gauge: @autoclosure () -> HeroGaugeState) {
        resumeDeadline = now.addingTimeInterval(Self.idleDelay)
        guard !isPaused else { return }
        pauseID = UUID()
        pauseStarted = now
        frozenGauge = HeroGaugeState(fraction: gauge().fraction, remaining: nil)
    }

    public func resumeIfIdle(at now: Date) -> Resumption? {
        guard let resumeDeadline, now >= resumeDeadline else { return nil }
        return resume(at: now)
    }

    public func resume(at now: Date) -> Resumption? {
        guard let pauseStarted else { return nil }
        let result = Resumption(
            pausedDuration: max(0, now.timeIntervalSince(pauseStarted)),
            advanceAfterTrailer: deferredAdvance
        )
        reset()
        return result
    }

    public func deferAdvanceIfPaused() -> Bool {
        guard isPaused else { return false }
        deferredAdvance = true
        return true
    }

    public func resetSlide(at now: Date) {
        deferredAdvance = false
        if isPaused {
            pauseStarted = now
            frozenGauge = HeroGaugeState(fraction: 0, remaining: nil)
        }
    }

    public func reset() {
        frozenGauge = nil
        pauseID = nil
        resumeDeadline = nil
        pauseStarted = nil
        deferredAdvance = false
    }
}
