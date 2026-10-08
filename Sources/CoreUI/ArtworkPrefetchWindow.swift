#if canImport(UIKit)
import CoreModels
import Foundation

/// Owns only the current lookahead window, including completed work. Updating it
/// never awaits artwork and cancellation cannot cancel another visible consumer.
@MainActor
public final class ArtworkPrefetchWindow {
    public struct Request: Sendable {
        public let id: String
        public let prepare: @Sendable () async -> Void

        public init(id: String, prepare: @escaping @Sendable () async -> Void) {
            self.id = id
            self.prepare = prepare
        }
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    private let limiter: ConcurrencyLimiter

    public init(limiter: ConcurrencyLimiter = ArtworkSession.warmLimiter) {
        self.limiter = limiter
    }

    public func update(_ requests: [Request]) {
        let wanted = Set(requests.map(\.id))
        for id in Array(tasks.keys) where !wanted.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        for request in requests where tasks[request.id] == nil {
            let limiter = limiter
            tasks[request.id] = Task(priority: .background) {
                let _: Bool = await limiter.runUnlessCancelled {
                    guard !Task.isCancelled else { return }
                    await request.prepare()
                }
            }
        }
    }

    public func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }
}
#endif
