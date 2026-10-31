import Foundation

/// Request pacing for touch swipes only; the playhead and remote scan timer
/// continue advancing independently.
struct ScrubPreviewCadence {
    static let precisionInterval: TimeInterval = 1.0 / 30
    static let traversalInterval: TimeInterval = 0.25

    private(set) var interval = precisionInterval
    private var lastRequest: TimeInterval?
    private var direction = 0

    mutating func update(speed: Double, delta: Double) {
        let fraction = min(1, max(0, (abs(speed) - 500) / 2_000))
        interval = Self.precisionInterval + fraction * (Self.traversalInterval - Self.precisionInterval)
        if delta != 0 {
            let nextDirection = delta > 0 ? 1 : -1
            if direction != 0, nextDirection != direction { lastRequest = nil }
            direction = nextDirection
        }
    }

    func remainingDelay(at time: TimeInterval) -> TimeInterval {
        guard let lastRequest else { return 0 }
        return max(0, lastRequest + interval - time)
    }

    mutating func didRequest(at time: TimeInterval) {
        lastRequest = time
    }
}
