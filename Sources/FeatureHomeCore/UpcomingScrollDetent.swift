#if os(iOS)
import SwiftUI
import UIKit
import CoreUI
import os

extension UpcomingView {
    /// A navigation reselection resets only the visible Upcoming agenda.
    @MainActor
    public static func scrollToToday(in scrollView: UIScrollView) -> Bool {
        func findProbe(in view: UIView) -> UpcomingScrollProbe.Probe? {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if let probe = view as? UpcomingScrollProbe.Probe,
               probe.role == .container, probe.detent?.scrollView === scrollView {
                return probe
            }
            return view.subviews.lazy.compactMap { findProbe(in: $0) }.first
        }
        guard let probe = findProbe(in: scrollView), let action = probe.onScrollToToday else { return false }
        action()
        probe.detent?.scrollToToday()
        return true
    }
}

private struct UpcomingScrollDetentKey: EnvironmentKey {
    static let defaultValue: UpcomingScrollDetent? = nil
}

extension EnvironmentValues {
    var upcomingScrollDetent: UpcomingScrollDetent? {
        get { self[UpcomingScrollDetentKey.self] }
        set { self[UpcomingScrollDetentKey.self] = newValue }
    }
}

struct UpcomingTodayAnchor: View {
    @Environment(\.upcomingScrollDetent) private var detent

    var body: some View {
        if let detent { UpcomingScrollProbe(detent: detent, role: .today) }
    }
}

struct UpcomingScrollDetentDrag: Sendable {
    static let releaseDistance: CGFloat = 360
    static var heldDistance: CGFloat { stretch(releaseDistance) }
    static let snapDistance: CGFloat = 48
    static let maximumSnapVelocity: CGFloat = 1_200
    let start: CGFloat
    let translation: CGFloat
    let today: CGFloat
    private(set) var hasReleased = false
    private var feedbackStep = 0

    init(start: CGFloat, translation: CGFloat, today: CGFloat) {
        self.start = start
        self.translation = translation
        self.today = today
    }

    mutating func advance(translation: CGFloat) -> TouchFeedback.Event? {
        guard start >= today - 2, !hasReleased else { return nil }
        let pull = today - (start - (translation - self.translation))
        if pull <= 0 {
            feedbackStep = 0
            return nil
        }
        if pull >= Self.releaseDistance {
            hasReleased = true
            return .pop
        }
        let step = Int(pull / Self.releaseDistance * 8)
        guard step > feedbackStep else { return nil }
        feedbackStep = step
        return .tension(intensity: 0.35 + 0.65 * Double(step) / 8)
    }

    func offset(translation: CGFloat) -> CGFloat {
        let proposed = start - (translation - self.translation)
        // Once the seal breaks, keep a fixed displacement for the rest of the
        // gesture so reversing direction cannot jump or reattach the content.
        if hasReleased { return proposed + Self.releaseDistance - Self.heldDistance }
        guard start >= today - 2, proposed < today else { return proposed }
        return today - Self.stretch(today - proposed)
    }

    private static func stretch(_ pull: CGFloat) -> CGFloat {
        let dimension: CGFloat = 120
        return dimension * 0.55 * pull / (dimension + 0.55 * pull)
    }

    static func pull(forStretch distance: CGFloat) -> CGFloat {
        let distance = min(heldDistance, max(0, distance))
        // Regrabbing a pixel-rounded return must not pop the hold by itself.
        return min(releaseDistance - 1, 120 * distance / (0.55 * (120 - distance)))
    }

    func shouldSnap(offset: CGFloat, translation: CGFloat, velocity: CGFloat) -> Bool {
        guard !hasReleased else { return false }
        let raw = start - (translation - self.translation)
        if start >= today - 2, raw < today {
            return true
        }
        return abs(offset - today) <= Self.snapDistance && abs(velocity) < Self.maximumSnapVelocity
    }
}

struct UpcomingScrollTargetBehavior: ScrollTargetBehavior {
    let state: UpcomingScrollTargetState

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Native release velocity is points/ms; the detent policy uses points/s.
        guard context.axes.contains(.vertical),
              let y = state.target(projected: target.rect.minY, velocity: context.velocity.dy * 1_000) else { return }
        target.rect.origin.y = y
    }
}

// ScrollTargetBehavior is nonisolated. Exchange value snapshots with the UIKit
// adapter, without reading views or hopping asynchronously during target selection.
final class UpcomingScrollTargetState: Sendable {
    private struct State {
        var today: CGFloat?
        var inset: CGFloat = 0
        var offset: CGFloat = 0
        var translation: CGFloat = 0
        var drag: UpcomingScrollDetentDrag?
        var enabled = false
        var interacting = false
        var resolved = false
        var target: CGFloat?
        var feedbackPending = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func update(today: CGFloat?, inset: CGFloat, offset: CGFloat, translation: CGFloat,
                drag: UpcomingScrollDetentDrag?, enabled: Bool) {
        state.withLock {
            $0.today = today
            $0.inset = inset
            $0.offset = offset
            $0.translation = translation
            $0.drag = drag
            $0.enabled = enabled
        }
    }

    func begin() {
        state.withLock {
            $0.interacting = true
            $0.resolved = false
            $0.target = nil
            $0.feedbackPending = false
        }
    }

    func cancel() {
        state.withLock {
            $0.interacting = false
            $0.target = nil
            $0.feedbackPending = false
        }
    }

    func target(projected: CGFloat, velocity: CGFloat) -> CGFloat? {
        state.withLock {
            guard $0.enabled, $0.interacting, $0.drag?.hasReleased != true,
                  let today = $0.today else { return nil }
            if $0.resolved { return $0.target }
            $0.resolved = true
            let nearbyRelease = $0.drag?.shouldSnap(
                offset: $0.offset, translation: $0.translation, velocity: velocity
            ) ?? (abs($0.offset - today) <= UpcomingScrollDetentDrag.snapDistance
                && abs(velocity) < UpcomingScrollDetentDrag.maximumSnapVelocity)
            let nearbyDestination = abs(projected - today - $0.inset) <= UpcomingScrollDetentDrag.snapDistance
                && abs(velocity) < UpcomingScrollDetentDrag.maximumSnapVelocity
            let crossesUnreleasedToday = $0.drag.map { $0.start >= today - 2 } == true
                && projected - $0.inset < today
            guard crossesUnreleasedToday || nearbyRelease || nearbyDestination else { return nil }
            $0.target = today + $0.inset
            $0.feedbackPending = abs($0.offset - today) > 0.5
            return $0.target
        }
    }

    func consumeArrival() -> Bool {
        state.withLock {
            guard $0.enabled, $0.feedbackPending, $0.drag?.hasReleased != true, let target = $0.target,
                  abs($0.offset + $0.inset - target) <= 1 else { return false }
            $0.feedbackPending = false
            return true
        }
    }

    func heldReturnOffset() -> CGFloat? {
        state.withLock {
            guard $0.enabled, $0.interacting, let today = $0.today,
                  let target = $0.target, let drag = $0.drag, !drag.hasReleased,
                  drag.start >= today - 2, $0.offset < today - 0.5 else { return nil }
            return target - $0.inset
        }
    }
}

@MainActor
final class UpcomingScrollDetent {
    let targetState = UpcomingScrollTargetState()
    private(set) weak var scrollView: UIScrollView?
    private weak var anchor: UIView?
    private(set) var todayOffset: CGFloat?
    private(set) var phase = ScrollPhase.idle
    private var offsetObservation: NSKeyValueObservation?
    private var drag: UpcomingScrollDetentDrag?
    private var adjustingOffset = false
    private var hasResisted = false
    private var releaseShift: CGFloat = 0
    private var motion: UpcomingScrollMotion?
    // Mutated on the main actor; deinit removes the token after the last owner releases it.
    private nonisolated(unsafe) var inactivityObserver: NSObjectProtocol?
    var reduceMotion = false
    var onFeedback: (TouchFeedback.Event) -> Void = { TouchFeedback.shared.emit($0) }

    deinit {
        if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) }
    }

    private var usesAssistiveScrolling: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    func attach(to scroll: UIScrollView) {
        if scrollView !== scroll {
            detach()
            scrollView = scroll
            offsetObservation = scroll.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.offsetChanged() }
            }
            inactivityObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelInteraction() }
            }
        }
        updateAnchor()
    }

    func detach() {
        cancelInteraction()
        offsetObservation?.invalidate()
        offsetObservation = nil
        if let inactivityObserver { NotificationCenter.default.removeObserver(inactivityObserver) }
        inactivityObserver = nil
        scrollView = nil
        todayOffset = nil
        phase = .idle
    }

    func cancelInteraction() {
        stopMotion(preservingPosition: false)
        targetState.cancel()
        drag = nil
        hasResisted = false
        releaseShift = 0
    }

    func scrollToToday() {
        cancelInteraction()
        updateAnchor()
        guard let scrollView, let todayOffset else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: todayOffset), animated: !reduceMotion
        )
    }

    func setAnchor(_ view: UIView) {
        anchor = view
        updateAnchor()
    }

    func removeAnchor(_ view: UIView) {
        if anchor === view {
            anchor = nil
            todayOffset = nil
            cancelInteraction()
        }
    }

    func updateAnchor() {
        guard let scrollView, let anchor, anchor.window != nil, anchor.bounds.width > 0,
              anchor.isDescendant(of: scrollView) else { return }
        let offset = anchor.convert(.zero, to: scrollView).y - scrollView.adjustedContentInset.top
        if let todayOffset, abs(offset - todayOffset) > 1 {
            cancelInteraction()
        }
        todayOffset = offset
        updateTargetState()
    }

    func phaseChanged(to newPhase: ScrollPhase) {
        let previousPhase = phase
        phase = newPhase
        if newPhase == .tracking {
            let holdingToday = motion?.returning == true
            stopMotion(preservingPosition: true)
            cancelInteraction()
            beginInteraction(holdingToday: holdingToday)
        } else if newPhase == .interacting, drag == nil || motion != nil {
            let holdingToday = motion?.returning == true
            stopMotion(preservingPosition: true)
            cancelInteraction()
            beginInteraction(holdingToday: holdingToday)
        }
        if previousPhase == .interacting, newPhase == .decelerating || newPhase == .idle,
           !reduceMotion, !usesAssistiveScrolling, let scrollView,
           let target = targetState.heldReturnOffset() {
            animateOffset(to: target, displacement: scrollView.contentOffset.y - target, returning: true)
        }
        if newPhase == .idle {
            completeCatch()
            if motion == nil { cancelInteraction() }
        }
    }

    private func beginInteraction(holdingToday: Bool = false) {
        updateAnchor()
        guard !usesAssistiveScrolling, let scrollView, let todayOffset else { return }
        hasResisted = false
        releaseShift = 0
        let pan = scrollView.panGestureRecognizer
        let translation = pan.translation(in: scrollView.window).y
        if holdingToday, scrollView.contentOffset.y < todayOffset {
            let pull = UpcomingScrollDetentDrag.pull(forStretch: todayOffset - scrollView.contentOffset.y)
            drag = UpcomingScrollDetentDrag(start: todayOffset, translation: translation - pull, today: todayOffset)
            _ = drag?.advance(translation: translation)
            hasResisted = true
        } else {
            // SwiftUI can deliver .interacting after UIKit's first movement.
            // Recover the touch-down origin instead of treating that movement as history.
            let movedBeforePhase = phase == .interacting && (pan.state == .began || pan.state == .changed)
            drag = UpcomingScrollDetentDrag(
                start: scrollView.contentOffset.y + (movedBeforePhase ? translation : 0),
                translation: movedBeforePhase ? 0 : translation, today: todayOffset
            )
        }
        updateTargetState()
        targetState.begin()
    }

    private func offsetChanged() {
        guard !adjustingOffset, let scrollView else { return }
        updateAnchor()
        if phase == .interacting, !usesAssistiveScrolling, var drag, drag.start >= drag.today - 2 {
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView.window).y
            let raw = drag.start - (translation - drag.translation)
            hasResisted = hasResisted || raw < drag.today
            if hasResisted {
                let feedback = drag.advance(translation: translation)
                self.drag = drag
                let releasing = feedback == .pop && !reduceMotion
                if releasing { releaseShift = 24 }
                let y = drag.offset(translation: translation) - releaseShift
                let minimum = -scrollView.adjustedContentInset.top
                let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
                // Once the gesture reaches an outer edge, leave its rubber-band
                // behavior to UIKit instead of clamping the scroll position.
                if y <= minimum || y >= maximum {
                    cancelInteraction()
                } else {
                    if releasing {
                        animateOffset(to: y, displacement: releaseShift, returning: false)
                    } else if abs(y - scrollView.contentOffset.y) > 0.01 {
                        adjustingOffset = true
                        scrollView.contentOffset.y = y
                        adjustingOffset = false
                    }
                    if let feedback { onFeedback(feedback) }
                }
            }
        }
        updateTargetState()
        completeCatch()
    }

    private func updateTargetState() {
        guard let scrollView else { return }
        targetState.update(
            today: todayOffset,
            inset: scrollView.adjustedContentInset.top,
            offset: scrollView.contentOffset.y,
            translation: scrollView.panGestureRecognizer.translation(in: scrollView.window).y,
            drag: drag, enabled: !usesAssistiveScrolling
        )
    }

    private func completeCatch() {
        guard motion == nil, phase != .tracking, phase != .interacting, !usesAssistiveScrolling else { return }
        updateTargetState()
        guard targetState.consumeArrival() else { return }
        onFeedback(.selection)
    }

    private func animateOffset(to offset: CGFloat, displacement: CGFloat, returning: Bool) {
        guard let scrollView else { return }
        stopMotion(preservingPosition: false)
        let completion = UpcomingScrollMotion(owner: self, returning: returning)
        motion = completion
        let spring = Spring(response: returning ? 0.4 : 0.3, dampingRatio: 0.78)
        let animation = CASpringAnimation(keyPath: "bounds.origin.y")
        animation.fromValue = displacement
        animation.toValue = 0
        animation.isAdditive = true
        animation.mass = spring.mass
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.duration = spring.settlingDuration
        animation.delegate = completion
        // Commit the real offset once, then let the compositor release the
        // equal-and-opposite displacement. No second per-frame scroll driver.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        adjustingOffset = true
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
        adjustingOffset = false
        scrollView.layer.add(animation, forKey: UpcomingScrollMotion.key)
        CATransaction.commit()
        updateTargetState()
    }

    private func stopMotion(preservingPosition: Bool) {
        guard motion != nil, let scrollView else { return }
        let visibleOffset = scrollView.layer.presentation()?.bounds.origin.y ?? scrollView.contentOffset.y
        motion = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.layer.removeAnimation(forKey: UpcomingScrollMotion.key)
        if preservingPosition {
            adjustingOffset = true
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: visibleOffset), animated: false
            )
            adjustingOffset = false
        }
        CATransaction.commit()
    }

    fileprivate func motionStopped(_ completed: UpcomingScrollMotion, finished: Bool) {
        guard motion === completed else { return }
        motion = nil
        if finished { completeCatch() }
        if phase == .idle || !finished { cancelInteraction() }
    }
}

fileprivate final class UpcomingScrollMotion: NSObject, CAAnimationDelegate {
    static let key = "plozz.upcoming.elasticity"
    let returning: Bool
    @MainActor private weak var owner: UpcomingScrollDetent?

    @MainActor
    init(owner: UpcomingScrollDetent, returning: Bool) {
        self.owner = owner
        self.returning = returning
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated { owner?.motionStopped(self, finished: flag) }
    }
}

struct UpcomingScrollProbe: UIViewRepresentable {
    enum Role { case container, today }
    let detent: UpcomingScrollDetent
    let role: Role
    var reduceMotion = false
    var onScrollToToday: (() -> Void)?

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.detent = detent
        view.role = role
        view.onScrollToToday = onScrollToToday
        if role == .container { detent.reduceMotion = reduceMotion }
        view.connect()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.onScrollToToday = nil
        view.disconnect()
    }

    final class Probe: UIView {
        weak var detent: UpcomingScrollDetent?
        var role = Role.container
        var onScrollToToday: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { disconnect() } else { connect() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
        }

        func connect() {
            guard window != nil, let detent else { return }
            if role == .today {
                detent.setAnchor(self)
            } else {
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        detent.attach(to: scroll)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        func disconnect() {
            if role == .today { detent?.removeAnchor(self) } else { detent?.detach() }
        }
    }
}
#endif
