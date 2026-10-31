#if canImport(SwiftUI)
import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// How far the page's content has been pushed in from the leading edge to make
/// room for the custom navigation rail, in points. `0` under horizontal navigation
/// and the native sidebar, which need no leading content inset.
///
/// ### Why this exists
/// The rail insets **content** — a hero's title/overview/buttons, a row header,
/// a poster grid — because those must never sit under the navigation. It must NOT
/// inset **full-bleed artwork**: a hero backdrop is meant to run to the physical
/// screen edge, and letting the inset narrow it leaves a dead band down the side
/// of the picture.
///
/// SwiftUI's usual tool for that split is `safeAreaPadding` plus `ignoresSafeArea`,
/// which does not work here. The page is a `NavigationStack` that manages its own
/// safe area, so a safe-area inset applied by the shell never reaches the surfaces
/// inside it — changing the amount moved nothing at all. Publishing the number and
/// letting each surface apply REAL padding to its own content is what actually
/// works, and it keeps artwork out of it by construction.
private struct PlozzNavigationContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct PlozzTopNavigationContentInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

private struct PlozzTopNavigationScrollKey: EnvironmentKey {
    static let defaultValue: TopNavigationScroll? = nil
}

/// The root scroll owner moves the custom top bar; detail chrome remains independent.
@MainActor @Observable
public final class TopNavigationScroll {
    public struct StageTransition: Equatable {
        public let offset: CGFloat
        public let progress: CGFloat

        public init(offset: CGFloat, progress: CGFloat) {
            self.offset = offset
            self.progress = min(1, max(0, progress))
        }
    }

    public private(set) var offset: CGFloat = 0
    public private(set) var stageTransition: StageTransition?
    @ObservationIgnored private var source: UUID?
    @ObservationIgnored private var reset: (() -> Void)?
    #if os(tvOS)
    @ObservationIgnored private weak var motionView: UIView?
    @ObservationIgnored private var maximumMotionOffset: CGFloat = 0
    @ObservationIgnored private var motionKeys: [String] = []
    #endif

    public init() {}

    public func register(source: UUID, offset: CGFloat, scrollToTop: @escaping () -> Void) {
        self.source = source
        reset = scrollToTop
        self.offset = max(0, offset)
        stageTransition = nil
        applyMotion(resetAnimations: true)
    }

    public func update(offset: CGFloat, source: UUID, stageTransition: StageTransition? = nil) {
        guard self.source == source else { return }
        self.offset = max(0, offset)
        self.stageTransition = stageTransition
        applyMotion()
    }

    public func visibleOffset(maximum: CGFloat) -> CGFloat {
        guard let stageTransition else { return min(offset, maximum) }
        let rows = max(0, offset - stageTransition.offset)
        return min(maximum, rows + maximum * stageTransition.progress)
    }

    public func unregister(source: UUID) {
        guard self.source == source else { return }
        self.source = nil
        reset = nil
        offset = 0
        stageTransition = nil
        applyMotion(resetAnimations: true)
    }

    /// Returns whether content moved, so navigation can discard its old deep-row focus.
    @discardableResult
    public func scrollToTop() -> Bool {
        guard offset > 0, let reset else { return false }
        reset()
        offset = 0
        stageTransition = nil
        applyMotion(resetAnimations: true)
        return true
    }

    #if os(tvOS)
    public func bindMotionView(_ view: UIView, maximumOffset: CGFloat) {
        if let previous = motionView, previous !== view { unbindMotionView(previous) }
        motionView = view
        maximumMotionOffset = maximumOffset
        applyMotion()
    }

    public func unbindMotionView(_ view: UIView) {
        guard motionView === view else { return }
        for key in motionKeys { view.layer.removeAnimation(forKey: key) }
        motionKeys.removeAll()
        motionView = nil
    }

    /// Add to the feature's current animation transaction; no per-frame SwiftUI updates.
    public func animateStage(
        from progress: CGFloat, duration: TimeInterval, timingFunction: CAMediaTimingFunction,
        key: String, source: UUID
    ) {
        guard self.source == source, let layer = motionView?.layer else { return }
        motionKeys.removeAll { layer.animation(forKey: $0) == nil }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = -progress * maximumMotionOffset
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = duration
        animation.timingFunction = timingFunction
        layer.add(animation, forKey: key)
        motionKeys.append(key)
    }

    public func stopStageAnimations(source: UUID) {
        guard self.source == source else { return }
        applyMotion(resetAnimations: true)
    }
    #endif

    private func applyMotion(resetAnimations: Bool = false) {
        #if os(tvOS)
        guard let layer = motionView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(-visibleOffset(maximum: maximumMotionOffset), forKeyPath: "transform.translation.y")
        if resetAnimations {
            for key in motionKeys { layer.removeAnimation(forKey: key) }
            motionKeys.removeAll()
        }
        CATransaction.commit()
        #endif
    }
}

private struct PlozzPinnedSidebarActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PlozzPinnedSidebarInteractionKey: EnvironmentKey {
    static let defaultValue: PlozzPinnedSidebarInteraction? = nil
}

/// Coordinates focus-sensitive interactions between page content and the custom
/// pinned sidebar without coupling feature modules to AppShell.
public final class PlozzPinnedSidebarInteraction: ObservableObject {
    @Published public private(set) var heroHasFocus = false
    @Published public private(set) var searchResultsHaveFocus = false
    @Published public private(set) var openRequest = 0

    public init() {}

    @MainActor
    public func setHeroFocused(_ focused: Bool) {
        heroHasFocus = focused
    }

    @MainActor
    public func setSearchResultsFocused(_ focused: Bool) {
        guard searchResultsHaveFocus != focused else { return }
        searchResultsHaveFocus = focused
    }

    @MainActor
    public func requestOpen() {
        #if os(tvOS)
        guard !DetailTransitionNavigation.isNavigationInputSuppressed else { return }
        #endif
        openRequest &+= 1
    }
}

public extension EnvironmentValues {
    /// The leading inset the navigation chrome has applied to page content.
    var plozzNavigationContentInset: CGFloat {
        get { self[PlozzNavigationContentInsetKey.self] }
        set { self[PlozzNavigationContentInsetKey.self] = newValue }
    }

    /// Bottom edge and horizontal content keylines of the custom top navigation,
    /// measured from the physical screen edges.
    /// Full-bleed surfaces inset browsing controls, not their artwork or player.
    var plozzTopNavigationContentInsets: EdgeInsets {
        get { self[PlozzTopNavigationContentInsetsKey.self] }
        set { self[PlozzTopNavigationContentInsetsKey.self] = newValue }
    }

    var plozzTopNavigationScroll: TopNavigationScroll? {
        get { self[PlozzTopNavigationScrollKey.self] }
        set { self[PlozzTopNavigationScrollKey.self] = newValue }
    }

    /// Whether Plozz's custom pinned sidebar owns the surrounding shell.
    ///
    /// Separate from the live inset because the sidebar publishes inset 0 while
    /// hidden behind a detail page, but branch-specific drawing behavior must stay
    /// stable until the navigation style itself changes.
    var plozzPinnedSidebarActive: Bool {
        get { self[PlozzPinnedSidebarActiveKey.self] }
        set { self[PlozzPinnedSidebarActiveKey.self] = newValue }
    }

    /// Focus coordination available only inside Plozz's custom pinned-sidebar shell.
    var plozzPinnedSidebarInteraction: PlozzPinnedSidebarInteraction? {
        get { self[PlozzPinnedSidebarInteractionKey.self] }
        set { self[PlozzPinnedSidebarInteractionKey.self] = newValue }
    }
}

public extension View {
    /// Apply to a root vertical ScrollView, not a detail page or horizontal media row.
    func scrollsTopNavigation(onReturnToTop: @escaping () -> Void = {}) -> some View {
        modifier(TopNavigationRootScroll(onReturnToTop: onReturnToTop))
    }
}

private struct TopNavigationRootScroll: ViewModifier {
    let onReturnToTop: () -> Void
    @Environment(\.plozzTopNavigationScroll) private var navigation
    @State private var position = ScrollPosition()
    @State private var source = Source()

    private final class Source {
        let id = UUID()
        var offset: CGFloat = 0
    }

    @ViewBuilder func body(content: Content) -> some View {
        if let navigation {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self) {
                    max(0, $0.contentOffset.y + $0.contentInsets.top)
                } action: { _, offset in
                    source.offset = offset
                    navigation.update(offset: offset, source: source.id)
                }
                .onAppear {
                    let binding = $position
                    navigation.register(source: source.id, offset: source.offset) {
                        onReturnToTop()
                        binding.wrappedValue.scrollTo(edge: .top)
                    }
                }
                .onDisappear {
                    navigation.unregister(source: source.id)
                }
        } else {
            content
        }
    }
}

#endif
