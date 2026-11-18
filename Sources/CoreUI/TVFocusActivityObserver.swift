#if os(tvOS)
import SwiftUI
import UIKit

/// Observes the presented HUD's native input without changing focus or consuming presses.
public struct TVFocusActivityObserver: UIViewRepresentable {
    let onActivity: () -> Void
    let observesPlaybackPresses: Bool
    let onFocusedFrame: ((CGRect) -> Void)?
    let onUp: (() -> Void)?
    let onFocusOutsideContent: ((Bool) -> Void)?
    let ignoresProgrammaticFocusChanges: Bool
    let observesDirectionalPresses: Bool
    let onFailedMove: ((MoveCommandDirection) -> Void)?

    public init(
        onActivity: @escaping () -> Void,
        observesPlaybackPresses: Bool = false,
        onFocusedFrame: ((CGRect) -> Void)? = nil,
        onUp: (() -> Void)? = nil,
        onFocusOutsideContent: ((Bool) -> Void)? = nil,
        ignoresProgrammaticFocusChanges: Bool = false,
        observesDirectionalPresses: Bool = true,
        onFailedMove: ((MoveCommandDirection) -> Void)? = nil
    ) {
        self.onActivity = onActivity
        self.observesPlaybackPresses = observesPlaybackPresses
        self.onFocusedFrame = onFocusedFrame
        self.onUp = onUp
        self.onFocusOutsideContent = onFocusOutsideContent
        self.ignoresProgrammaticFocusChanges = ignoresProgrammaticFocusChanges
        self.observesDirectionalPresses = observesDirectionalPresses
        self.onFailedMove = onFailedMove
    }

    public func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.onActivity = onActivity
        view.onFocusedFrame = onFocusedFrame
        view.onUp = onUp
        view.onFocusOutsideContent = onFocusOutsideContent
        view.ignoresProgrammaticFocusChanges = ignoresProgrammaticFocusChanges
        view.observesDirectionalPresses = observesDirectionalPresses
        view.onFailedMove = onFailedMove
        view.observesPlaybackPresses = observesPlaybackPresses
        return view
    }

    public func updateUIView(_ uiView: ObserverView, context: Context) {
        uiView.onActivity = onActivity
        uiView.onFocusedFrame = onFocusedFrame
        uiView.onUp = onUp
        uiView.onFocusOutsideContent = onFocusOutsideContent
        uiView.ignoresProgrammaticFocusChanges = ignoresProgrammaticFocusChanges
        uiView.observesDirectionalPresses = observesDirectionalPresses
        uiView.onFailedMove = onFailedMove
        uiView.observesPlaybackPresses = observesPlaybackPresses
    }

    public static func dismantleUIView(_ uiView: ObserverView, coordinator: ()) {
        uiView.stop()
    }

    public final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var onActivity: (() -> Void)?
        var onFocusedFrame: ((CGRect) -> Void)?
        var onUp: (() -> Void)?
        var onFocusOutsideContent: ((Bool) -> Void)?
        var ignoresProgrammaticFocusChanges = false
        var observesDirectionalPresses = true
        var onFailedMove: ((MoveCommandDirection) -> Void)?
        var observesPlaybackPresses = false {
            didSet {
                guard oldValue != observesPlaybackPresses else { return }
                pressObserver?.allowedPressTypes = allowedPressTypes
            }
        }
        private weak var observedWindow: UIWindow?
        private var pressObserver: UITapGestureRecognizer?
        private var upSwipeObserver: UISwipeGestureRecognizer?

        private var allowedPressTypes: [NSNumber] {
            var types: [UIPress.PressType] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
            if observesPlaybackPresses { types += [.select, .playPause] }
            return types.map { NSNumber(value: $0.rawValue) }
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            detachObservers()
            guard let window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusMovementFailed(_:)),
                name: UIFocusSystem.movementDidFailNotification, object: nil)
            let presses = UITapGestureRecognizer()
            presses.allowedPressTypes = allowedPressTypes
            presses.allowedTouchTypes = []
            presses.cancelsTouchesInView = false
            presses.delaysTouchesBegan = false
            presses.delaysTouchesEnded = false
            presses.delegate = self
            window.addGestureRecognizer(presses)
            pressObserver = presses
            if onUp != nil {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp(_:)))
                swipe.direction = .up
                swipe.allowedPressTypes = []
                swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
                swipe.cancelsTouchesInView = false
                swipe.delegate = self
                window.addGestureRecognizer(swipe)
                upSwipeObserver = swipe
            }
        }

        func stop() {
            detachObservers()
            onActivity = nil
            onFocusedFrame = nil
            onUp = nil
            onFocusOutsideContent = nil
            onFailedMove = nil
        }

        private func detachObservers() {
            NotificationCenter.default.removeObserver(self)
            if let pressObserver { observedWindow?.removeGestureRecognizer(pressObserver) }
            if let upSwipeObserver { observedWindow?.removeGestureRecognizer(upSwipeObserver) }
            pressObserver = nil
            upSwipeObserver = nil
            observedWindow = nil
        }

        @objc private func focusDidUpdate(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
            observeFocusUpdate(previous: context.previouslyFocusedItem,
                               next: context.nextFocusedItem, heading: context.focusHeading)
        }

        func observeFocusUpdate(
            previous: (any UIFocusItem)?, next: (any UIFocusItem)?, heading: UIFocusHeading
        ) {
            guard let window,
                  focusedView(for: next ?? previous)?.window === window
            else { return }
            reportFocusOwnership(for: next)
            if !ignoresProgrammaticFocusChanges || !heading.isEmpty {
                reportActivity(for: next)
            }
        }

        @objc private func focusMovementFailed(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
            observeFailedMove(previous: context.previouslyFocusedItem, heading: context.focusHeading)
        }

        func observeFailedMove(previous: (any UIFocusItem)?, heading: UIFocusHeading) {
            guard contains(previous) else { return }
            if !observesDirectionalPresses { reportActivity(for: previous) }
            switch heading {
            case .left: onFailedMove?(.left)
            case .right: onFailedMove?(.right)
            case .up: onFailedMove?(.up)
            case .down: onFailedMove?(.down)
            default: break
            }
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            guard gestureRecognizer === pressObserver else { return false }
            let item = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
            return observePress(press.type, focusedItem: item)
        }

        func observePress(_ type: UIPress.PressType, focusedItem: (any UIFocusItem)?) -> Bool {
            if type == .upArrow, contains(focusedItem) { onUp?() }
            switch type {
            case .leftArrow, .rightArrow, .upArrow, .downArrow:
                if observesDirectionalPresses { reportActivity(for: focusedItem) }
            case .select, .playPause:
                if observesPlaybackPresses { reportActivity(for: focusedItem) }
            default: break
            }
            // Receiving an arrow at the end of a row is still activity. Reject
            // recognition so UIKit alone performs navigation and press replay.
            return false
        }

        public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === upSwipeObserver else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            return contains(window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem })
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        @objc private func swipedUp(_ recognizer: UISwipeGestureRecognizer) {
            if recognizer.state == .ended { onUp?() }
        }

        private func reportFocusOwnership(for item: (any UIFocusItem)?) {
            if let onFocusOutsideContent {
                var responder: UIResponder? = self
                while let current = responder, !(current is UIViewController) { responder = current.next }
                if let content = (responder as? UIViewController)?.view {
                    onFocusOutsideContent(focusedView(for: item)?.isDescendant(of: content) != true)
                }
            }
        }

        private func focusedView(for item: (any UIFocusItem)?) -> UIView? {
            var environment: (any UIFocusEnvironment)? = item
            while let current = environment, !(current is UIView) {
                environment = current.parentFocusEnvironment
            }
            return environment as? UIView
        }

        func reportActivity(for item: (any UIFocusItem)?) {
            guard let frame = focusedFrame(for: item) else { return }
            onFocusedFrame?(frame)
            onActivity?()
        }

        func contains(_ item: (any UIFocusItem)?) -> Bool {
            focusedFrame(for: item) != nil
        }

        private func focusedFrame(for item: (any UIFocusItem)?) -> CGRect? {
            guard let window, let item, item.canBecomeFocused, !bounds.isEmpty else { return nil }
            let frame: CGRect
            if let view = item as? UIView {
                guard view.window === window else { return nil }
                frame = view.convert(view.bounds, to: self)
            } else {
                var environment = item.parentFocusEnvironment
                var container: (any UIFocusItemContainer)?
                var parentView: UIView?
                while let current = environment {
                    if let view = current as? UIView {
                        guard view.window === window else { return nil }
                        parentView = view
                        if container == nil { container = view.focusItemContainer }
                        break
                    }
                    if container == nil { container = current.focusItemContainer }
                    environment = current.parentFocusEnvironment
                }
                if let container {
                    let coordinates: any UICoordinateSpace = self
                    frame = coordinates.convert(item.frame, from: container.coordinateSpace)
                } else if let parentView {
                    // SwiftUI's virtual focus items use their hosting view's coordinates
                    // without exposing a UIFocusItemContainer.
                    frame = parentView.convert(item.frame, to: self)
                } else {
                    return nil
                }
            }
            guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                  bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return frame
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            if let pressObserver {
                let window = observedWindow
                Task { @MainActor in window?.removeGestureRecognizer(pressObserver) }
            }
            if let upSwipeObserver {
                let window = observedWindow
                Task { @MainActor in window?.removeGestureRecognizer(upSwipeObserver) }
            }
        }
    }
}
#endif
