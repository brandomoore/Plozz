#if os(tvOS)
import CoreModels
import CoreNetworking
import CoreUI
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class HeroShowcaseState {
    private(set) var isExpanded = true
    @ObservationIgnored var returnToHero: (() -> Void)?
    @ObservationIgnored let motion = HeroShowcaseScrollMotion()

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }
}

@MainActor
final class HeroShowcaseScrollMotion: NSObject {
    enum Surface: Hashable { case featured, featuredBackdrop, showcase, showcaseBackdrop, rows }

    static let backdropTravelFraction: CGFloat = 0.375
    static let duration: TimeInterval = 0.6
    static let timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.2, 1)

    private final class Target {
        weak var view: UIView?
        var offset: CGFloat = 0
        var keys: [String] = []
        init(view: UIView) { self.view = view }
    }

    private var targets: [Surface: Target] = [:]
    private var sequence = 0
    private(set) var distance: CGFloat = 0
    private var offset: CGFloat = 0
    private var reduceMotion = false
    private weak var navigationPosition: FocusHeroNativeScrollPosition.PositionView?
    private var navigationFrames: CADisplayLink?

    func bindNavigation(_ position: FocusHeroNativeScrollPosition.PositionView) {
        guard navigationPosition !== position else { return }
        navigationPosition = position
        reportNavigationFrame()
    }

    func unbindNavigation(_ position: FocusHeroNativeScrollPosition.PositionView) {
        guard navigationPosition === position else { return }
        navigationPosition = nil
        stopNavigationFrames()
    }

    func bind(_ view: UIView, to surface: Surface) {
        let target = Target(view: view)
        targets[surface] = target
        target.offset = position(for: surface)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.setValue(target.offset, forKeyPath: "transform.translation.y")
        CATransaction.commit()
    }

    func unbind(_ view: UIView, from surface: Surface) {
        guard let target = targets[surface], target.view === view else { return }
        for key in target.keys { view.layer.removeAnimation(forKey: key) }
        targets.removeValue(forKey: surface)
    }

    func move(expanded: Bool, distance: CGFloat, animated: Bool, reduceMotion: Bool) {
        let departure = navigationProgress
        self.distance = distance
        self.offset = expanded ? distance : 0
        self.reduceMotion = reduceMotion
        sequence += 1
        let key = "plozz.hero-showcase.scroll.\(sequence)"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (surface, target) in targets {
            guard let layer = target.view?.layer else { continue }
            target.keys.removeAll { layer.animation(forKey: $0) == nil }
            let value = position(for: surface)
            let delta = value - target.offset
            target.offset = value
            layer.setValue(value, forKeyPath: "transform.translation.y")
            if animated, !reduceMotion, delta != 0 {
                let animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.fromValue = -delta
                animation.toValue = 0
                animation.isAdditive = true
                // Default start time is the shared transaction's commit, not before cold UI work.
                animation.duration = Self.duration
                animation.timingFunction = Self.timingFunction
                layer.add(animation, forKey: key)
                target.keys.append(key)
            } else if !animated || reduceMotion {
                for key in target.keys { layer.removeAnimation(forKey: key) }
                target.keys.removeAll()
            }
        }
        CATransaction.commit()
        if animated, !reduceMotion, navigationPosition != nil {
            navigationPosition?.updateNavigationOffset(distance - offset, progress: departure)
            startNavigationFrames()
        } else {
            finishNavigation()
        }
    }

    private var navigationProgress: CGFloat {
        guard distance > 0 else { return 0 }
        let position = targets[.rows]?.view?.layer.presentation()?.transform.m42 ?? offset
        return min(1, max(0, 1 - position / distance))
    }

    private var targetNavigationProgress: CGFloat { distance > 0 && offset == 0 ? 1 : 0 }

    @objc private func reportNavigationFrame() {
        guard let target = targets[.rows], let view = target.view,
              view.window != nil, navigationPosition != nil else {
            finishNavigation()
            return
        }
        let moving = target.keys.contains { view.layer.animation(forKey: $0) != nil }
        navigationPosition?.updateNavigationOffset(
            distance - offset, progress: moving ? navigationProgress : targetNavigationProgress
        )
        if moving { startNavigationFrames() } else { stopNavigationFrames() }
    }

    private func startNavigationFrames() {
        guard navigationFrames == nil else { return }
        let frames = CADisplayLink(target: self, selector: #selector(reportNavigationFrame))
        navigationFrames = frames
        frames.add(to: .main, forMode: .common)
    }

    private func stopNavigationFrames() {
        navigationFrames?.invalidate()
        navigationFrames = nil
    }

    func finishNavigation() {
        stopNavigationFrames()
        navigationPosition?.updateNavigationOffset(distance - offset, progress: targetNavigationProgress)
    }

    private func position(for surface: Surface) -> CGFloat {
        switch surface {
        // The nested foreground supplies the travel not already applied by its parent.
        case .featured: reduceMotion ? 0 : (offset - distance) * (1 - Self.backdropTravelFraction)
        case .featuredBackdrop: reduceMotion ? 0 : (offset - distance) * Self.backdropTravelFraction
        case .showcase: reduceMotion ? 0 : offset * (1 - Self.backdropTravelFraction)
        case .showcaseBackdrop: reduceMotion ? 0 : offset * Self.backdropTravelFraction
        case .rows: offset
        }
    }

    func stopAnimations() {
        finishNavigation()
        for target in targets.values {
            for key in target.keys { target.view?.layer.removeAnimation(forKey: key) }
            target.keys.removeAll()
        }
    }
}

private struct HeroShowcaseMotionKey: EnvironmentKey {
    static let defaultValue: HeroShowcaseScrollMotion? = nil
}

extension EnvironmentValues {
    var heroShowcaseMotion: HeroShowcaseScrollMotion? {
        get { self[HeroShowcaseMotionKey.self] }
        set { self[HeroShowcaseMotionKey.self] = newValue }
    }
}

struct HeroShowcaseForeground: ViewModifier {
    let surface: HeroShowcaseScrollMotion.Surface
    @Environment(\.heroShowcaseMotion) private var motion

    func body(content: Content) -> some View {
        if let motion {
            HeroShowcaseForegroundSurface(content: AnyView(content), motion: motion, surface: surface)
        } else {
            content
        }
    }
}

struct HeroShowcaseForegroundSurface: UIViewControllerRepresentable {
    let content: AnyView
    let motion: HeroShowcaseScrollMotion
    let surface: HeroShowcaseScrollMotion.Surface

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: hosted(context), motion: motion, surface: surface)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = hosted(context)
    }

    private func hosted(_ context: Context) -> AnyView {
        AnyView(content.transformEnvironment(\.self) { target in
            target.copyHostedPresentation(from: context.environment)
        })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        uiViewController.host.sizeThatFits(in: CGSize(
            width: proposal.width ?? HomeHeroLayout.screenWidth,
            height: proposal.height ?? HomeHeroLayout.screenHeight
        ))
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.motion.unbind(controller.host.view, from: controller.surface)
    }

    final class Controller: UIViewController {
        let host: UIHostingController<AnyView>
        let motion: HeroShowcaseScrollMotion
        let surface: HeroShowcaseScrollMotion.Surface

        init(content: AnyView, motion: HeroShowcaseScrollMotion, surface: HeroShowcaseScrollMotion.Surface) {
            host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            self.motion = motion
            self.surface = surface
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            addChild(host)
            host.view.backgroundColor = .clear
            view.addSubview(host.view)
            host.didMove(toParent: self)
            motion.bind(host.view, to: surface)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
            host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
    }
}

struct HeroShowcaseFeaturedContent: View {
    let state: HeroShowcaseState
    let content: (Bool) -> AnyView

    var body: some View { content(!state.isExpanded) }
}

struct HeroShowcaseReturnCue: UIViewRepresentable {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    let isActive: Bool

    func makeUIView(context: Context) -> CueView { CueView() }

    func updateUIView(_ view: CueView, context: Context) {
        view.setActive(isActive && model.activeIndex(in: rows) == 0)
    }

    static func dismantleUIView(_ view: CueView, coordinator: ()) { view.setActive(false) }

    final class CueView: UIView {
        let arrow = UIView()
        var top: CGFloat = 72 {
            didSet { if oldValue != top { setNeedsLayout() } }
        }
        private(set) var isActive = false
        private var dismissal: Task<Void, Never>?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            accessibilityIdentifier = "hero-showcase-return-cue"
            let stroke = CAShapeLayer()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2, y: 11))
            path.addLine(to: CGPoint(x: 22, y: 3))
            path.addLine(to: CGPoint(x: 42, y: 11))
            stroke.path = path.cgPath
            stroke.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
            stroke.fillColor = UIColor.clear.cgColor
            stroke.lineWidth = 5
            stroke.lineCap = .round
            stroke.lineJoin = .round
            arrow.layer.addSublayer(stroke)
            arrow.alpha = 0
            addSubview(arrow)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let viewport = window.map { convert($0.bounds, from: $0) } ?? bounds
            arrow.bounds = CGRect(x: 0, y: 0, width: 44, height: 14)
            arrow.center = CGPoint(x: viewport.midX, y: viewport.minY + top)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshVisibility()
        }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            refreshVisibility()
        }

        private func refreshVisibility() {
            dismissal?.cancel()
            dismissal = nil
            arrow.layer.removeAllAnimations()
            guard isActive, window != nil else { arrow.alpha = 0; return }
            UIView.animate(withDuration: 0.25) { self.arrow.alpha = 1 }
            dismissal = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch is CancellationError { return }
                catch {
                    PlozzLog.app.debug("Hero return cue delay failed: \(error.localizedDescription)")
                    return
                }
                guard let self, self.isActive, self.window != nil else { return }
                UIView.animate(withDuration: 0.35) { self.arrow.alpha = 0 }
                self.dismissal = nil
            }
        }
    }
}

/// Stable scene hosts scroll foregrounds together, with coordinated slower backdrops.
/// Directional handoff happens before focus commits, not through an invisible target.
struct HeroShowcaseStage: UIViewControllerRepresentable {
    let state: HeroShowcaseState
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    let hero: AnyView
    let showcase: AnyView
    let rowContent: AnyView

    func makeUIViewController(context: Context) -> Controller {
        Controller(state: state, hero: hosted(hero, context), showcase: hosted(showcase, context),
                   rows: hosted(rowContent, context))
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.updateContent(
            hero: hosted(hero, context), showcase: hosted(showcase, context), rows: hosted(rowContent, context)
        )
        controller.canReturn = { model.activeIndex(in: rows) == 0 }
        controller.canEnterRows = { rows.first.map { !$0.isPlaceholder } ?? false }
        controller.updatePeek(firstRowHeight: model.scrollOrigin(in: rows))
        state.returnToHero = { [weak controller] in controller?.resetToFeatured() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.state.returnToHero = nil
        controller.stopAnimations()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    private func hosted(_ content: AnyView, _ context: Context) -> AnyView {
        AnyView(content.transformEnvironment(\.self) { target in
            target.copyHostedPresentation(from: context.environment)
        }.environment(\.heroShowcaseMotion, state.motion))
    }

    @MainActor
    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        let state: HeroShowcaseState
        let hero: UIHostingController<AnyView>
        let showcase: UIHostingController<AnyView>
        let rows: UIHostingController<AnyView>
        var canReturn: () -> Bool = { true }
        var canEnterRows: () -> Bool = { true }
        private weak var heroTarget: (any UIFocusItem)?
        private weak var rowTarget: (any UIFocusItem)?
        private var requestingFocus = false
        private var peek: CGFloat = 0

        init(state: HeroShowcaseState, hero: AnyView, showcase: AnyView, rows: AnyView) {
            self.state = state
            self.hero = UIHostingController(rootView: Self.viewport(hero))
            self.showcase = UIHostingController(rootView: Self.viewport(showcase))
            self.rows = UIHostingController(rootView: Self.viewport(rows))
            super.init(nibName: nil, bundle: nil)
            for host in [self.hero, self.showcase, self.rows] { host.safeAreaRegions = [] }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private static func viewport(_ content: AnyView) -> AnyView {
            AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }

        func updateContent(hero: AnyView, showcase: AnyView, rows: AnyView) {
            self.hero.rootView = Self.viewport(hero)
            self.showcase.rootView = Self.viewport(showcase)
            self.rows.rootView = Self.viewport(rows)
        }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            for host in [showcase, hero, rows] {
                addChild(host)
                host.view.backgroundColor = .clear
                view.addSubview(host.view)
                host.didMove(toParent: self)
            }
            showcase.view.alpha = 0
            showcase.view.isUserInteractionEnabled = false
            showcase.view.accessibilityElementsHidden = true
            rows.view.isUserInteractionEnabled = !state.isExpanded
            rows.view.accessibilityElementsHidden = state.isExpanded
            state.motion.bind(rows.view, to: .rows)
            state.motion.bind(hero.view, to: .featuredBackdrop)
            state.motion.bind(showcase.view, to: .showcaseBackdrop)
            // A hidden destination produces no geometric focus update, and
            // SwiftUI can consume arrows before they reach pressesBegan.
            let press = BoundaryPressRecognizer()
            press.delegate = self
            press.onMove = { [weak self] heading in self?.beginBoundaryMove(heading) }
            view.addGestureRecognizer(press)
            for direction: UISwipeGestureRecognizer.Direction in [.up, .down] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                swipe.allowedPressTypes = []
                swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
                swipe.delegate = self
                view.addGestureRecognizer(swipe)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let windowFrame = view.window.map { view.convert($0.bounds, from: $0) }
            for host in [hero, showcase, rows] {
                var frame = view.bounds
                if let windowFrame {
                    if host === hero {
                        frame = Self.featuredFrame(in: view.bounds, window: windowFrame)
                    } else if host === showcase {
                        // Browse artwork is right-aligned; keep its edge on the
                        // display without moving the leading details column.
                        frame.size.width = max(frame.width, windowFrame.maxX - frame.minX)
                    }
                }
                host.view.bounds = CGRect(origin: .zero, size: frame.size)
                host.view.center = CGPoint(x: frame.midX, y: frame.midY)
            }
        }

        static func featuredFrame(in bounds: CGRect, window: CGRect) -> CGRect {
            // Rows break out at the trailing edge. The full-screen hero backdrop
            // instead needs a symmetric slot to stay centered on the physical panel.
            let inset = max(0, bounds.minX - window.minX, window.maxX - bounds.maxX)
            return CGRect(x: window.minX + inset, y: bounds.minY,
                          width: max(0, window.width - 2 * inset), height: bounds.height)
        }

        override var preferredFocusEnvironments: [UIFocusEnvironment] {
            if state.isExpanded {
                if let heroTarget, heroTarget.canBecomeFocused, hero.view.window != nil,
                   contains(heroTarget, in: hero) { return [heroTarget] }
                return [hero]
            }
            if let rowTarget, rowTarget.canBecomeFocused, rows.view.window != nil,
               contains(rowTarget, in: rows) { return [rowTarget] }
            return [rows]
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            allowsFocusUpdate(
                from: context.previouslyFocusedItem, to: context.nextFocusedItem, heading: context.focusHeading
            ) && super.shouldUpdateFocus(in: context)
        }

        func allowsFocusUpdate(
            from previous: (any UIFocusItem)?, to next: (any UIFocusItem)?, heading: UIFocusHeading
        ) -> Bool {
            // A queued handoff still owns this boundary. Only its eventual
            // non-directional focus request may bypass geometric navigation.
            let fromHero = contains(previous, in: hero)
            let fromRows = contains(previous, in: rows)
            if state.isExpanded, fromHero, heading.contains(.down),
               !contains(next, in: hero), canEnterRows() {
                heroTarget = previous
                scheduleHandoff(expanded: false)
                return false
            }
            if !state.isExpanded, fromRows, heading.contains(.up), canReturn() {
                rowTarget = previous
                scheduleHandoff(expanded: true)
                return false
            }
            return true
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            if contains(context.nextFocusedItem, in: hero) {
                heroTarget = context.nextFocusedItem
                if !state.isExpanded { present(expanded: true, focus: false) }
            } else if contains(context.nextFocusedItem, in: rows) {
                rowTarget = context.nextFocusedItem
                if state.isExpanded { present(expanded: false, focus: false) }
            }
        }

        func boundaryDestination(for heading: UIFocusHeading, from focused: (any UIFocusItem)?) -> Bool? {
            if state.isExpanded, heading == .down, canEnterRows(), contains(focused, in: hero) { return false }
            if !state.isExpanded, heading == .up, canReturn(), contains(focused, in: rows) { return true }
            return nil
        }

        func beginBoundaryMove(_ heading: UIFocusHeading) {
            let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem
            guard let expanded = boundaryDestination(for: heading, from: focused) else { return }
            if expanded { rowTarget = focused } else { heroTarget = focused }
            scheduleHandoff(expanded: expanded)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
            guard gestureRecognizer is BoundaryPressRecognizer,
                  press.type == .upArrow || press.type == .downArrow else { return false }
            let heading: UIFocusHeading = press.type == .upArrow ? .up : .down
            return boundaryDestination(
                for: heading, from: UIFocusSystem.focusSystem(for: view)?.focusedItem
            ) != nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return true }
            return boundaryDestination(
                for: swipe.direction == .up ? .up : .down,
                from: UIFocusSystem.focusSystem(for: view)?.focusedItem
            ) != nil
        }

        @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            beginBoundaryMove(recognizer.direction == .up ? .up : .down)
        }

        func contains(_ target: (any UIFocusItem)?, in host: UIViewController) -> Bool {
            guard let target else { return false }
            var controller = NativeFocusRegion.owningController(of: target)
            while let current = controller {
                if current === host { return true }
                controller = current.parent
            }
            return false
        }

        private func scheduleHandoff(expanded: Bool) {
            // Defer only past the current focus transaction; never wait for artwork
            // or for the animation to finish before admitting the destination.
            guard !requestingFocus else { return }
            requestingFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.view.window != nil else { self.requestingFocus = false; return }
                let focused = UIFocusSystem.focusSystem(for: self.view)?.focusedItem
                guard self.contains(focused, in: expanded ? self.rows : self.hero) else {
                    self.requestingFocus = false
                    return
                }
                self.present(expanded: expanded, focus: true)
                self.requestingFocus = false
            }
        }

        func updatePeek(firstRowHeight: CGFloat) {
            let next = max(0, HomeHeroLayout.screenHeight - HomeHeroLayout.rowOverlap
                           - (FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing) - firstRowHeight))
            guard abs(next - peek) > 0.5 else { return }
            peek = next
            state.motion.move(
                expanded: state.isExpanded, distance: peek, animated: false,
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            )
        }

        func present(expanded: Bool, focus: Bool) {
            let changed = state.isExpanded != expanded
            state.setExpanded(expanded)
            hero.view.isUserInteractionEnabled = expanded
            rows.view.isUserInteractionEnabled = !expanded
            hero.view.accessibilityElementsHidden = !expanded
            rows.view.accessibilityElementsHidden = expanded
            showcase.view.accessibilityElementsHidden = expanded
            let animate = changed && !UIAccessibility.isReduceMotionEnabled
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            state.motion.move(
                expanded: expanded, distance: peek, animated: animate,
                reduceMotion: UIAccessibility.isReduceMotionEnabled
            )
            dissolve(hero.view, to: expanded ? 1 : 0, animated: animate)
            dissolve(showcase.view, to: expanded ? 0 : 1, animated: animate)
            CATransaction.commit()
            if focus {
                view.layoutIfNeeded()
                guard let system = UIFocusSystem.focusSystem(for: view) else {
                    PlozzLog.app.debug("Hero Showcase focus system is unavailable")
                    return
                }
                system.requestFocusUpdate(to: self)
                system.updateFocusIfNeeded()
                if !contains(system.focusedItem, in: expanded ? hero : rows) {
                    PlozzLog.app.debug("Hero Showcase boundary focus request was not accepted")
                }
            }
        }

        func resetToFeatured() {
            rowTarget = nil
            present(expanded: true, focus: false)
        }

        private func dissolve(_ view: UIView, to alpha: CGFloat, animated: Bool) {
            let from = view.layer.presentation()?.opacity ?? view.layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.alpha = alpha
            if animated {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = from
                animation.toValue = Float(alpha)
                animation.duration = HeroShowcaseScrollMotion.duration
                animation.timingFunction = HeroShowcaseScrollMotion.timingFunction
                view.layer.add(animation, forKey: "plozz.hero-showcase.opacity")
            } else {
                view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
            }
            CATransaction.commit()
        }

        func stopAnimations() {
            state.motion.stopAnimations()
            hero.view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
            showcase.view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
        }
    }

    private final class BoundaryPressRecognizer: UIGestureRecognizer {
        var onMove: ((UIFocusHeading) -> Void)?

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = [UIPress.PressType.upArrow, .downArrow].map { NSNumber(value: $0.rawValue) }
            allowedTouchTypes = []
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard let press = presses.first else { state = .failed; return }
            state = .began
            onMove?(press.type == .upArrow ? .up : .down)
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .ended }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .cancelled }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
#endif
