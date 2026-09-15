#if os(tvOS)
import SwiftUI
import UIKit

/// Keep Down in the hero while the episode browser is unavailable during entrance.
struct SeriesEntranceFocusGuard: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.enabled = isEnabled
        view.connect()
    }

    static func dismantleUIView(_ view: Marker, coordinator: ()) {
        view.disconnect()
    }

    final class Marker: UIView {
        var enabled = false
        private weak var guardedWindow: UIWindow?
        private var guide: UIFocusGuide?
        private var top: NSLayoutConstraint?
        private var height: NSLayoutConstraint?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
        }

        func connect() {
            guard enabled, let window else {
                disconnect()
                return
            }
            if guardedWindow !== window {
                disconnect()
                guardedWindow = window
                let guide = UIFocusGuide()
                guide.isEnabled = false
                window.addLayoutGuide(guide)
                let top = guide.topAnchor.constraint(equalTo: window.topAnchor)
                let height = guide.heightAnchor.constraint(equalToConstant: 1)
                NSLayoutConstraint.activate([
                    guide.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                    guide.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                    top, height
                ])
                self.guide = guide
                self.top = top
                self.height = height
                NotificationCenter.default.addObserver(
                    self, selector: #selector(focusChanged(_:)),
                    name: UIFocusSystem.didUpdateNotification, object: nil
                )
            }
            adopt(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        }

        @objc private func focusChanged(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                as? UIFocusUpdateContext else { return }
            adopt(context.nextFocusedItem)
        }

        private func adopt(_ item: (any UIFocusItem)?) {
            guard enabled, let window = guardedWindow, let item,
                  item.canBecomeFocused, !bounds.isEmpty,
                  let frame = frame(of: item, in: window),
                  !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                  bounds.contains(convert(CGPoint(x: frame.midX, y: frame.midY), from: window))
            else { return }
            let lowerEdge = min(window.bounds.maxY - 1, frame.maxY)
            if top?.constant != lowerEdge { top?.constant = lowerEdge }
            let guideHeight = max(1, window.bounds.maxY - lowerEdge)
            if height?.constant != guideHeight { height?.constant = guideHeight }
            guide?.preferredFocusEnvironments = [item]
            guide?.isEnabled = true
        }

        private func frame(of item: any UIFocusItem, in window: UIWindow) -> CGRect? {
            if let view = item as? UIView {
                return view.window === window ? view.convert(view.bounds, to: window) : nil
            }
            var parent = item.parentFocusEnvironment
            var visited = Set<ObjectIdentifier>()
            while let current = parent, visited.insert(ObjectIdentifier(current)).inserted {
                if let container = current.focusItemContainer {
                    let coordinates: any UICoordinateSpace = window
                    return coordinates.convert(item.frame, from: container.coordinateSpace)
                }
                parent = current.parentFocusEnvironment
            }
            return nil
        }

        func disconnect() {
            NotificationCenter.default.removeObserver(self)
            if let guide {
                guide.isEnabled = false
                guide.preferredFocusEnvironments = []
                guardedWindow?.removeLayoutGuide(guide)
            }
            guide = nil
            top = nil
            height = nil
            guardedWindow = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
#endif
