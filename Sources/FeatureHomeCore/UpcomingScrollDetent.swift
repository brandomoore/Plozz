#if os(iOS)
import SwiftUI
import UIKit

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

struct UpcomingScrollDetentDrag {
    static let releaseDistance: CGFloat = 120
    static let snapDistance: CGFloat = 48
    static let maximumSnapVelocity: CGFloat = 1_200
    let start: CGFloat
    let translation: CGFloat
    let today: CGFloat

    func offset(translation: CGFloat) -> CGFloat {
        let proposed = start - (translation - self.translation)
        guard start >= today - 2, proposed < today else { return proposed }
        let pull = today - proposed
        let distance = Self.releaseDistance
        let t = min(pull / distance, 1)
        // Integrate a smoothstep velocity: 1/4 speed at Today, then smoothly
        // regain finger speed without a positional jump at the release point.
        let resisted = distance * (0.25 * t + 0.75 * (t * t * t - 0.5 * t * t * t * t))
        return today - resisted - max(0, pull - distance)
    }

    func shouldSnap(offset: CGFloat, translation: CGFloat, velocity: CGFloat) -> Bool {
        let raw = start - (translation - self.translation)
        if start >= today - 2, raw < today, raw > today - Self.releaseDistance {
            return true
        }
        return abs(offset - today) <= Self.snapDistance && abs(velocity) < Self.maximumSnapVelocity
    }
}

@MainActor
final class UpcomingScrollDetent {
    private(set) weak var scrollView: UIScrollView?
    private weak var anchor: UIView?
    private(set) var todayOffset: CGFloat?
    private(set) var phase = ScrollPhase.idle
    private var offsetObservation: NSKeyValueObservation?
    private var drag: UpcomingScrollDetentDrag?
    private var settleTask: Task<Void, Never>?
    private var adjustingOffset = false
    private var hasResisted = false
    var reduceMotion = false

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
        settleTask?.cancel()
        settleTask = nil
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
    }

    func phaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase, velocity: CGFloat) {
        phase = newPhase
        if newPhase == .tracking {
            cancelInteraction()
            beginInteraction()
        } else if newPhase == .interacting, drag == nil {
            beginInteraction()
        } else if oldPhase == .interacting, newPhase == .decelerating || newPhase == .idle {
            endInteraction(velocity: velocity)
        } else if oldPhase == .decelerating, newPhase == .idle, settleTask == nil {
            endInteraction(velocity: 0)
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
    }

    private func offsetChanged() {
        guard !adjustingOffset, let scrollView else { return }
        updateAnchor()
        if phase == .interacting, !usesAssistiveScrolling, let drag, drag.start >= drag.today - 2 {
            let translation = scrollView.panGestureRecognizer.translation(in: scrollView.window).y
            let raw = drag.start - (translation - drag.translation)
            hasResisted = hasResisted || raw < drag.today
            if hasResisted {
                let y = drag.offset(translation: translation)
                let minimum = -scrollView.adjustedContentInset.top
                let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
                // Once the gesture reaches an outer edge, leave its rubber-band
                // behavior to UIKit instead of clamping the scroll position.
                guard y > minimum, y < maximum else {
                    self.drag = nil
                    return
                }
                if abs(y - scrollView.contentOffset.y) > 0.01 {
                    adjustingOffset = true
                    scrollView.contentOffset.y = y
                    adjustingOffset = false
                }
            }
        }
    }

    private func endInteraction(velocity: CGFloat) {
        let completedDrag = drag
        drag = nil
        guard !usesAssistiveScrolling, let scrollView, let todayOffset else { return }
        let current = scrollView.contentOffset.y
        let shouldSnap = completedDrag?.shouldSnap(
            offset: current,
            translation: scrollView.panGestureRecognizer.translation(in: scrollView.window).y,
            velocity: velocity
        ) ?? (abs(current - todayOffset) <= UpcomingScrollDetentDrag.snapDistance
            && abs(velocity) < UpcomingScrollDetentDrag.maximumSnapVelocity)
        guard shouldSnap, abs(current - todayOffset) > 0.5 else { return }
        // Stop momentum before starting the native settle, on the next turn.
        // Otherwise UIKit can consume the animated request while decelerating.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self, weak scrollView] in
            await Task.yield()
            guard !Task.isCancelled, let self, let scrollView,
                  self.scrollView === scrollView, !self.usesAssistiveScrolling,
                  self.phase != .tracking, self.phase != .interacting,
                  let target = self.todayOffset else { return }
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: !self.reduceMotion)
        }
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
