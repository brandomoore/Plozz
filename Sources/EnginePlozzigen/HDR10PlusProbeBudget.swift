import Foundation
import AetherEngine

struct HDR10PlusProbeLimits: Sendable {
    var networkBytes = 8 * 1024 * 1024
    var packets = 128
    /// Inspection threshold after demuxing, not a native allocation ceiling.
    var packetBytes = 2 * 1024 * 1024
    var rangeBytes = 128 * 1024
    var requestTimeout: TimeInterval = 2
    var wallTimeout: TimeInterval = 5

    var isValid: Bool {
        networkBytes > 0 && packets > 0 && packetBytes > 0 && rangeBytes > 0
            && requestTimeout.isFinite && requestTimeout > 0
            && wallTimeout.isFinite && wallTimeout > 0 && wallTimeout <= 60
    }

    /// Engine-delivered input includes rereads, not transport prefetch or wire
    /// traffic. The HTTP range source independently reserves its request budget.
    func engineLimits(remainingTime: TimeInterval) -> ProbeLimits {
        ProbeLimits(
            maxInputBytes: Int64(networkBytes),
            maxPackets: packets,
            maxPacketBytes: packetBytes,
            timeBudget: remainingTime
        )
    }
}

final class HDR10PlusProbeBudget: @unchecked Sendable {
    let limits: HDR10PlusProbeLimits
    private let now: @Sendable () -> TimeInterval
    private let deadline: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var reservedBytes = 0
    private var cancellation: (@Sendable () -> Void)?

    init(
        limits: HDR10PlusProbeLimits,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.limits = limits
        self.now = now
        deadline = now() + limits.wallTimeout
    }

    var remainingTime: TimeInterval {
        lock.withLock { cancelled ? 0 : max(0, deadline - now()) }
    }

    var isActive: Bool { remainingTime > 0 }

    /// Reserve the entire requested range, including failed/short requests.
    /// Retries, seeks and redirects cannot reset the cumulative transfer budget.
    func reserve(upTo count: Int) -> Int {
        lock.withLock {
            guard !cancelled, now() < deadline else { return 0 }
            let allowed = min(max(0, count), max(0, limits.networkBytes - reservedBytes))
            reservedBytes += allowed
            return allowed
        }
    }

    func onCancellation(_ action: @escaping @Sendable () -> Void) {
        let callNow = lock.withLock {
            cancellation = action
            return cancelled
        }
        if callNow { action() }
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !cancelled else { return nil }
            cancelled = true
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}
