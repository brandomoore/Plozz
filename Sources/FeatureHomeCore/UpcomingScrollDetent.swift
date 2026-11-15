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
    static let releaseDistance: CGFloat = 240
    static let heldDistance: CGFloat = 24
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
        return .tension(intensity: 0.15 + 0.8 * Double(step) / 8)
    }

    func offset(translation: CGFloat) -> CGFloat {
        let proposed = start - (translation - self.translation)
        // Once the seal breaks, keep a fixed displacement for the rest of the
        // gesture so reversing direction cannot jump or reattach the content.
        if hasReleased { return proposed + Self.releaseDistance - Self.heldDistance }
        guard start >= today - 2, proposed < today else { return proposed }
        let pull = today - proposed
        let t = min(pull / Self.releaseDistance, 1)
        return today - Self.heldDistance * (2 * t - t * t)
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
    var reduceMotion = false
    var onFeedback: (TouchFeedback.Event) -> Void = { TouchFeedback.shared.emit($0) }

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
        }
        updateAnchor()
    }

    func detach() {
        cancelInteraction()
        offsetObservation?.invalidate()
        offsetObservation = nil
        scrollView = nil
        todayOffset = nil
        phase = .idle
    }

    func cancelInteraction() {
        targetState.cancel()
        drag = nil
        hasResisted = false
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
        phase = newPhase
        if newPhase == .tracking {
            cancelInteraction()
            beginInteraction()
        } else if newPhase == .interacting, drag == nil {
            beginInteraction()
        } else if newPhase == .idle {
            completeCatch()
            cancelInteraction()
        }
    }

    private func beginInteraction() {
        updateAnchor()
        guard !usesAssistiveScrolling, let scrollView, let todayOffset else { return }
        hasResisted = false
        drag = UpcomingScrollDetentDrag(
            start: scrollView.contentOffset.y,
            translation: scrollView.panGestureRecognizer.translation(in: scrollView.window).y,
            today: todayOffset
        )
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
                let y = drag.offset(translation: translation)
                let minimum = -scrollView.adjustedContentInset.top
                let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
                // Once the gesture reaches an outer edge, leave its rubber-band
                // behavior to UIKit instead of clamping the scroll position.
                if y <= minimum || y >= maximum {
                    self.drag = nil
                    targetState.cancel()
                } else {
                    if abs(y - scrollView.contentOffset.y) > 0.01 {
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
        guard phase != .tracking, phase != .interacting, !usesAssistiveScrolling else { return }
        updateTargetState()
        guard targetState.consumeArrival() else { return }
        onFeedback(.selection)
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
