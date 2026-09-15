#if DEBUG && os(tvOS)
import CoreModels
import SwiftUI
import UIKit

/// Temporary opt-in trace for user-driven device reproduction; never changes focus.
struct SeriesDetailFocusTrace: UIViewRepresentable {
    let isEnabled: Bool
    let state: String

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = false
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        marker.update(isEnabled: isEnabled, state: state)
    }

    static func dismantleUIView(_ marker: Marker, coordinator: ()) {
        marker.stop()
    }

    final class Marker: UIView, UIGestureRecognizerDelegate {
        private var stateSummary = ""
        private var enabled = false
        private weak var observedWindow: UIWindow?
        private var pressObserver: UITapGestureRecognizer?
        private let page = UUID().uuidString.prefix(8)
        private var eventCount = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        func update(isEnabled: Bool, state: String) {
            let changed = stateSummary != state || enabled != isEnabled
            enabled = isEnabled
            stateSummary = state
            connect()
            if changed { emit("state") }
        }

        private func connect() {
            guard enabled, let window else {
                disconnect()
                return
            }
            guard observedWindow !== window else { return }
            disconnect()
            observedWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusChanged(_:)),
                name: UIFocusSystem.didUpdateNotification, object: nil
            )
            let observer = UITapGestureRecognizer()
            observer.allowedPressTypes = [
                UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow, .select, .menu
            ].map { NSNumber(value: $0.rawValue) }
            observer.allowedTouchTypes = []
            observer.cancelsTouchesInView = false
            observer.delegate = self
            observer.name = "Plozz series focus trace"
            window.addGestureRecognizer(observer)
            pressObserver = observer
            emit("attached")
        }

        func stop() {
            emit("detached")
            disconnect()
            enabled = false
        }

        private func disconnect() {
            NotificationCenter.default.removeObserver(self)
            if let pressObserver { observedWindow?.removeGestureRecognizer(pressObserver) }
            pressObserver = nil
            observedWindow = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            emit("press=\(press.type.rawValue)")
            return false
        }

        @objc private func focusChanged(_ notification: Notification) {
            guard observedWindow != nil,
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                  let item = context.nextFocusedItem else { return }
            emit("focus heading=\(context.focusHeading.rawValue)", item: item)
        }

        private func emit(_ event: String, item: (any UIFocusItem)? = nil) {
            guard enabled, eventCount < 160, let window = observedWindow else { return }
            eventCount += 1
            let target = item ?? UIFocusSystem.focusSystem(for: window)?.focusedItem
            var parts = ["SERIES_FOCUS page=\(page) event=\(event)", stateSummary]
            if let target {
                parts.append("target=\(type(of: target)) eligible=\(target.canBecomeFocused)")
                if let view = target as? UIView {
                    parts.append("frame=\(view.convert(view.bounds, to: window))")
                    if let control = view as? UIControl { parts.append("enabled=\(control.isEnabled)") }
                } else {
                    parts.append("localFrame=\(target.frame)")
                }
                var parent = target.parentFocusEnvironment
                var depth = 0
                while let current = parent, depth < 7 {
                    if let view = current as? UIView {
                        parts.append("parent\(depth)=\(type(of: view)) frame=\(view.convert(view.bounds, to: window)) hidden=\(view.isHidden) alpha=\(view.alpha)")
                    } else {
                        parts.append("parent\(depth)=\(type(of: current))")
                    }
                    parent = current.parentFocusEnvironment
                    depth += 1
                }
            } else {
                parts.append("target=nil")
            }
            HandoffDiagnostics.emit(parts.joined(separator: " "))
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
#endif
