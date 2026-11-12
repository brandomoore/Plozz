import Foundation

/// One Home/profile generation. Never persist or share this across Home owners.
public final class HomeRecommendationScope: Sendable {
    @TaskLocal public static var current: HomeRecommendationScope?
    @TaskLocal public static var refreshRequested = false
    public let id = UUID()
    private let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var revision = UUID()
        var active = true
    }

    public init() {}

    public var revision: UUID { state.lock.withLock { state.revision } }
    public var isActive: Bool { state.lock.withLock { state.active } }

    /// Also fences in-flight reads when history or library access changes.
    public func refresh() { state.lock.withLock { state.revision = UUID() } }

    public func invalidate() {
        state.lock.withLock {
            state.active = false
            state.revision = UUID()
        }
    }
}
