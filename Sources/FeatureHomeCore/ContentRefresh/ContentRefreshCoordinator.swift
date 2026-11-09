import Foundation
import Observation

/// Owns the cross-platform decision of when the visible content surface should
/// ask its provider for fresh data again.
///
/// Views only register a surface and perform the typed action they receive.
/// Timing, foreground/background handling, and platform differences stay here
/// so both app shells cannot drift into separate refresh bugs.
@MainActor
@Observable
public final class ContentRefreshCoordinator {
    public private(set) var request: ContentRefreshRequest?
    /// Increments when the active profile resets the coordinator. Surfaces
    /// observe it so a page that stays mounted across a profile switch registers
    /// again instead of silently dropping out of the coordinator's visible order.
    public private(set) var resetRevision: UInt64 = 0

    private let profile: ContentRefreshProfile
    private let now: @MainActor @Sendable () -> Date

    @ObservationIgnored private var surfaces: [ContentRefreshSurfaceID: ContentRefreshSurfaceKind] = [:]
    @ObservationIgnored private var visibleOrder: [ContentRefreshSurfaceID] = []
    @ObservationIgnored private var lastVisibleAt: [ContentRefreshSurfaceID: Date] = [:]
    @ObservationIgnored private var hasBeenVisible: Set<ContentRefreshSurfaceID> = []
    @ObservationIgnored private var applicationIsActive = true
    @ObservationIgnored private var leftActiveAt: Date?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(
        profile: ContentRefreshProfile,
        now: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        self.profile = profile
        self.now = now
    }

    // MARK: - Surface registration

    public func register(_ surface: ContentRefreshSurfaceID) {
        surfaces[surface] = surface.kind
    }

    public func unregister(_ surface: ContentRefreshSurfaceID) {
        guard surfaces.removeValue(forKey: surface) != nil else { return }
        visibleOrder.removeAll { $0 == surface }
        lastVisibleAt[surface] = now()
    }

    public func surfaceDidBecomeVisible(_ surface: ContentRefreshSurfaceID) {
        guard surfaces[surface] != nil else { return }
        visibleOrder.removeAll { $0 == surface }
        visibleOrder.append(surface)
        guard !hasBeenVisible.insert(surface).inserted else {
            lastVisibleAt[surface] = now()
            return
        }
        let away = lastVisibleAt[surface].map { now().timeIntervalSince($0) } ?? 0
        maybeEmit(
            for: surface,
            actionThreshold: profile.rule(for: surface.kind).surfaceReturnAfter,
            awayFor: away,
            reason: .surfaceReturn(after: away)
        )
    }

    public func surfaceDidDisappear(_ surface: ContentRefreshSurfaceID) {
        visibleOrder.removeAll { $0 == surface }
        lastVisibleAt[surface] = now()
    }

    /// Drops every registered surface and timing. Used when the active profile
    /// changes so one profile's visible page cannot receive another's refresh.
    public func reset() {
        surfaces.removeAll()
        visibleOrder.removeAll()
        lastVisibleAt.removeAll()
        hasBeenVisible.removeAll()
        leftActiveAt = nil
        request = nil
        applicationIsActive = true
        resetRevision &+= 1
    }

    // MARK: - Application lifecycle

    public func applicationWillResignActive() {
        applicationIsActive = false
        leftActiveAt = now()
    }

    public func applicationDidBecomeActive() {
        applicationIsActive = true
        let away = leftActiveAt.map { now().timeIntervalSince($0) } ?? 0
        leftActiveAt = nil
        guard let surface = visibleOrder.last else { return }
        maybeEmit(
            for: surface,
            actionThreshold: profile.rule(for: surface.kind).foregroundAfter,
            awayFor: away,
            reason: .foreground(awayFor: away)
        )
    }

    public func requestManualRefresh() {
        guard let surface = visibleOrder.last else { return }
        emit(for: surface, reason: .manual)
    }

    // MARK: - Emission

    private func maybeEmit(
        for surface: ContentRefreshSurfaceID,
        actionThreshold: TimeInterval,
        awayFor: TimeInterval,
        reason: ContentRefreshReason
    ) {
        guard applicationIsActive, awayFor >= actionThreshold else { return }
        emit(for: surface, reason: reason)
    }

    private func emit(for surface: ContentRefreshSurfaceID, reason: ContentRefreshReason) {
        guard let kind = surfaces[surface] else { return }
        let action = profile.rule(for: kind).action
        guard action != .none else { return }
        generation &+= 1
        request = ContentRefreshRequest(
            surface: surface,
            action: action,
            reason: reason,
            generation: generation
        )
    }
}
