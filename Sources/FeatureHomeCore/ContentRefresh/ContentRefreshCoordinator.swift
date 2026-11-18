import Foundation
import Observation

/// Owned by a mounted page, including while its navigation stack retains it.
/// Two pages for the same title must not consume each other's refresh requests.
@MainActor
public final class ContentRefreshRegistration {
    public let id = UUID()
    public let surface: ContentRefreshSurfaceID
    fileprivate var revision: UInt64?
    fileprivate var hasAppeared = false
    fileprivate var hiddenAt: ContinuousClock.Instant?

    public init(surface: ContentRefreshSurfaceID) {
        self.surface = surface
    }
}

@MainActor
@Observable
public final class ContentRefreshCoordinator {
    public private(set) var request: ContentRefreshRequest?
    public private(set) var resetRevision: UInt64 = 0

    private let profile: ContentRefreshProfile
    private let now: @MainActor @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var visible: [ContentRefreshRegistration] = []
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var leftActiveAt: ContinuousClock.Instant?
    @ObservationIgnored private var pendingForegroundAbsence: TimeInterval?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(
        profile: ContentRefreshProfile,
        now: @escaping @MainActor @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.profile = profile
        self.now = now
    }

    public func surfaceDidBecomeVisible(_ registration: ContentRefreshRegistration) {
        guard !visible.contains(where: { $0.id == registration.id }) else { return }
        if registration.revision != resetRevision {
            registration.revision = resetRevision
            registration.hasAppeared = false
            registration.hiddenAt = nil
        }
        if let covered = visible.last, covered.hiddenAt == nil {
            covered.hiddenAt = now()
        }
        request = nil
        visible.append(registration)
        if registration.hasAppeared {
            refreshReturningSurface(registration)
        } else {
            registration.hasAppeared = true
            pendingForegroundAbsence = nil
        }
    }

    public func surfaceDidDisappear(_ registration: ContentRefreshRegistration) {
        guard visible.contains(where: { $0.id == registration.id }) else { return }
        let wasTop = visible.last?.id == registration.id
        visible.removeAll { $0.id == registration.id }
        if registration.hiddenAt == nil { registration.hiddenAt = now() }
        if request?.registrationID == registration.id { request = nil }
        if wasTop, let revealed = visible.last { refreshReturningSurface(revealed) }
    }

    /// Invalidates requests without pretending a backgrounded app became active.
    public func reset() {
        visible.removeAll()
        pendingForegroundAbsence = nil
        request = nil
        resetRevision &+= 1
    }

    public func applicationWillResignActive() {
        guard applicationIsActive else { return }
        applicationIsActive = false
        leftActiveAt = now()
        pendingForegroundAbsence = nil
        request = nil
    }

    public func applicationDidBecomeActive() {
        guard !applicationIsActive else { return }
        applicationIsActive = true
        pendingForegroundAbsence = leftActiveAt.map(elapsed)
        leftActiveAt = nil
        if let top = visible.last { refreshReturningSurface(top) }
    }

    public func requestManualRefresh() {
        guard applicationIsActive, let top = visible.last else { return }
        emit(for: top, reason: .manual)
    }

    public func isCurrent(_ request: ContentRefreshRequest) -> Bool {
        applicationIsActive && self.request == request
            && visible.last?.id == request.registrationID
    }

    private func refreshReturningSurface(_ registration: ContentRefreshRegistration) {
        guard applicationIsActive, visible.last?.id == registration.id else { return }
        let rule = profile.rule(for: registration.surface.kind)
        let hiddenFor = registration.hiddenAt.map(elapsed)
        registration.hiddenAt = nil
        let foregroundAbsence = pendingForegroundAbsence
        pendingForegroundAbsence = nil
        if let away = foregroundAbsence, away >= rule.foregroundAfter {
            emit(for: registration, reason: .foreground(awayFor: away))
        } else if let away = hiddenFor, away >= rule.surfaceReturnAfter {
            emit(for: registration, reason: .surfaceReturn(after: away))
        }
    }

    private func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: now()).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func emit(for registration: ContentRefreshRegistration, reason: ContentRefreshReason) {
        generation &+= 1
        request = ContentRefreshRequest(
            surface: registration.surface,
            registrationID: registration.id,
            action: profile.rule(for: registration.surface.kind).action,
            reason: reason,
            generation: generation
        )
    }
}
