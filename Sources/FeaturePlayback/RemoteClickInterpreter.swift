import CoreGraphics
import Foundation

/// Keeps a physical touchpad click distinct from the finger movement around it.
struct RemoteClickInterpreter {
    enum Action: Equatable {
        case select, skipBackward, skipForward
    }

    struct Position {
        let x: Float
        let y: Float
    }

    var edgeThreshold: Float = 0.7
    private(set) var suppressesPan = false
    private(set) var pendingAction: Action = .select

    init(edgeThreshold: Float = 0.7) {
        self.edgeThreshold = edgeThreshold
    }

    /// Correlates native presses with the independently updated controller
    /// snapshot. Old idle-remote positions must not affect keyboard/iPhone input.
    static func matchesInput(
        pressUptime: Double, inputUnixTime: Double, nowUptime: Double, nowUnixTime: Double
    ) -> Bool {
        guard pressUptime.isFinite, inputUnixTime.isFinite, nowUptime.isFinite, nowUnixTime.isFinite,
              pressUptime > 0, inputUnixTime > 0 else { return false }
        // UIPress timestamps are uptime; GCPhysicalInputProfile uses Unix time.
        let pressUnixTime = nowUnixTime - (nowUptime - pressUptime)
        return abs(pressUnixTime - inputUnixTime) <= 0.25
    }

    mutating func touchBegan() {
        suppressesPan = false
    }

    mutating func selectBegan(position: Position?) {
        // A click's lift can produce a sizeable UIKit pan. Ignore the remainder
        // of this contact, not a timed window that would swallow the next swipe.
        suppressesPan = true
        pendingAction = .select
        guard let position, position.x.isFinite, position.y.isFinite,
              abs(position.x) >= edgeThreshold, abs(position.x) > abs(position.y) else { return }
        pendingAction = position.x < 0 ? .skipBackward : .skipForward
    }

    mutating func takeAction() -> Action {
        defer { pendingAction = .select }
        return pendingAction
    }
}

struct RemoteTapInterpreter {
    private var origin: CGPoint?
    private var beganAt: TimeInterval = 0

    mutating func began(at point: CGPoint, timestamp: TimeInterval) {
        origin = point
        beganAt = timestamp
        moved(to: point)
    }

    mutating func moved(to point: CGPoint) {
        guard let origin else { return }
        if !point.x.isFinite || !point.y.isFinite
            || !origin.x.isFinite || !origin.y.isFinite
            || hypot(point.x - origin.x, point.y - origin.y) >= 10 {
            cancel()
        }
    }

    mutating func cancel() {
        origin = nil
    }

    mutating func ended(at point: CGPoint, timestamp: TimeInterval) -> Bool {
        moved(to: point)
        defer { cancel() }
        let elapsed = timestamp - beganAt
        return origin != nil && elapsed.isFinite && elapsed >= 0 && elapsed <= 0.35
    }
}
