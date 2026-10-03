#if os(tvOS)
import CoreUI
import SwiftUI
import UIKit

@MainActor
protocol PlayerOptionsRemoteInput: AnyObject, HorizontalNavigationInputOwning {
    func beginPress(_ direction: PlozzMoveCommandDirection)
    func stopRepeating()
}

/// Owns horizontal press/swipe input before native directional focus can consume
/// it. Up/Down and non-adjustable rows remain under the native focus engine.
struct PlayerOptionsFocusScope<Content: View, Screen: Equatable>: UIViewControllerRepresentable {
    let content: Content
    let screen: Screen
    let adjustableRow: () -> Int?
    let submenuRow: () -> Int?
    let onMove: (PlozzMoveCommandDirection, Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(rootView: hostedContent(environment: context.environment))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        controller.screen = screen
        controller.adjustableRow = adjustableRow
        controller.submenuRow = submenuRow
        controller.onMove = onMove
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.screen = screen
        controller.rootView = hostedContent(environment: context.environment)
        controller.adjustableRow = adjustableRow
        controller.submenuRow = submenuRow
        controller.onMove = onMove
        controller.cancelRepeatIfFocusChanged()
    }

    private func hostedContent(environment: EnvironmentValues) -> AnyView {
        // Copy appearance, not the outer graph's focus coordination. Forwarding
        // the entire environment leaves two controls highlighted after navigation.
        AnyView(content
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.themePalette, environment.themePalette)
            .environment(\.plozzHDRDisplayActive, environment.plozzHDRDisplayActive)
            .environment(\.plozzReduceTransparency, environment.plozzReduceTransparency)
            .environment(\.plozzReducePanelGlass, environment.plozzReducePanelGlass)
        )
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.stopRepeating()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(
            width: proposal.width ?? PlayerOptionsPanel.standardWidth,
            height: proposal.height ?? .greatestFiniteMagnitude
        ))
    }

    final class Controller: UIHostingController<AnyView>, UIGestureRecognizerDelegate, PlayerOptionsRemoteInput {
        var adjustableRow: (() -> Int?)?
        var submenuRow: (() -> Int?)?
        var onMove: ((PlozzMoveCommandDirection, Bool) -> Void)?
        var screen: Screen? {
            didSet {
                if oldValue != screen { stopRepeating() }
            }
        }
        private var heldRow: Int?
        private weak var heldItem: (any UIFocusItem)?
        private var heldDirection: PlozzMoveCommandDirection?
        private var repeatWork: DispatchWorkItem?
        private var repeatGeneration: UInt64 = 0
        var ownsHorizontalNavigationInput: Bool { focusedAdjustableRow != nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            let press = ArrowPressRecognizer()
            press.delegate = self
            press.began = { [weak self] in self?.beginPress($0) }
            press.finished = { [weak self] in self?.stopRepeating() }
            view.addGestureRecognizer(press)

            let pan = HorizontalPanRecognizer(target: self, action: #selector(swiped(_:)))
            pan.allowedPressTypes = []
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.delegate = self
            view.addGestureRecognizer(pan)
            NotificationCenter.default.addObserver(
                self, selector: #selector(stopRepeating),
                name: UIApplication.willResignActiveNotification, object: nil
            )
        }

        override func viewWillDisappear(_ animated: Bool) {
            stopRepeating()
            super.viewWillDisappear(animated)
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if owns(context.previouslyFocusedItem) {
                if adjustableRow?() != nil,
                   !context.focusHeading.intersection([.left, .right]).isEmpty { return false }
                if submenuRow?() != nil, context.focusHeading.contains(.right) { return false }
            }
            return super.shouldUpdateFocus(in: context)
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            cancelRepeatIfFocusChanged()
        }

        private var focusedAdjustableRow: Int? {
            guard let window = view.window,
                  owns(UIFocusSystem.focusSystem(for: window)?.focusedItem) else { return nil }
            return adjustableRow?()
        }

        private var focusedSubmenuRow: Int? {
            guard let window = view.window,
                  owns(UIFocusSystem.focusSystem(for: window)?.focusedItem) else { return nil }
            return submenuRow?()
        }

        private func accepts(_ direction: PlozzMoveCommandDirection) -> Bool {
            focusedAdjustableRow != nil || (direction == .right && focusedSubmenuRow != nil)
        }

        private func owns(_ item: (any UIFocusItem)?) -> Bool {
            guard let item else { return false }
            if let focusedView = item as? UIView, focusedView.isDescendant(of: view) {
                return true
            }
            return view.contains(item)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            switch press.type {
            case .leftArrow: accepts(.left)
            case .rightArrow: accepts(.right)
            default: false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            (focusedAdjustableRow != nil || focusedSubmenuRow != nil) && heldRow == nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return focusedAdjustableRow != nil || focusedSubmenuRow != nil
            }
            let velocity = pan.velocity(in: view)
            return heldRow == nil && abs(velocity.x) > abs(velocity.y)
                && accepts(velocity.x < 0 ? .left : .right)
        }

        @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
            let direction: PlozzMoveCommandDirection = recognizer.velocity(in: view).x < 0 ? .left : .right
            guard recognizer.state == .began, heldRow == nil, accepts(direction) else { return }
            onMove?(direction, false)
        }

        func beginPress(_ direction: PlozzMoveCommandDirection) {
            stopRepeating()
            if direction == .right, focusedSubmenuRow != nil {
                onMove?(direction, false)
                return
            }
            guard let row = focusedAdjustableRow else { return }
            heldRow = row
            heldItem = UIFocusSystem.focusSystem(for: view)?.focusedItem
            heldDirection = direction
            onMove?(direction, false)
            scheduleRepeat(after: 0.45)
        }

        private func scheduleRepeat(after delay: TimeInterval) {
            let generation = repeatGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.repeatGeneration == generation,
                      self.stillOwnsHeldFocus,
                      let direction = self.heldDirection else { return }
                self.onMove?(direction, true)
                if self.repeatGeneration == generation {
                    self.scheduleRepeat(after: 0.08)
                }
            }
            repeatWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        func cancelRepeatIfFocusChanged() {
            if heldRow != nil, !stillOwnsHeldFocus { stopRepeating() }
        }

        private var stillOwnsHeldFocus: Bool {
            guard let heldRow, let heldItem else { return false }
            return heldRow == focusedAdjustableRow
                && UIFocusSystem.focusSystem(for: view)?.focusedItem === heldItem
        }

        @objc func stopRepeating() {
            repeatGeneration &+= 1
            repeatWork?.cancel()
            repeatWork = nil
            heldRow = nil
            heldItem = nil
            heldDirection = nil
        }
    }

    private final class ArrowPressRecognizer: UIGestureRecognizer {
        var began: ((PlozzMoveCommandDirection) -> Void)?
        var finished: (() -> Void)?

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map {
                NSNumber(value: $0.rawValue)
            }
            allowedTouchTypes = []
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard state == .possible, let press = presses.first else { return }
            state = .began
            began?(press.type == .leftArrow ? .left : .right)
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            finished?()
            state = .ended
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            finished?()
            state = .cancelled
        }

        override func reset() {
            finished?()
            super.reset()
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }

    private final class HorizontalPanRecognizer: UIPanGestureRecognizer {
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
#endif
