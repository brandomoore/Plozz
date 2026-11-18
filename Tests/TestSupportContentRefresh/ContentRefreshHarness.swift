import Foundation
import FeatureHomeCore

/// Deterministic driver for `ContentRefreshCoordinator` tests. The fake clock is
/// intentionally explicit so a test never depends on wall-clock timing.
@MainActor
public final class ContentRefreshHarness {
    public let coordinator: ContentRefreshCoordinator
    private let clock: TestClock
    private var registrations: [ContentRefreshSurfaceID: ContentRefreshRegistration] = [:]

    public init(profile: ContentRefreshProfile = .tvOS) {
        let clock = TestClock()
        self.clock = clock
        self.coordinator = ContentRefreshCoordinator(profile: profile, now: { clock.now })
    }

    public var now: ContinuousClock.Instant { clock.now }

    public func advance(by interval: TimeInterval) {
        clock.now = clock.now.advanced(by: .seconds(interval))
    }

    public func show(_ surface: ContentRefreshSurfaceID) {
        let registration = registration(for: surface)
        coordinator.surfaceDidBecomeVisible(registration)
    }

    public func hide(_ surface: ContentRefreshSurfaceID) {
        coordinator.surfaceDidDisappear(registration(for: surface))
    }

    public func registration(for surface: ContentRefreshSurfaceID) -> ContentRefreshRegistration {
        if let registration = registrations[surface] { return registration }
        let registration = ContentRefreshRegistration(surface: surface)
        registrations[surface] = registration
        return registration
    }
}

@MainActor
private final class TestClock {
    var now = ContinuousClock.now
}
