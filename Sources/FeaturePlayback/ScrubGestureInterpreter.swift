#if canImport(AVFoundation)
import CoreGraphics
import Foundation

/// The gesture *state machine* around the scrub transfer function — extracted
/// from `PlayerInputViewController.handlePan` so its fragile semantics are
/// unit-tested rather than discovered on a TV.
///
/// It owns only the per-gesture interpretation: locking a pan to an axis past a
/// dead-zone, the "pause to seek" gate, low-pass-filtering the jittery recogniser
/// velocity that drives scrub acceleration, and distinguishing a deliberate
/// landing from a mid-traversal flick on lift. The point→seconds math stays in
/// ``ScrubGeometry``; the UIKit recogniser reading and the side effects
/// (begin/commit scrub, reveal controls, seek) stay in the view controller,
/// which just applies the outcomes this returns.
struct ScrubGestureInterpreter {
    enum Axis: Equatable { case undecided, horizontal, verticalIgnored }

    /// What the host controller should do for one `.changed` pan sample.
    enum PanOutcome: Equatable {
        /// Still deciding the axis (travel below the dead-zone, or a vertical lean
        /// short of `verticalNavigationDistance`), or a suppressed vertical drag —
        /// do nothing this sample.
        case ignore
        /// A deliberate downward swipe — reveal the Info card.
        case enterControlBar
        /// A deliberate upward swipe — use the same destination as an Up press.
        case moveUp
        /// Pause-to-seek gate: a horizontal swipe while playing with seek-without-
        /// pausing off — flash the transport for feedback and suppress the gesture.
        case flashAndSuppress
        /// Advance the scrub head by `deltaPoints` at `smoothedSpeed`. On the
        /// sample that first locks horizontal, exactly one of `beginScrub` /
        /// `continueTraversal` is true (a fresh session vs. resuming a flick-bridged
        /// one); both are false on every later sample. The first sample excludes
        /// only the dead-zone distance, not movement coalesced before delivery.
        case advance(deltaPoints: Double, smoothedSpeed: Double,
                     beginScrub: Bool, continueTraversal: Bool)
    }

    /// What the host controller should do when the gesture ends.
    enum EndOutcome: Equatable {
        case none
        /// A deliberate landing — commit the seek (and resume) immediately.
        case commit
        /// A fast flick — keep the scrub session alive and bridge to a possible
        /// follow-up swipe instead of seeking now.
        case bridgeCommit
    }

    /// Distance (points) a touch must travel before we lock to an axis.
    let axisDeadZone: Double
    /// Vertical travel (points) before a swipe leaves the scrub surface for the
    /// controls. Longer than the dead-zone so a horizontal swipe whose first
    /// delivered sample still leans vertical can lock horizontal on a later one.
    let verticalNavigationDistance: Double
    /// EMA weight at the 60 Hz reference cadence. Actual samples are weighted by
    /// elapsed time, so matching 24 Hz video does not slow the acceleration ramp.
    let speedSmoothing: Double
    /// Lift speed (points/sec) at or above which a scrub is treated as a
    /// mid-traversal flick (defer the commit) rather than a deliberate landing.
    let flickCommitThreshold: Double

    private(set) var axis: Axis = .undecided
    /// The pan `translation.x` from the previous scrub sample. Each sample scrubs
    /// by the increment since this value, seeded at the dead-zone boundary so
    /// delayed delivery cannot discard most or all of a short swipe.
    private var lastTranslationX: Double = 0
    /// Low-pass-filtered pan speed (points/sec). Reset to 0 only when a fresh
    /// scrub begins, so a flick-bridged continuation carries its momentum.
    private var smoothedSpeed: Double = 0

    init(axisDeadZone: Double = 18,
         verticalNavigationDistance: Double = 54,
         speedSmoothing: Double = 0.25,
         flickCommitThreshold: Double = 1000) {
        precondition((0...1).contains(speedSmoothing))
        self.axisDeadZone = axisDeadZone
        self.verticalNavigationDistance = verticalNavigationDistance
        self.speedSmoothing = speedSmoothing
        self.flickCommitThreshold = flickCommitThreshold
    }

    /// Resets the per-gesture axis lock at `.began`. Deliberately leaves
    /// `smoothedSpeed` intact so a multi-swipe traversal keeps its momentum.
    mutating func begin() {
        axis = .undecided
        lastTranslationX = 0
    }

    /// Interprets one `.changed` pan sample. `isScrubbing`/`seekWithoutPausing`/
    /// `isPaused` are the model flags read at the moment the axis is decided.
    mutating func changed(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        isScrubbing: Bool,
        seekWithoutPausing: Bool,
        isPaused: Bool,
        elapsed: TimeInterval = 1.0 / 60.0
    ) -> PanOutcome {
        precondition(elapsed.isFinite && elapsed >= 0)
        var beginScrub = false
        var continueTraversal = false

        if axis == .undecided {
            let absX = abs(translationX)
            let absY = abs(translationY)
            // Wait for a clear directional signal before committing to an axis.
            guard max(absX, absY) >= axisDeadZone else { return .ignore }
            if absX >= absY {
                axis = .horizontal
                if isScrubbing {
                    // Continuing a multi-swipe traversal — a previous flick left
                    // the session alive with a commit pending.
                    continueTraversal = true
                } else if !seekWithoutPausing, !isPaused {
                    // Pause-to-seek mode while playing: a horizontal swipe neither
                    // seeks nor pauses; flash the transport and suppress the rest.
                    axis = .verticalIgnored
                    return .flashAndSuppress
                } else {
                    beginScrub = true
                    smoothedSpeed = 0
                }
                lastTranslationX = translationX < 0 ? -axisDeadZone : axisDeadZone
            } else {
                // Leaving the surface needs more travel than a scrub. UIKit can deliver
                // a right swipe's first sample while it still leans downward; locking
                // there opened Info and the rest of the swipe moved focus to Cast.
                guard absY >= verticalNavigationDistance else { return .ignore }
                axis = .verticalIgnored
                return translationY > 0 ? .enterControlBar : .moveUp
            }
        }

        guard axis == .horizontal else { return .ignore }

        let dx = translationX - lastTranslationX
        lastTranslationX = translationX
        let rawSpeed = abs(velocityX)
        let weight = 1 - pow(1 - speedSmoothing, elapsed * 60)
        smoothedSpeed += (rawSpeed - smoothedSpeed) * weight
        return .advance(deltaPoints: dx, smoothedSpeed: smoothedSpeed,
                        beginScrub: beginScrub, continueTraversal: continueTraversal)
    }

    /// Interprets the gesture ending. `gestureEnded` is true for `.ended` (a real
    /// lift) and false for `.cancelled`/`.failed`. Always clears the axis lock.
    mutating func ended(gestureEnded: Bool, velocityX: Double, isScrubbing: Bool) -> EndOutcome {
        defer { axis = .undecided }
        guard axis == .horizontal, isScrubbing else { return .none }
        let liftSpeed = abs(velocityX)
        if gestureEnded, liftSpeed >= flickCommitThreshold {
            return .bridgeCommit
        }
        return .commit
    }
}
#endif
