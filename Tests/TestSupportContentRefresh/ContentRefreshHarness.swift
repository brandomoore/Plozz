import Foundation
import FeatureHomeCore

/// Deterministic driver for `ContentRefreshCoordinator` tests. The fake clock is
/// intentionally explicit so a test never depends on wall-clock timing.
@MainActor
public final class ContentRefreshHarness {
    public let coordinator: ContentRefreshCoordinator
    private let clock: TestClock

    public init(profile: ContentRefreshProfile = .tvOS) {
        let clock = TestClock()
        self.clock = clock
        self.coordinator = ContentRefreshCoordinator(profile: profile, now: { clock.now })
    }

    public var now: Date { clock.now }

    public func advance(by interval: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(interval)
    }

    public func show(_ surface: ContentRefreshSurfaceID) {
        coordinator.register(surface)
        coordinator.surfaceDidBecomeVisible(surface)
    }

    public func hide(_ surface: ContentRefreshSurfaceID) {
        coordinator.surfaceDidDisappear(surface)
        coordinator.unregister(surface)
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}
