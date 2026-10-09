#if os(tvOS)
import CoreUI
import CoreNetworking
import FeatureHome
import SwiftUI
import UIKit

/// New destinations start at their first visible control, not beside the expanded rail.
struct NavigationContentFocusRequester: UIViewRepresentable {
    let request: UInt64?
    let onCompleted: (UInt64, Bool) -> Void
    var returnFocus: ReturnFocus?
    var restoresPreviousFocus = false

    func makeUIView(context: Context) -> RequestView {
        let view = RequestView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        returnFocus?.marker = view
        return view
    }

    func updateUIView(_ view: RequestView, context: Context) {
        view.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        view.onCompleted = onCompleted
        returnFocus?.marker = view
        view.returnFocus = restoresPreviousFocus ? returnFocus : nil
        view.request = request
    }

    static func dismantleUIView(_ view: RequestView, coordinator: ()) {
        view.request = nil
        view.onCompleted = nil
        view.returnFocus = nil
    }

    @MainActor
    final class ReturnFocus {
        weak var marker: UIView?
        private weak var item: (any UIFocusItem)?
        private weak var capturedWindow: UIWindow?

        func capture() {
            clear()
            guard let marker, let window = marker.window,
                  let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                  Self.isVisible(focused, relativeTo: marker) else { return }
            item = focused
            capturedWindow = window
            HeroFocusDiagnostics.emit("sidebar.content capture=\(String(describing: focused))")
        }

        func clear() {
            item = nil
            capturedWindow = nil
        }

        func target(relativeTo marker: UIView) -> (any UIFocusItem)? {
            guard let item, let window = marker.window, window === capturedWindow,
                  item.canBecomeFocused, (item as? UIControl)?.isEnabled != false,
                  Self.isVisible(item, relativeTo: marker) else { return nil }
            var environment: (any UIFocusEnvironment)? = item
            var seen = Set<ObjectIdentifier>()
            while let current = environment, seen.insert(ObjectIdentifier(current)).inserted {
                if current === window { return item }
                if let view = current as? UIView {
                    return NavigationContentFocusRequester.isVisible(view, in: window) ? item : nil
                }
                environment = current.parentFocusEnvironment
            }
            return nil
        }

        private static func isVisible(_ item: any UIFocusItem, relativeTo marker: UIView) -> Bool {
            guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: marker),
                  !frame.isEmpty, !frame.isNull, !frame.isInfinite else { return false }
            return marker.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    final class RequestView: UIView {
        var isRightToLeft = false
        var onCompleted: ((UInt64, Bool) -> Void)?
        var returnFocus: ReturnFocus?
        var request: UInt64? {
            didSet {
                guard request != oldValue else { return }
                stop()
                schedule()
            }
        }
        private var displayLink: CADisplayLink?
        private var crossedFrame = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() } else { schedule() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            schedule()
        }

        private func schedule() {
            guard displayLink == nil, request != nil, window != nil, !bounds.isEmpty else { return }
            let link = CADisplayLink(target: self, selector: #selector(framePresented))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func framePresented() {
            guard let request, let window, !bounds.isEmpty else {
                stop()
                return
            }
            // Presentation releases the disabled-content gate. Cross its render
            // commit before querying nested hosts; Task.yield can still see only rail rows.
            guard crossedFrame else {
                crossedFrame = true
                return
            }
            stop()
            guard let system = UIFocusSystem.focusSystem(for: window) else {
                complete(request, didFocus: false)
                return
            }
            window.layoutIfNeeded()
            guard self.request == request, self.window === window else { return }
            let previous = returnFocus?.target(relativeTo: self)
            guard let target = previous
                ?? NavigationContentFocusRequester.firstTarget(
                in: window, relativeTo: self, isRightToLeft: isRightToLeft
            ) else {
                PlozzLog.app.debug("New navigation page has no visible focus target yet")
                complete(request, didFocus: false)
                return
            }
            guard let owner = NavigationRailFocusHostController.containing(self) else {
                PlozzLog.app.error("Navigation content has no shared native focus owner")
                complete(request, didFocus: false)
                return
            }
            let didFocus = owner.requestFocus(to: target, using: system)
            HeroFocusDiagnostics.emit("sidebar.content request=\(request) previous=\(String(describing: previous)) target=\(String(describing: target)) focused=\(String(describing: system.focusedItem)) success=\(didFocus)")
            if !didFocus {
                PlozzLog.app.debug("New navigation page rejected its first-content focus request")
            }
            complete(request, didFocus: didFocus)
        }

        private func stop() {
            displayLink?.invalidate()
            displayLink = nil
            crossedFrame = false
        }

        private func complete(_ request: UInt64, didFocus: Bool) {
            guard self.request == request else { return }
            self.request = nil
            onCompleted?(request, didFocus)
        }

    }

    static func firstTarget(
        in window: UIWindow, relativeTo marker: UIView, isRightToLeft: Bool
    ) -> (any UIFocusItem)? {
        guard !marker.bounds.isEmpty else { return nil }
        let rows = railMarkers(in: window)
        var containers: [any UIFocusItemContainer] = [window]
        // A hosting view's virtual items omit controls in nested native controllers.
        var controllers = window.rootViewController.map { [$0] } ?? []
        while let controller = controllers.popLast() {
            controllers.append(contentsOf: controller.children)
            if let view = controller.viewIfLoaded, isVisible(view, in: window) {
                containers.append(view)
            }
        }
        var seen = Set<ObjectIdentifier>()
        var candidates: [(item: any UIFocusItem, frame: CGRect)] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            if let view = container.coordinateSpace as? UIView, view !== window,
               !isVisible(view, in: window) { continue }
            let query = container.coordinateSpace.convert(marker.bounds, from: marker)
            for item in container.focusItems(in: query) {
                if let view = item as? UIView, !isVisible(view, in: window) { continue }
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                guard item.canBecomeFocused, (item as? UIControl)?.isEnabled != false,
                      !(item is UIScrollView),
                      let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: marker),
                      frame.width > 1, frame.height > 1,
                      !frame.isNull, !frame.isInfinite,
                      marker.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                candidates.append((item, frame))
            }
        }
        // SwiftUI can recreate virtual focus items between queries. Resolve the
        // rail and page from one snapshot instead of comparing separate queries'
        // object identities (and walking the entire window once per rail row).
        let railFrames = rows.filter { !$0.bounds.isEmpty }.map { $0.convert($0.bounds, to: marker) }
        // Scrolled rows can overlap Profile; exclude every item centered in the
        // row labels, not just one minimum-area match per label.
        candidates.removeAll { candidate in
            railFrames.contains {
                $0.insetBy(dx: -0.5, dy: -0.5).contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
            }
        }
        guard let index = firstFrameIndex(candidates.map(\.frame), isRightToLeft: isRightToLeft) else { return nil }
        return candidates[index].item
    }

    private static func railMarkers(in view: UIView) -> [NavigationRowFocusRequester.RequestView] {
        if let marker = view as? NavigationRowFocusRequester.RequestView { return [marker] }
        return view.subviews.flatMap { railMarkers(in: $0) }
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return false }
            if current === window { return true }
            ancestor = current.superview
        }
        return false
    }

    static func firstFrameIndex(_ frames: [CGRect], isRightToLeft: Bool) -> Int? {
        guard let top = frames.min(by: { $0.midY < $1.midY }) else { return nil }
        // Focus expansion can move a later card's top edge above the first card.
        // Pick the leading control in the first row, not the most-expanded one.
        return frames.indices.filter {
            frames[$0].minY <= top.midY && frames[$0].maxY >= top.midY
        }.min {
            isRightToLeft ? frames[$0].maxX > frames[$1].maxX : frames[$0].minX < frames[$1].minX
        }
    }
}
#endif
