import Foundation

struct HDR10PlusProbeLimits: Sendable {
    var networkBytes = 8 * 1024 * 1024
    var packets = 128
    var packetBytes = 2 * 1024 * 1024
    var rangeBytes = 128 * 1024
    var requestTimeout: TimeInterval = 2
    var wallTimeout: TimeInterval = 5

    var isValid: Bool {
        networkBytes > 0 && packets > 0 && packetBytes > 0 && rangeBytes > 0
            && requestTimeout.isFinite && requestTimeout > 0
            && wallTimeout.isFinite && wallTimeout > 0 && wallTimeout <= 60
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

enum HDR10PlusProbeExecutor {
    private static let queue = DispatchQueue(label: "com.thatcube.Plozz.hdr10plus-probe", qos: .utility)

    static func run(
        limits: HDR10PlusProbeLimits = HDR10PlusProbeLimits(),
        queue: DispatchQueue = queue,
        operation: @escaping @Sendable (HDR10PlusProbeBudget) -> Bool?
    ) async -> Bool? {
        guard limits.isValid else { return nil }
        let budget = HDR10PlusProbeBudget(limits: limits)
        let completion = Completion(budget: budget)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.attach(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limits.wallTimeout) {
                    completion.finish(nil)
                }
                queue.async {
                    guard budget.isActive else {
                        completion.finish(nil)
                        return
                    }
                    let result = operation(budget)
                    completion.finish(budget.isActive && result == true ? true : nil)
                }
            }
        } onCancel: {
            completion.finish(nil)
        }
    }

    private final class Completion: @unchecked Sendable {
        let budget: HDR10PlusProbeBudget
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool?, Never>?
        private var finished = false
        private var result: Bool?

        init(budget: HDR10PlusProbeBudget) { self.budget = budget }

        func attach(_ continuation: CheckedContinuation<Bool?, Never>) {
            let alreadyFinished = lock.withLock {
                if !finished { self.continuation = continuation }
                return finished
            }
            if alreadyFinished { continuation.resume(returning: result) }
        }

        func finish(_ result: Bool?) {
            let continuation = lock.withLock { () -> CheckedContinuation<Bool?, Never>? in
                guard !finished else { return nil }
                finished = true
                self.result = result == true ? true : nil
                let value = self.continuation
                self.continuation = nil
                return value
            }
            budget.cancel()
            continuation?.resume(returning: result == true ? true : nil)
        }
    }
}
