#if os(iOS)
import SwiftUI
import UIKit

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

    func target(proposed: CGFloat, translation: CGFloat) -> CGFloat {
        let raw = start - (translation - self.translation)
        if start >= today - 2, raw < today, raw > today - Self.releaseDistance, proposed < today {
            return today
        }
        return abs(proposed - today) <= Self.snapDistance ? today : proposed
    }
}

@MainActor
final class UpcomingScrollDetent: NSObject, UIScrollViewDelegate {
    private(set) weak var scrollView: UIScrollView?
    private weak var previousDelegate: UIScrollViewDelegate?
    private weak var anchor: UIView?
    private(set) var todayOffset: CGFloat?
    private var drag: UpcomingScrollDetentDrag?
    private var settlingOffset: CGFloat?
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
        }
        if scroll.delegate !== self {
            previousDelegate = scroll.delegate
            scroll.delegate = self
        }
        updateAnchor()
    }

    func detach() {
        if let scrollView, scrollView.delegate === self {
            scrollView.delegate = previousDelegate
        }
        scrollView = nil
        previousDelegate = nil
        todayOffset = nil
        drag = nil
        settlingOffset = nil
        hasResisted = false
    }

    func setAnchor(_ view: UIView) {
        anchor = view
        updateAnchor()
    }

    func removeAnchor(_ view: UIView) {
        if anchor === view {
            anchor = nil
            todayOffset = nil
            drag = nil
            settlingOffset = nil
        }
    }

    func updateAnchor() {
        guard let scrollView, let anchor, anchor.window != nil, anchor.bounds.width > 0,
              anchor.isDescendant(of: scrollView) else { return }
        let offset = anchor.convert(.zero, to: scrollView).y - scrollView.adjustedContentInset.top
        if let todayOffset, abs(offset - todayOffset) > 1 {
            drag = nil
            settlingOffset = nil
        }
        todayOffset = offset
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        previousDelegate?.scrollViewWillBeginDragging?(scrollView)
        updateAnchor()
        settlingOffset = nil
        hasResisted = false
        guard !usesAssistiveScrolling, let todayOffset else { drag = nil; return }
        drag = UpcomingScrollDetentDrag(
            start: scrollView.contentOffset.y,
            translation: scrollView.panGestureRecognizer.translation(in: scrollView.window).y,
            today: todayOffset
        )
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjustingOffset else { return }
        updateAnchor()
        if scrollView.isDragging, !usesAssistiveScrolling, let drag, drag.start >= drag.today - 2 {
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
                    previousDelegate?.scrollViewDidScroll?(scrollView)
                    return
                }
                if abs(y - scrollView.contentOffset.y) > 0.01 {
                    adjustingOffset = true
                    scrollView.contentOffset.y = y
                    adjustingOffset = false
                }
            }
        }
        previousDelegate?.scrollViewDidScroll?(scrollView)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        previousDelegate?.scrollViewWillEndDragging?(
            scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset
        )
        guard !usesAssistiveScrolling, let todayOffset else { return }
        let proposed = targetContentOffset.pointee.y
        let target = drag?.target(
            proposed: proposed,
            translation: scrollView.panGestureRecognizer.translation(in: scrollView.window).y
        ) ?? (abs(proposed - todayOffset) <= UpcomingScrollDetentDrag.snapDistance ? todayOffset : proposed)
        if target == todayOffset {
            settlingOffset = target
            targetContentOffset.pointee.y = reduceMotion ? scrollView.contentOffset.y : target
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        drag = nil
        previousDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        if let settlingOffset, !decelerate || reduceMotion {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: settlingOffset), animated: !reduceMotion
            )
        }
        settlingOffset = nil
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if previousDelegate?.responds(to: selector) == true { return previousDelegate }
        return super.forwardingTarget(for: selector)
    }
}

struct UpcomingScrollProbe: UIViewRepresentable {
    enum Role { case container, today }
    let detent: UpcomingScrollDetent
    let role: Role
    var reduceMotion = false

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.detent = detent
        view.role = role
        if role == .container { detent.reduceMotion = reduceMotion }
        view.connect()
    }

    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: UIView {
        weak var detent: UpcomingScrollDetent?
        var role = Role.container

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
