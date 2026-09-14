#if os(tvOS)
import CoreUI
import CoreNetworking
import SwiftUI
import UIKit

/// New destinations start at their first visible control, not beside the expanded rail.
struct NavigationContentFocusRequester: UIViewRepresentable {
    let request: UInt64?
    let onCompleted: (UInt64, Bool) -> Void

    func makeUIView(context: Context) -> RequestView {
        let view = RequestView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: RequestView, context: Context) {
        view.isRightToLeft = context.environment.layoutDirection == .rightToLeft
        view.onCompleted = onCompleted
        view.request = request
    }

    static func dismantleUIView(_ view: RequestView, coordinator: ()) {
        view.request = nil
        view.onCompleted = nil
    }

    final class RequestView: UIView {
        var isRightToLeft = false
        var onCompleted: ((UInt64, Bool) -> Void)?
        var request: UInt64? {
            didSet {
                guard request != oldValue else { return }
                pending?.cancel()
                pending = nil
                schedule()
            }
        }
        private var pending: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            schedule()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            schedule()
        }

        private func schedule() {
            guard pending == nil, let request, window != nil else { return }
            pending = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, self.request == request else { return }
                defer { pending = nil }
                guard let window, let system = UIFocusSystem.focusSystem(for: window) else { return }
                window.layoutIfNeeded()
                guard self.request == request, self.window === window else { return }
                guard let target = NavigationContentFocusRequester.firstTarget(
                    in: window, relativeTo: self, isRightToLeft: isRightToLeft
                ) else {
                    PlozzLog.app.debug("New navigation page has no visible focus target yet")
                    complete(request, didFocus: false)
                    return
                }
                system.requestFocusUpdate(to: target)
                system.updateFocusIfNeeded()
                let didFocus = system.focusedItem === target
                if !didFocus {
                    PlozzLog.app.debug("New navigation page rejected its first-content focus request")
                }
                complete(request, didFocus: didFocus)
            }
        }

        private func complete(_ request: UInt64, didFocus: Bool) {
            guard self.request == request else { return }
            self.request = nil
            onCompleted?(request, didFocus)
        }

        deinit { pending?.cancel() }
    }

    static func firstTarget(
        in window: UIWindow, relativeTo marker: UIView, isRightToLeft: Bool
    ) -> (any UIFocusItem)? {
        guard !marker.bounds.isEmpty else { return nil }
        let railTargets = Set(railMarkers(in: window).compactMap {
            NavigationRowFocusRequester.target(for: $0, in: window).map(ObjectIdentifier.init)
        })
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var candidates: [(item: any UIFocusItem, frame: CGRect)] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let query = container.coordinateSpace.convert(marker.bounds, from: marker)
            for item in container.focusItems(in: query) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                guard item.canBecomeFocused, !(item is UIScrollView),
                      !railTargets.contains(ObjectIdentifier(item)),
                      let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: marker),
                      frame.width > 1, frame.height > 1,
                      !frame.isNull, !frame.isInfinite,
                      marker.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                candidates.append((item, frame))
            }
        }
        guard let index = firstFrameIndex(candidates.map(\.frame), isRightToLeft: isRightToLeft) else { return nil }
        return candidates[index].item
    }

    private static func railMarkers(in view: UIView) -> [NavigationRowFocusRequester.RequestView] {
        if let marker = view as? NavigationRowFocusRequester.RequestView { return [marker] }
        return view.subviews.flatMap { railMarkers(in: $0) }
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
