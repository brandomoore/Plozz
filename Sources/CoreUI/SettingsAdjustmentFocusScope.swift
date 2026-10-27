#if canImport(SwiftUI)
import SwiftUI

public enum SettingsMoveCommandDirection {
    case up, down, left, right
}

#if os(tvOS)
import UIKit

public enum SettingsAdjustmentRepeatSpeed: Sendable {
    case standard
    case fast

    var interval: TimeInterval {
        switch self {
        case .standard: 0.08
        case .fast: 0.03
        }
    }
}

private struct SettingsAdjustmentRepeatSpeedKey: EnvironmentKey {
    static let defaultValue = SettingsAdjustmentRepeatSpeed.standard
}

public extension EnvironmentValues {
    var settingsAdjustmentRepeatSpeed: SettingsAdjustmentRepeatSpeed {
        get { self[SettingsAdjustmentRepeatSpeedKey.self] }
        set { self[SettingsAdjustmentRepeatSpeedKey.self] = newValue }
    }
}

@MainActor
public protocol SettingsAdjustmentRemoteInput: AnyObject, HorizontalNavigationInputOwning {
    func beginPress(_ direction: SettingsMoveCommandDirection)
    func stopRepeating()
}

/// Owns adjustment input on one axis without moving native focus to another row.
public struct SettingsAdjustmentFocusScope<Content: View, Screen: Equatable>: UIViewControllerRepresentable {
    @Environment(\.settingsAdjustmentRepeatSpeed) private var repeatSpeed
    let content: Content
    let screen: Screen
    let adjustableRow: () -> Int?
    let submenuRow: () -> Int?
    let onMove: (SettingsMoveCommandDirection, Bool) -> Void
    let idealWidth: CGFloat
    let axis: Axis

    public init(
        content: Content,
        screen: Screen,
        adjustableRow: @escaping () -> Int?,
        submenuRow: @escaping () -> Int? = { nil },
        idealWidth: CGFloat = SettingsFormMetrics.pageWidth,
        axis: Axis = .horizontal,
        onMove: @escaping (SettingsMoveCommandDirection, Bool) -> Void
    ) {
        self.content = content
        self.screen = screen
        self.adjustableRow = adjustableRow
        self.submenuRow = submenuRow
        self.idealWidth = idealWidth
        self.axis = axis
        self.onMove = onMove
    }

    public func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(rootView: hostedContent(environment: context.environment))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        controller.screen = screen
        controller.axis = axis
        controller.repeatSpeed = repeatSpeed
        controller.adjustableRow = adjustableRow
        controller.submenuRow = submenuRow
        controller.onMove = onMove
        return controller
    }

    public func updateUIViewController(_ controller: Controller, context: Context) {
        controller.screen = screen
        controller.axis = axis
        controller.repeatSpeed = repeatSpeed
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

    public static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.stopRepeating()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(
            width: proposal.width ?? idealWidth,
            height: proposal.height ?? .greatestFiniteMagnitude
        ))
    }

    public final class Controller: UIHostingController<AnyView>, UIGestureRecognizerDelegate, SettingsAdjustmentRemoteInput {
        var adjustableRow: (() -> Int?)?
        var submenuRow: (() -> Int?)?
        var onMove: ((SettingsMoveCommandDirection, Bool) -> Void)?
        var screen: Screen? {
            didSet {
                if oldValue != screen { stopRepeating() }
            }
        }
        var axis: Axis = .horizontal {
            didSet {
                if oldValue != axis { stopRepeating() }
            }
        }
        var repeatSpeed: SettingsAdjustmentRepeatSpeed = .standard {
            didSet {
                if oldValue != repeatSpeed { stopRepeating() }
            }
        }
        private var heldRow: Int?
        private weak var heldItem: (any UIFocusItem)?
        private var heldDirection: SettingsMoveCommandDirection?
        private var repeatWork: DispatchWorkItem?
        private var repeatGeneration: UInt64 = 0
        public var ownsHorizontalNavigationInput: Bool { axis == .horizontal && focusedAdjustableRow != nil }

        public override func viewDidLoad() {
            super.viewDidLoad()
            let press = ArrowPressRecognizer()
            press.delegate = self
            press.began = { [weak self] in self?.beginPress($0) }
            press.finished = { [weak self] in self?.stopRepeating() }
            view.addGestureRecognizer(press)

            let pan = DirectionalPanRecognizer(target: self, action: #selector(swiped(_:)))
            pan.allowedPressTypes = []
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.delegate = self
            view.addGestureRecognizer(pan)
            NotificationCenter.default.addObserver(
                self, selector: #selector(stopRepeating),
                name: UIApplication.willResignActiveNotification, object: nil
            )
        }

        public override func viewWillDisappear(_ animated: Bool) {
            stopRepeating()
            super.viewWillDisappear(animated)
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard axis == .vertical, focusedAdjustableRow != nil,
                  let item = UIFocusSystem.focusSystem(for: view)?.focusedItem else { return }
            var ancestor = view.superview
            while let parent = ancestor {
                if let scroll = parent as? UIScrollView {
                    var environment: (any UIFocusEnvironment)? = item
                    while let current = environment {
                        if let container = current.focusItemContainer {
                            let frame = container.coordinateSpace.convert(item.frame, to: scroll)
                            // Moving the focused item does not trigger UIKit's normal focus-scroll handoff.
                            scroll.scrollRectToVisible(frame.insetBy(dx: 0, dy: -24), animated: false)
                            return
                        }
                        environment = current.parentFocusEnvironment
                    }
                    return
                }
                ancestor = parent.superview
            }
        }

        public override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if owns(context.previouslyFocusedItem) {
                if adjustableRow?() != nil,
                   !context.focusHeading.intersection(axis == .horizontal ? [.left, .right] : [.up, .down]).isEmpty {
                    return false
                }
                if submenuRow?() != nil, context.focusHeading.contains(.right) { return false }
            }
            return super.shouldUpdateFocus(in: context)
        }

        public override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
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

        private func accepts(_ direction: SettingsMoveCommandDirection) -> Bool {
            let onAxis = axis == .horizontal
                ? direction == .left || direction == .right
                : direction == .up || direction == .down
            return onAxis && (focusedAdjustableRow != nil || (direction == .right && focusedSubmenuRow != nil))
        }

        private func owns(_ item: (any UIFocusItem)?) -> Bool {
            guard let item else { return false }
            if let focusedView = item as? UIView, focusedView.isDescendant(of: view) {
                return true
            }
            return view.contains(item)
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            switch press.type {
            case .leftArrow: accepts(.left)
            case .rightArrow: accepts(.right)
            case .upArrow: accepts(.up)
            case .downArrow: accepts(.down)
            default: false
            }
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            (focusedAdjustableRow != nil || focusedSubmenuRow != nil) && heldRow == nil
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return focusedAdjustableRow != nil || focusedSubmenuRow != nil
            }
            let velocity = pan.velocity(in: view)
            let onAxis = axis == .horizontal ? abs(velocity.x) > abs(velocity.y) : abs(velocity.y) > abs(velocity.x)
            return heldRow == nil && onAxis && accepts(direction(for: velocity))
        }

        private func direction(for velocity: CGPoint) -> SettingsMoveCommandDirection {
            axis == .horizontal ? (velocity.x < 0 ? .left : .right) : (velocity.y < 0 ? .up : .down)
        }

        @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
            let direction = direction(for: recognizer.velocity(in: view))
            guard recognizer.state == .began, heldRow == nil, accepts(direction) else { return }
            onMove?(direction, false)
        }

        public func beginPress(_ direction: SettingsMoveCommandDirection) {
            stopRepeating()
            guard accepts(direction) else { return }
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
                    self.scheduleRepeat(after: self.repeatSpeed.interval)
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

        @objc public func stopRepeating() {
            repeatGeneration &+= 1
            repeatWork?.cancel()
            repeatWork = nil
            heldRow = nil
            heldItem = nil
            heldDirection = nil
        }
    }

    private final class ArrowPressRecognizer: UIGestureRecognizer {
        var began: ((SettingsMoveCommandDirection) -> Void)?
        var finished: (() -> Void)?

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow, .upArrow, .downArrow].map {
                NSNumber(value: $0.rawValue)
            }
            allowedTouchTypes = []
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard state == .possible, let press = presses.first else { return }
            state = .began
            switch press.type {
            case .leftArrow: began?(.left)
            case .rightArrow: began?(.right)
            case .upArrow: began?(.up)
            case .downArrow: began?(.down)
            default: break
            }
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

    private final class DirectionalPanRecognizer: UIPanGestureRecognizer {
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
#endif
#endif
