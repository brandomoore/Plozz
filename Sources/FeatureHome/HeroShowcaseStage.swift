#if os(tvOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class HeroShowcaseState {
    private(set) var isExpanded = true
    @ObservationIgnored var returnToHero: (() -> Void)?

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }
}

struct HeroShowcaseFeaturedContent: View {
    let state: HeroShowcaseState
    let content: (Bool) -> AnyView

    var body: some View { content(!state.isExpanded) }
}

struct HeroShowcaseReturnCue: View {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    let navigationStyle: NavigationStyle

    var body: some View {
        Label("Featured", systemImage: "chevron.up")
            .font(.system(size: 20, weight: .medium))
            .plozzForeground(.secondary)
            .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
            .padding(.top, max(16, FocusHeroLayout.columnTop(for: navigationStyle) - 38))
            .opacity(model.activeIndex(in: rows) == 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(model.activeIndex(in: rows) != 0)
            .accessibilityIdentifier("hero-showcase-return-cue")
    }
}

/// Three stable hosts: only the row viewport moves; the two artwork planes dissolve.
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
        controller.hero.rootView = hosted(hero, context)
        controller.showcase.rootView = hosted(showcase, context)
        controller.rows.rootView = hosted(rowContent, context)
        controller.canReturn = { model.activeIndex(in: rows) == 0 }
        controller.canEnterRows = { !rows.isEmpty }
        controller.updatePeek(firstRowHeight: model.scrollOrigin(in: rows))
        state.returnToHero = { [weak controller] in controller?.resetToFeatured() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.state.returnToHero = nil
        controller.stopAnimations()
    }

    private func hosted(_ content: AnyView, _ context: Context) -> AnyView {
        AnyView(content.transformEnvironment(\.self) { target in
            target.copyHostedPresentation(from: context.environment)
        })
    }

    @MainActor
    final class Controller: UIViewController {
        let state: HeroShowcaseState
        let hero: UIHostingController<AnyView>
        let showcase: UIHostingController<AnyView>
        let rows: UIHostingController<AnyView>
        var canReturn: () -> Bool = { true }
        var canEnterRows: () -> Bool = { true }
        private weak var heroTarget: UIView?
        private weak var rowTarget: UIView?
        private var requestingFocus = false
        private var peek: CGFloat = 0
        private var translation: CGFloat = 0
        private var sequence = 0
        private var motionKeys: [String] = []

        init(state: HeroShowcaseState, hero: AnyView, showcase: AnyView, rows: AnyView) {
            self.state = state
            self.hero = UIHostingController(rootView: hero)
            self.showcase = UIHostingController(rootView: showcase)
            self.rows = UIHostingController(rootView: rows)
            super.init(nibName: nil, bundle: nil)
            for host in [self.hero, self.showcase, self.rows] { host.safeAreaRegions = [] }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            for host in [hero, showcase, rows] {
                host.view.bounds = view.bounds
                host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            }
        }

        override var preferredFocusEnvironments: [UIFocusEnvironment] {
            if state.isExpanded {
                if let heroTarget, heroTarget.window != nil { return [heroTarget] }
                return [hero]
            }
            if let rowTarget, rowTarget.window != nil { return [rowTarget] }
            return [rows]
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            guard !requestingFocus else { return true }
            let fromHero = contains(context.previouslyFocusedView, in: hero)
            let fromRows = contains(context.previouslyFocusedView, in: rows)
            if state.isExpanded, fromHero, context.focusHeading.contains(.down),
               !contains(context.nextFocusedView, in: hero), canEnterRows() {
                heroTarget = context.previouslyFocusedView
                scheduleHandoff(expanded: false)
                return false
            }
            if !state.isExpanded, fromRows, context.focusHeading.contains(.up), canReturn() {
                rowTarget = context.previouslyFocusedView
                scheduleHandoff(expanded: true)
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            if contains(context.nextFocusedView, in: hero) {
                heroTarget = context.nextFocusedView
                if !state.isExpanded { present(expanded: true, focus: false) }
            } else if contains(context.nextFocusedView, in: rows) {
                rowTarget = context.nextFocusedView
                if state.isExpanded { present(expanded: false, focus: false) }
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
            if !state.isExpanded, canReturn(), contains(focused, in: rows),
               presses.contains(where: { $0.type == .upArrow }) {
                rowTarget = focused
                scheduleHandoff(expanded: true)
                return
            }
            super.pressesBegan(presses, with: event)
        }

        private func contains(_ target: UIView?, in host: UIViewController) -> Bool {
            target.map { $0.isDescendant(of: host.view) } ?? false
        }

        private func scheduleHandoff(expanded: Bool) {
            // Defer only past the current focus transaction; never wait for artwork
            // or for the animation to finish before admitting the destination.
            guard !requestingFocus else { return }
            requestingFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.view.window != nil else { self.requestingFocus = false; return }
                let focused = UIFocusSystem.focusSystem(for: self.view)?.focusedItem as? UIView
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
            if state.isExpanded { moveRows(to: peek, animated: false) }
        }

        func present(expanded: Bool, focus: Bool) {
            let changed = state.isExpanded != expanded
            state.setExpanded(expanded)
            hero.view.isUserInteractionEnabled = expanded
            hero.view.accessibilityElementsHidden = !expanded
            showcase.view.accessibilityElementsHidden = expanded
            let animate = changed && !UIAccessibility.isReduceMotionEnabled
            moveRows(to: expanded ? peek : 0, animated: animate)
            dissolve(hero.view, to: expanded ? 1 : 0, animated: animate)
            dissolve(showcase.view, to: expanded ? 0 : 1, animated: animate)
            if focus {
                view.layoutIfNeeded()
                let system = UIFocusSystem.focusSystem(for: view)
                system?.requestFocusUpdate(to: self)
                system?.updateFocusIfNeeded()
            }
        }

        func resetToFeatured() {
            rowTarget = nil
            present(expanded: true, focus: false)
        }

        private func moveRows(to value: CGFloat, animated: Bool) {
            let layer = rows.view.layer
            motionKeys.removeAll { layer.animation(forKey: $0) == nil }
            let delta = value - translation
            translation = value
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: "transform.translation.y")
            if animated, delta != 0 {
                let spring = FocusHeroLayout.rowSpring
                let animation = CASpringAnimation(keyPath: "transform.translation.y")
                animation.mass = spring.mass
                animation.stiffness = spring.stiffness
                animation.damping = spring.damping
                animation.fromValue = -delta
                animation.toValue = 0
                animation.isAdditive = true
                animation.duration = spring.settlingDuration
                sequence += 1
                let key = "plozz.hero-showcase.rows.\(sequence)"
                layer.add(animation, forKey: key)
                motionKeys.append(key)
            } else if !animated {
                for key in motionKeys { layer.removeAnimation(forKey: key) }
                motionKeys.removeAll()
            }
            CATransaction.commit()
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
                animation.duration = FocusHeroLayout.rowSpringDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.layer.add(animation, forKey: "plozz.hero-showcase.opacity")
            } else {
                view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
            }
            CATransaction.commit()
        }

        func stopAnimations() {
            for key in motionKeys { rows.view.layer.removeAnimation(forKey: key) }
            motionKeys.removeAll()
            hero.view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
            showcase.view.layer.removeAnimation(forKey: "plozz.hero-showcase.opacity")
        }
    }
}
#endif
