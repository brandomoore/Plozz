import Foundation

enum RemoteSeekScan {
    static let holdDuration: TimeInterval = 0.4
    static let rates: [TimeInterval] = [8, 24, 48, 96, 192, 384, 768, 1536]

    static func nextLevel(_ level: Int, forward: Bool) -> Int {
        let direction = forward ? 1 : -1
        let next = min(rates.count, max(-rates.count, level + direction))
        return next == 0 ? direction : next
    }

    static func rate(at level: Int) -> TimeInterval {
        guard level != 0 else { return 0 }
        let bounded = min(rates.count, max(-rates.count, level))
        return rates[abs(bounded) - 1] * (bounded > 0 ? 1 : -1)
    }

    static func position(from seconds: TimeInterval, level: Int, elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(duration, max(0, seconds + rate(at: level) * elapsed))
    }
}
