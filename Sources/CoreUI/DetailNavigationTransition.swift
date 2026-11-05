import CoreModels
import Foundation
import SwiftUI

public enum DetailEntranceStage: Int, Comparable, Sendable {
    case artwork, logo, metadata, controls, episodes, complete

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DetailEntranceTiming: Equatable, Sendable {
    public var zoom: TimeInterval = 0.4
    public var artworkPause: TimeInterval = 0.10
    public var stagger: TimeInterval = 0.09
    public var reveal: TimeInterval = 0.45
    public var episodeReveal: TimeInterval = 0.72
    public var reverse: TimeInterval = 0.28

    public init() {}
}

enum DetailEntranceMotion {
    static let pickup = UnitPoint(x: 0.22, y: 0.64)
    static let landing = UnitPoint(x: 0.30, y: 1)
    static let foregroundTravel: CGFloat = 10
    static let episodeTravel: CGFloat = 48

    static func reveal(duration: TimeInterval) -> Animation {
        .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    }

    static func episodeReveal(duration: TimeInterval) -> Animation {
        .timingCurve(0.32, 0, 0.20, 1, duration: duration)
    }
}

@MainActor
public func withCinematicDetailNavigation(for item: MediaItem, _ navigate: () -> Void) {
    #if os(tvOS)
    DetailTransitionNavigation.prepare(for: item)
    DetailTransitionNavigation.preloadBackdrop(for: item)
    DetailTransitionNavigation.performNavigation(navigate)
    #else
    navigate()
    #endif
}

public extension View {
    @ViewBuilder
    func detailNavigationZoom(isEnabled: Bool) -> some View {
        #if os(tvOS)
        environment(\.detailZoomEnabled, isEnabled)
            .background { DetailZoomPreferenceAnchor(isEnabled: isEnabled) }
        #else
        self
        #endif
    }

    @MainActor
    func cinematicDetailNavigation(path: Binding<NavigationPath>) -> some View {
        environment(\.detailNavigationPop, {
            guard !path.wrappedValue.isEmpty else { return false }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            path.transaction(transaction).wrappedValue.removeLast()
            return true
        })
    }

    @MainActor
    func cinematicDetailNavigation<Path: RangeReplaceableCollection>(
        path: Binding<Path>
    ) -> some View where Path: MutableCollection & RandomAccessCollection, Path.Element: Hashable {
        environment(\.detailNavigationPop, {
            guard !path.wrappedValue.isEmpty else { return false }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            path.transaction(transaction).wrappedValue.removeLast()
            return true
        })
    }

    @ViewBuilder
    func cinematicDetailPage(
        isEnabled: Bool, waitsForBackdrop: Bool = false, revealsEpisodesLast: Bool = false
    ) -> some View {
        #if os(tvOS)
        modifier(TVDetailPageTransition(
            isEnabled: isEnabled, waitsForBackdrop: waitsForBackdrop,
            revealsEpisodesLast: revealsEpisodesLast
        ))
        #else
        self
        #endif
    }

    @ViewBuilder
    func detailEntranceStage(_ stage: DetailEntranceStage) -> some View {
        #if os(tvOS)
        modifier(TVDetailStageReveal(stage: stage))
        #else
        self
        #endif
    }
}

private struct DetailNavigationPopKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Bool)? = nil
}

extension EnvironmentValues {
    var detailNavigationPop: (@MainActor () -> Bool)? {
        get { self[DetailNavigationPopKey.self] }
        set { self[DetailNavigationPopKey.self] = newValue }
    }
}

#if os(tvOS)
import CoreNetworking
import Observation
import UIKit
import TVUIKit

private struct DetailZoomEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var detailZoomEnabled: Bool {
        get { self[DetailZoomEnabledKey.self] }
        set { self[DetailZoomEnabledKey.self] = newValue }
    }
}

private struct DetailZoomPreferenceAnchor: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> Marker {
        let marker = Marker()
        marker.isUserInteractionEnabled = false
        marker.accessibilityElementsHidden = true
        return marker
    }

    func updateUIView(_ marker: Marker, context: Context) {
        marker.isEnabled = isEnabled
        marker.connect()
    }

    static func dismantleUIView(_ marker: Marker, coordinator: ()) {
        marker.disconnect()
    }

    final class Marker: UIView {
        var isEnabled = false
        private let token = UUID()
        private weak var registeredWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        func connect() {
            guard let window else {
                disconnect()
                return
            }
            if registeredWindow !== window { disconnect() }
            registeredWindow = window
            DetailTransitionNavigation.registerZoom(isEnabled, in: window, token: token)
        }

        func disconnect() {
            if let registeredWindow {
                DetailTransitionNavigation.unregisterZoom(in: registeredWindow, token: token)
            }
            registeredWindow = nil
        }
    }
}

public struct DetailTransitionArtworkLayout: Equatable {
    public let frame: CGRect
    public let intrinsicSize: CGSize

    public init(frame: CGRect, intrinsicSize: CGSize) {
        self.frame = frame
        self.intrinsicSize = intrinsicSize
    }
}

public extension View {
    /// Measure the clipped artwork slot, not an aspect-fill image overflowing it.
    func recordDetailTransitionArtwork(_ reference: DetailTransitionSourceReference) -> some View {
        modifier(DetailArtworkTracking(reference: reference))
    }
}

private struct DetailArtworkTracking: ViewModifier {
    let reference: DetailTransitionSourceReference
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        if style.usesSystemEffect {
            content.background { NativeArtworkAnchor(reference: reference) }
        } else {
            content.onGeometryChange(for: DetailTransitionArtworkLayout.self) {
                DetailTransitionArtworkLayout(
                    frame: $0.frame(in: .named(reference.coordinateSpace)), intrinsicSize: $0.size
                )
            } action: {
                reference.recordArtworkFrame($0.frame, intrinsicSize: $0.intrinsicSize)
            }
        }
    }
}

private struct NativeArtworkAnchor: UIViewRepresentable {
    let reference: DetailTransitionSourceReference

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        reference.nativeArtworkView = view
    }
}

struct DetailTransitionSourceGeometry: Equatable {
    let frame: CGRect
    let cornerRadius: CGFloat
}

@MainActor
protocol DetailTransitionFocusRequesting: AnyObject {
    func requestFocus() -> Bool
}

/// Weak, per-card geometry. Images are captured only when the card is selected.
@MainActor
public final class DetailTransitionSourceReference {
    public let coordinateSpace = UUID()
    weak var view: UIView?
    weak var nativeArtworkView: UIView?
    var itemKey = ""
    var artworkPolicy: ArtworkPresentationPolicy?
    var cornerRadius: CGFloat = 0
    var isFocused: Bool?
    weak var focusRequester: (any DetailTransitionFocusRequesting)?
    private var artworkFrame: CGRect?
    private var intrinsicArtworkSize: CGSize?

    public init() {}

    public func recordArtworkFrame(_ frame: CGRect, intrinsicSize: CGSize? = nil) {
        artworkFrame = frame
        intrinsicArtworkSize = intrinsicSize
    }

    public func prepare(for item: MediaItem) {
        guard let window = view?.window else { return }
        DetailTransitionNavigation.prepare(for: item, in: window, source: self)
    }

    func visibleFrame(in window: UIWindow) -> CGRect? {
        guard let view = nativeArtworkView ?? view, view.window === window, !view.bounds.isEmpty else { return nil }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return nil }
            ancestor = current.superview
        }
        let frame: CGRect
        if nativeArtworkView != nil {
            guard let projected = NativeFocusProjection.artworkFrame(of: view, in: window) else {
                PlozzLog.app.debug("Native artwork projection is unavailable for the detail transition")
                return nil
            }
            frame = projected
        } else {
            frame = view.convert(nativeArtworkView == nil ? artworkFrame ?? view.bounds : view.bounds, to: window)
        }
        guard frame.width > 1, frame.height > 1, !frame.isInfinite, !frame.isNull,
              window.bounds.intersection(frame).width >= frame.width * 0.9,
              window.bounds.intersection(frame).height >= frame.height * 0.9 else { return nil }
        return frame
    }

    func geometry(in window: UIWindow) -> DetailTransitionSourceGeometry? {
        guard let frame = visibleFrame(in: window) else { return nil }
        let unscaledWidth = nativeArtworkView?.bounds.width ?? intrinsicArtworkSize?.width ?? view?.bounds.width ?? frame.width
        let scale = unscaledWidth > 0 ? frame.width / unscaledWidth : 1
        return DetailTransitionSourceGeometry(frame: frame, cornerRadius: cornerRadius * scale)
    }

    static func liveSource(
        in window: UIWindow, itemKey: String,
        scrollContext: UIScrollView?, near frame: CGRect?
    ) -> DetailTransitionSourceReference? {
        var candidates: [(reference: DetailTransitionSourceReference, frame: CGRect)] = []
        var pending = [window.rootViewController?.viewIfLoaded].compactMap { $0 }
        while let view = pending.popLast() {
            if let marker = view as? DetailTransitionSourceView,
               let reference = marker.reference, reference.itemKey == itemKey,
               (scrollContext.map { marker.isDescendant(of: $0) } ?? true),
               let visible = reference.visibleFrame(in: window) {
                candidates.append((reference, visible))
            }
            pending.append(contentsOf: view.subviews)
        }
        guard let frame else { return candidates.count == 1 ? candidates[0].reference : nil }
        return candidates.min {
            hypot($0.frame.midX - frame.midX, $0.frame.midY - frame.midY)
                < hypot($1.frame.midX - frame.midX, $1.frame.midY - frame.midY)
        }?.reference
    }

    func restoreFocus(in window: UIWindow, preferred: (any UIFocusEnvironment)?) {
        guard let frame = visibleFrame(in: window), let view else { return }
        // Synchronize the owning SwiftUI focus scope even if UIKit has already
        // restored the control; otherwise a later scope update can replace it.
        if focusRequester?.requestFocus() == true {
            return
        }
        let system = UIFocusSystem.focusSystem(for: window)
        var nativeOwner = nativeArtworkView?.superview
        while let current = nativeOwner {
            if current is TVLockupView, current.canBecomeFocused {
                system?.requestFocusUpdate(to: current)
                system?.updateFocusIfNeeded()
                let focused = system?.focusedItem.flatMap { TVNavigationExitProtectionFocus.containingView(of: $0) }
                if current.isFocused || focused?.isDescendant(of: current) == true { return }
                break
            }
            nativeOwner = current.superview
        }
        if let preferred = preferred as? any UIFocusItem, preferred.canBecomeFocused,
           TVNavigationExitProtectionFocus.containingView(of: preferred)?.window === window {
            system?.requestFocusUpdate(to: preferred)
            system?.updateFocusIfNeeded()
            return
        }
        // Lazy rows may recreate the original focus proxy while details are open.
        // Resolve the current card by its live artwork rectangle, not an old index.
        var ancestor: UIView? = view
        while let current = ancestor {
            if let container = current.focusItemContainer {
                let query = container.coordinateSpace.convert(frame, from: window)
                let target = container.focusItems(in: query).first { item in
                    guard item.canBecomeFocused else { return false }
                    let candidate = window.convert(item.frame, from: container.coordinateSpace)
                    let overlap = candidate.intersection(frame)
                    return !overlap.isNull && candidate.width <= frame.width * 1.5
                        && candidate.height <= frame.height * 2
                        && overlap.width * overlap.height >= frame.width * frame.height * 0.8
                }
                if let target {
                    system?.requestFocusUpdate(to: target)
                    system?.updateFocusIfNeeded()
                    return
                }
            }
            ancestor = current.superview
        }
    }
}

public struct DetailTransitionSourceAnchor: UIViewRepresentable {
    private let reference: DetailTransitionSourceReference
    private let itemKey: String
    private let cornerRadius: CGFloat
    private let isFocused: Bool?
    private let focus: FocusState<Bool>.Binding?
    private let cardFocus: PlozzCardFocus.Binding?

    public init(
        reference: DetailTransitionSourceReference, itemKey: String,
        cornerRadius: CGFloat, isFocused: Bool? = nil, focus: FocusState<Bool>.Binding? = nil,
        cardFocus: PlozzCardFocus.Binding? = nil
    ) {
        self.reference = reference
        self.itemKey = itemKey
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
        self.focus = focus
        self.cardFocus = cardFocus
    }

    public final class Coordinator: DetailTransitionFocusRequesting {
        var focus: FocusState<Bool>.Binding?
        var cardFocus: PlozzCardFocus.Binding?

        func requestFocus() -> Bool {
            if let cardFocus {
                if cardFocus.usesNativeFocus, cardFocus.isFocused,
                   !cardFocus.request.wrappedValue.wantsFocus {
                    cardFocus.focusState.wrappedValue = true
                } else {
                    cardFocus.requestFocus(animated: false)
                }
                return true
            }
            guard let focus else { return false }
            focus.wrappedValue = true
            return true
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIView {
        let view = DetailTransitionSourceView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        reference.view = view
        reference.itemKey = itemKey
        reference.artworkPolicy = context.environment.plozzArtworkPolicy.forArea(.details)
        reference.cornerRadius = cornerRadius
        reference.isFocused = isFocused
        context.coordinator.focus = focus
        context.coordinator.cardFocus = cardFocus
        reference.focusRequester = context.coordinator
        (view as? DetailTransitionSourceView)?.reference = reference
    }
}

final class DetailTransitionSourceView: UIView {
    weak var reference: DetailTransitionSourceReference?
}

@MainActor
public enum DetailTransitionNavigation {
    private static var pending: [ObjectIdentifier: PendingDetailEntrance] = [:]
    private static var suppressed: [ObjectIdentifier: UUID] = [:]
    private static var restoring: [ObjectIdentifier: (token: UUID, session: TVDetailEntranceSession)] = [:]
    private static let inputEpochs = NSMapTable<UIWindow, NSNumber>.weakToStrongObjects()
    private static let chromeRegistrations = NSMapTable<UIWindow, ChromeRegistration>.weakToStrongObjects()
    private static let zoomRegistrations = NSMapTable<UIWindow, ZoomRegistration>.weakToStrongObjects()

    private final class ZoomRegistration {
        let isEnabled: Bool
        let token: UUID

        init(isEnabled: Bool, token: UUID) {
            self.isEnabled = isEnabled
            self.token = token
        }
    }

    static func isZoomEnabled(in window: UIWindow) -> Bool {
        zoomRegistrations.object(forKey: window)?.isEnabled == true
    }

    static func registerZoom(_ isEnabled: Bool, in window: UIWindow, token: UUID) {
        let previous = zoomRegistrations.object(forKey: window)
        guard previous?.token != token || previous?.isEnabled != isEnabled else { return }
        zoomRegistrations.setObject(ZoomRegistration(isEnabled: isEnabled, token: token), forKey: window)
        if !isEnabled { cancelPreparedZoom(in: window) }
    }

    static func unregisterZoom(in window: UIWindow, token: UUID) {
        guard zoomRegistrations.object(forKey: window)?.token == token else { return }
        zoomRegistrations.removeObject(forKey: window)
        cancelPreparedZoom(in: window)
    }

    private static func cancelPreparedZoom(in window: UIWindow) {
        let key = ObjectIdentifier(window)
        pending.removeValue(forKey: key)?.discard()
        suppressed.removeValue(forKey: key)
        restoring[key]?.session.finishImmediately()
    }

    private final class ChromeRegistration {
        weak var chrome: NavigationChromeModel?
        let token: UUID
        init(chrome: NavigationChromeModel, token: UUID) {
            self.chrome = chrome
            self.token = token
        }
    }

    static func registerChrome(_ chrome: NavigationChromeModel, in window: UIWindow, token: UUID) {
        let existing = chromeRegistrations.object(forKey: window)
        if existing?.token != token || existing?.chrome !== chrome {
            chromeRegistrations.setObject(ChromeRegistration(chrome: chrome, token: token), forKey: window)
        }
        refreshChromeInput(in: window)
    }

    static func unregisterChrome(in window: UIWindow, token: UUID) {
        guard let registration = chromeRegistrations.object(forKey: window), registration.token == token else { return }
        chromeRegistrations.removeObject(forKey: window)
        registration.chrome?.updateTransitionInput(suppressesFocus: false, hidesRail: false)
    }

    static func chromeModel(in window: UIWindow) -> NavigationChromeModel? {
        chromeRegistrations.object(forKey: window)?.chrome
    }

    static func refreshChromeInput(in window: UIWindow) {
        let guards = (window.gestureRecognizers ?? []).compactMap { $0 as? DetailTransitionInputGuard }
            .filter(\.isEnabled)
        chromeModel(in: window)?.updateTransitionInput(
            suppressesFocus: !guards.isEmpty,
            hidesRail: guards.contains { $0.phase == .opening }
        )
    }

    public static var isNavigationInputSuppressed: Bool {
        activeWindow.map { navigationInputEpoch(in: $0) == nil } ?? false
    }

    static func allowsFocusUpdate(heading: UIFocusHeading, in view: UIView) -> Bool {
        heading.isEmpty || navigationInputEpoch(in: view) != nil
    }

    /// Passive navigation observers must reject consumed input as well as
    /// checks queued before a transition changed the window's focus scope.
    public static func navigationInputEpoch(in view: UIView?) -> UInt64? {
        guard let window = (view as? UIWindow) ?? view?.window else { return nil }
        guard !(window.gestureRecognizers ?? []).contains(where: {
            $0 is DetailTransitionInputGuard && $0.isEnabled
        }) else { return nil }
        return inputEpochs.object(forKey: window)?.uint64Value ?? 0
    }

    static func installInputGuard(
        in window: UIWindow, phase: DetailTransitionInputGuard.Phase = .opening
    ) -> DetailTransitionInputGuard {
        let epoch = (inputEpochs.object(forKey: window)?.uint64Value ?? 0) &+ 1
        inputEpochs.setObject(NSNumber(value: epoch), forKey: window)
        let guardView = DetailTransitionInputGuard(phase: phase)
        window.addGestureRecognizer(guardView)
        refreshChromeInput(in: window)
        return guardView
    }

    public static var isRestoringSourcePage: Bool {
        activeWindow.map { restoring[ObjectIdentifier($0)] != nil } ?? false
    }

    static func beginSourceRestore(in window: UIWindow, token: UUID, session: TVDetailEntranceSession) {
        let key = ObjectIdentifier(window)
        if let previous = restoring[key], previous.token != token { previous.session.finishImmediately() }
        // The dismissed SwiftUI page can die before the artwork animation ends.
        restoring[key] = (token, session)
    }

    static func endSourceRestore(token: UUID) {
        if let key = restoring.first(where: { $0.value.token == token })?.key {
            restoring.removeValue(forKey: key)
        }
    }

    static func performNavigation(_ navigate: () -> Void) {
        guard let window = activeWindow, isZoomEnabled(in: window),
              pending[ObjectIdentifier(window)] != nil else {
            navigate()
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, navigate)
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    /// The central routers call this too, covering More Info and non-card links.
    public static func prepare(
        for item: MediaItem, artworkSnapshot: UIImage? = nil, preservingVideo: Bool = false
    ) {
        guard let window = activeWindow else { return }
        prepare(for: item, in: window, source: nil, artworkSnapshot: artworkSnapshot, preservingVideo: preservingVideo)
    }

    /// A system Play route may push details underneath its player, without an entrance.
    public static func suppressNextEntranceForPlayback() {
        guard let window = activeWindow else { return }
        suppressNextEntrance(in: window)
    }

    static func suppressNextEntrance(in window: UIWindow) {
        guard isZoomEnabled(in: window) else { return }
        let key = ObjectIdentifier(window)
        let token = UUID()
        pending.removeValue(forKey: key)?.discard()
        suppressed[key] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if suppressed[key] == token { suppressed.removeValue(forKey: key) }
        }
    }

    static func consumesSuppression(in window: UIWindow) -> Bool {
        suppressed.removeValue(forKey: ObjectIdentifier(window)) != nil
    }

    static func prepare(
        for item: MediaItem, in window: UIWindow, source: DetailTransitionSourceReference?,
        artworkSnapshot: UIImage? = nil, preservingVideo: Bool = false
    ) {
        guard isZoomEnabled(in: window), !UIAccessibility.isReduceMotionEnabled,
              [.movie, .series, .episode, .season].contains(item.kind) else { return }
        let key = ObjectIdentifier(window)
        guard suppressed[key] == nil else { return }
        if let existing = pending[key], existing.itemKey == item.stablePresentationID {
            if preservingVideo { existing.preserveVideo() }
            return
        }
        pending.removeValue(forKey: key)?.discard()
        let screen = preservingVideo ? DetailTransitionSurface()
            : artworkSnapshot.map(DetailTransitionSurface.init(image:))
                ?? DetailTransitionSnapshot.surface(of: window)
        let geometry = source?.geometry(in: window)
        let frame = geometry?.frame
        let card = preservingVideo ? nil : frame.map { DetailTransitionSnapshot.surface(of: window, frame: $0) }
        let entry = PendingDetailEntrance(
            window: window, itemKey: item.stablePresentationID,
            source: card == nil ? nil : source, card: card, sourceFrame: frame,
            sourceCornerRadius: geometry?.cornerRadius ?? 0, screen: screen
        )
        pending[key] = entry
        if preservingVideo {
            entry.preserveVideo()
        } else {
            entry.overlay.destination.image = source?.artworkPolicy.flatMap {
                cachedDestinationArtwork(for: item, policy: $0)
            }
        }
        entry.start()
        // A direct-play route must never leave a prepared navigation cover behind.
        entry.expiry = Task { @MainActor [weak entry] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch is CancellationError { return }
            catch {
                PlozzLog.app.error("Detail transition expiry failed: \(String(describing: error))")
            }
            guard let entry, pending[key] === entry else { return }
            pending.removeValue(forKey: key)?.discard()
        }
    }

    static func take(in window: UIWindow) -> PendingDetailEntrance? {
        let result = pending.removeValue(forKey: ObjectIdentifier(window))
        result?.expiry?.cancel()
        result?.expiry = nil
        return result
    }

    static func backdropTask(matching key: String) -> Task<FirstPaintArtwork?, Never>? {
        guard let window = activeWindow, let request = pending[ObjectIdentifier(window)]?.backdropRequest,
              request.key == key else { return nil }
        return request.task
    }

    static func preloadBackdrop(for item: MediaItem) {
        guard item.kind == .movie || item.kind == .series,
              let window = activeWindow, isZoomEnabled(in: window),
              let entry = pending[ObjectIdentifier(window)],
              entry.itemKey == item.stablePresentationID,
              entry.overlay.destination.image == nil, entry.backdropRequest == nil else { return }
        guard !entry.preservesVideo, let policy = entry.source?.artworkPolicy,
              let request = DetailBackdropArtworkRequest(item: item, policy: policy) else { return }
        entry.backdropRequest = request
        entry.backdropDelivery = Task { @MainActor [weak entry] in
            guard let artwork = await request.task.value, !Task.isCancelled else { return }
            entry?.overlay.destination.image = artwork.image
            entry?.start()
        }
    }

    private static func cachedDestinationArtwork(for item: MediaItem, policy: ArtworkPresentationPolicy) -> UIImage? {
        guard item.kind == .movie || item.kind == .series else { return nil }
        let source = DetailBackdropArtworkSource(item: item, policy: policy)
        if let prepared = ArtworkSeedMemo.prepared(for: source.key, variant: .heroBackdrop)
            ?? ArtworkSeedMemo.prepared(for: source.previewKey, variant: .heroPreview) {
            return prepared.image
        }
        guard !source.settings.preferOnlineArtwork else { return nil }
        for reference in source.references {
            if let image = ArtworkImageCache.shared.cachedImage(for: reference, variant: .heroBackdrop)
                ?? ArtworkImageCache.shared.cachedImage(for: reference, variant: .heroPreview),
               image.size.height > 0, image.size.width / image.size.height <= 3 {
                return image
            }
        }
        return nil
    }
}

@MainActor
final class PendingDetailEntrance {
    let itemKey: String
    let source: DetailTransitionSourceReference?
    let sourceFrame: CGRect?
    let sourceCornerRadius: CGFloat
    let card: DetailTransitionSurface?
    weak var focusedItem: (any UIFocusEnvironment)?
    let overlay: DetailTransitionOverlay
    let inputGuard: DetailTransitionInputGuard
    var expiry: Task<Void, Never>?
    var animator: UIViewPropertyAnimator?
    private(set) var landedAt: CFTimeInterval?
    private var hasStarted = false
    private(set) var preservesVideo = false
    var onLanded: (() -> Void)?
    let windowSize: CGSize
    let scrollPositions: [DetailTransitionScrollPosition]
    var backdropRequest: DetailBackdropArtworkRequest?
    var backdropDelivery: Task<Void, Never>?

    init(
        window: UIWindow, itemKey: String, source: DetailTransitionSourceReference?,
        card: DetailTransitionSurface?, sourceFrame: CGRect?, sourceCornerRadius: CGFloat,
        screen: DetailTransitionSurface
    ) {
        self.itemKey = itemKey
        self.source = source
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.card = card
        windowSize = window.bounds.size
        focusedItem = UIFocusSystem.focusSystem(for: window)?.focusedItem
        let focusedView = source?.view ?? (focusedItem as? any UIFocusItem).flatMap {
            TVNavigationExitProtectionFocus.containingView(of: $0)
        }
        scrollPositions = DetailTransitionScrollPosition.capture(
            from: focusedView
        )
        overlay = DetailTransitionOverlay(screen: screen, card: card)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        inputGuard = DetailTransitionNavigation.installInputGuard(in: window)
    }

    func start(allowsMissingArtwork: Bool = false) {
        guard !hasStarted, !preservesVideo else { return }
        overlay.configureOpening(sourceFrame: sourceFrame, cornerRadius: sourceCornerRadius)
        guard overlay.destination.image != nil || allowsMissingArtwork else { return }
        hasStarted = true
        animator = overlay.animateOpening(duration: DetailEntranceTiming().zoom) { [weak self] in
            guard let self else { return }
            landedAt = CACurrentMediaTime()
            animator = nil
            onLanded?()
        }
        // Submit motion before the router constructs or loads the destination.
        CATransaction.flush()
    }

    func preserveVideo() {
        preservesVideo = true
        backdropDelivery?.cancel()
        backdropDelivery = nil
        backdropRequest?.cancel()
        backdropRequest = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay.preserveVideo()
    }

    func discard() {
        backdropDelivery?.cancel()
        backdropDelivery = nil
        backdropRequest?.cancel()
        backdropRequest = nil
        expiry?.cancel()
        expiry = nil
        animator?.stopAnimation(true)
        animator = nil
        onLanded = nil
        overlay.removeFromSuperview()
        inputGuard.invalidate()
    }
}

@MainActor
struct DetailTransitionScrollPosition {
    weak var view: UIScrollView?
    let offset: CGPoint

    static func capture(from view: UIView?) -> [Self] {
        var result: [Self] = []
        var ancestor = view
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                result.append(Self(view: scroll, offset: scroll.contentOffset))
            }
            ancestor = current.superview
        }
        return result
    }

    func restore(in window: UIWindow) {
        guard let view, view.window === window else { return }
        view.setContentOffset(offset, animated: false)
    }
}

@MainActor @Observable
public final class TVDetailEntranceSession {
    public private(set) var stage = DetailEntranceStage.artwork
    public private(set) var isClosing = false
    public private(set) var blocksNavigation = true
    public private(set) var primaryActionPressGeneration: UInt = 0
    public var isBackdropShadingVisible: Bool {
        !usesZoom || foregroundSequenceStarted || stage == .complete
    }
    /// Retained only for the return transition, never as the detail backdrop.
    private(set) var returnArtwork: DetailTransitionSurface?
    @ObservationIgnored private var returnBackground: DetailTransitionSurface?
    @ObservationIgnored private var destinationArtwork: UIImage?
    @ObservationIgnored private var preservesVideo = false
    public let timing: DetailEntranceTiming
    let usesZoom: Bool
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var source: DetailTransitionSourceReference?
    @ObservationIgnored private var sourceKey: String?
    @ObservationIgnored private weak var returnFocus: (any UIFocusEnvironment)?
    @ObservationIgnored private var overlay: DetailTransitionOverlay?
    @ObservationIgnored private var inputGuard: DetailTransitionInputGuard?
    @ObservationIgnored private var animator: UIViewPropertyAnimator?
    @ObservationIgnored private var sequence: Task<Void, Never>?
    @ObservationIgnored private var earlyDestinationArtwork: UIImage?
    @ObservationIgnored private var opening: PendingDetailEntrance?
    @ObservationIgnored private var activationGeometry: DetailTransitionSourceGeometry?
    @ObservationIgnored private var activationWindowSize: CGSize?
    @ObservationIgnored private var artworkHasLanded = false
    @ObservationIgnored private var waitsForPageAppearance = false
    @ObservationIgnored private var pageIsVisible = false
    @ObservationIgnored private var returnMotionFinished = false
    @ObservationIgnored private var returnNavigationFinished = false
    @ObservationIgnored private var navigationTransitionPending = false
    @ObservationIgnored private var returnHandoffScheduled = false
    @ObservationIgnored private var returnHandoffFinished = false
    @ObservationIgnored private var returnGeneration: UUID?
    @ObservationIgnored private var returnFrame: DetailReturnFrame?
    @ObservationIgnored private var scrollPositions: [DetailTransitionScrollPosition] = []
    @ObservationIgnored private let restoreToken = UUID()
    @ObservationIgnored private var backdropRequest: DetailBackdropArtworkRequest?
    @ObservationIgnored private var waitsForBackdrop = false
    @ObservationIgnored private var backdropIsResolved = false
    @ObservationIgnored private var backdropIsAvailable = false
    @ObservationIgnored private var backdropResolvedAt: CFTimeInterval?
    @ObservationIgnored private var artworkLandedAt: CFTimeInterval?
    @ObservationIgnored private var pageAppearedAt: CFTimeInterval?
    private var foregroundSequenceStarted = false
    @ObservationIgnored private var revealsEpisodesLast = false
    @ObservationIgnored private weak var navigationChrome: NavigationChromeModel?
    @ObservationIgnored private let chromeToken = UUID()

    public init(timing: DetailEntranceTiming = DetailEntranceTiming(), usesZoom: Bool = true) {
        self.timing = timing
        self.usesZoom = usesZoom
    }

    public func resolvedDestinationArtwork(_ image: UIImage) {
        guard usesZoom, !isClosing, !preservesVideo else { return }
        destinationArtwork = image
        backdropIsAvailable = true
        backdropIsResolved = true
        if backdropResolvedAt == nil { backdropResolvedAt = CACurrentMediaTime() }
        if !hasStarted {
            earlyDestinationArtwork = image
        } else if let overlay {
            overlay.destination.image = image
        }
        startOpeningIfReady()
        startForegroundIfReady()
    }

    public func resolvedDestinationVideo() {
        guard usesZoom, !isClosing else { return }
        preservesVideo = true
        destinationArtwork = nil
        earlyDestinationArtwork = nil
        returnArtwork = nil
        returnBackground = nil
        opening?.preserveVideo()
        overlay?.preserveVideo()
        backdropIsAvailable = true
        backdropIsResolved = true
        if backdropResolvedAt == nil { backdropResolvedAt = CACurrentMediaTime() }
        startOpeningIfReady()
        startForegroundIfReady()
    }

    func destinationArtworkUnavailable() {
        guard usesZoom, !isClosing, !backdropIsResolved else { return }
        PlozzLog.app.info("Detail backdrop exhausted its candidates; revealing controls without artwork")
        backdropIsResolved = true
        backdropResolvedAt = CACurrentMediaTime()
        if waitsForBackdrop, !artworkHasLanded {
            finishImmediately()
            return
        }
        startForegroundIfReady()
    }

    func backdropTask(matching key: String) -> Task<FirstPaintArtwork?, Never>? {
        guard usesZoom else { return nil }
        if let backdropRequest, backdropRequest.key == key { return backdropRequest.task }
        return DetailTransitionNavigation.backdropTask(matching: key)
    }

    func bind(to window: UIWindow) {
        self.window = window
    }

    func attach(
        to window: UIWindow, enabled: Bool,
        waitsForPageAppearance: Bool = false, waitsForBackdrop: Bool = false,
        revealsEpisodesLast: Bool = false
    ) {
        self.window = window
        guard !hasStarted else { return }
        self.waitsForPageAppearance = waitsForPageAppearance
        self.waitsForBackdrop = usesZoom && waitsForBackdrop
        self.revealsEpisodesLast = revealsEpisodesLast
        if DetailTransitionNavigation.consumesSuppression(in: window) {
            finishImmediately()
            return
        }
        guard enabled, !UIAccessibility.isReduceMotionEnabled else {
            hasStarted = true
            DetailTransitionNavigation.take(in: window)?.discard()
            stage = .complete
            blocksNavigation = false
            return
        }
        hasStarted = true
        stage = .artwork
        if !usesZoom {
            artworkHasLanded = true
            startForegroundIfReady()
            return
        }
        navigationChrome = DetailTransitionNavigation.chromeModel(in: window)
        navigationChrome?.detailAppeared(chromeToken)
        let pending = DetailTransitionNavigation.take(in: window)
        preservesVideo = preservesVideo || pending?.preservesVideo == true
        source = pending?.source
        sourceKey = pending?.itemKey
        returnArtwork = preservesVideo ? nil : pending?.card
        returnBackground = preservesVideo ? nil : pending?.overlay.screen
        activationGeometry = pending?.sourceFrame.map {
            DetailTransitionSourceGeometry(frame: $0, cornerRadius: pending?.sourceCornerRadius ?? 0)
        }
        activationWindowSize = pending?.windowSize
        returnFocus = pending?.focusedItem
        scrollPositions = pending?.scrollPositions ?? []
        backdropRequest = pending?.backdropRequest
        let cover = pending?.overlay
            ?? DetailTransitionOverlay(screen: DetailTransitionSnapshot.surface(of: window), card: nil)
        cover.frame = window.bounds
        if cover.superview == nil { window.addSubview(cover) }
        overlay = cover
        inputGuard = pending?.inputGuard ?? installInputGuard(in: window)
        inputGuard?.onOpeningSelect = { [weak self] in
            guard let self, pageIsVisible, !isClosing, primaryActionPressGeneration == 0 else { return }
            primaryActionPressGeneration &+= 1
        }
        if preservesVideo {
            pending?.preserveVideo()
            cover.preserveVideo()
        } else {
            cover.destination.image = earlyDestinationArtwork ?? cover.destination.image
        }
        destinationArtwork = cover.destination.image
        earlyDestinationArtwork = nil
        if let pending {
            opening = pending
            pending.onLanded = { [weak self] in self?.land() }
            if pending.landedAt != nil { land() }
        } else {
            cover.configureOpening(sourceFrame: nil, cornerRadius: 0)
        }
        startOpeningIfReady()
    }

    private func startOpeningIfReady() {
        guard !isClosing, !artworkHasLanded, let overlay else { return }
        if preservesVideo, backdropIsAvailable {
            land()
        } else if waitsForBackdrop, backdropIsResolved, !backdropIsAvailable {
            finishImmediately()
        } else if waitsForBackdrop, backdropIsAvailable, overlay.destination.image == nil {
            land()
        } else if let opening {
            opening.start(allowsMissingArtwork: !waitsForBackdrop)
        } else if animator == nil, overlay.destination.image != nil || !waitsForBackdrop {
            animator = overlay.animateOpening(duration: timing.zoom) { [weak self] in self?.land() }
        }
    }

    private func land() {
        guard !isClosing else { return }
        artworkHasLanded = true
        artworkLandedAt = opening?.landedAt ?? CACurrentMediaTime()
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening = nil
        animator = nil
        startForegroundIfReady()
    }

    func pageAppeared() {
        guard !isClosing else { return }
        pageIsVisible = true
        navigationChrome?.detailAppeared(chromeToken)
        pageAppearedAt = CACurrentMediaTime()
        startForegroundIfReady()
        finishEntranceIfReady()
    }

    func pageDisappeared() {
        pageIsVisible = false
        navigationChrome?.detailDisappeared(chromeToken)
        guard isClosing else { return }
        HandoffDiagnostics.emit("detail RETURN_PAGE_HIDDEN coordinatorPending=\(navigationTransitionPending)")
        returnNavigationFinished = !navigationTransitionPending
        finishReturnIfReady()
    }

    func navigationWillDisappear(using coordinator: any UIViewControllerTransitionCoordinator) {
        guard isClosing else { return }
        HandoffDiagnostics.emit("detail RETURN_POP_BEGIN animated=\(coordinator.isAnimated) duration=\(coordinator.transitionDuration)")
        let generation = returnGeneration
        navigationTransitionPending = true
        let registered = coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, isClosing, returnGeneration == generation else { return }
            if context.isCancelled {
                PlozzLog.app.info("Detail return was cancelled; restoring the retained page")
                HandoffDiagnostics.emit("detail RETURN_CANCELLED source=\(HandoffDiagnostics.correlationID(sourceKey))")
                finishImmediately()
                pageAppeared()
                return
            }
            navigationTransitionPending = false
            HandoffDiagnostics.emit("detail RETURN_POP_FINISHED pageVisible=\(pageIsVisible)")
            returnNavigationFinished = !pageIsVisible
            finishReturnIfReady()
        }
        if !registered { navigationTransitionPending = false }
    }

    private func removeOpeningCoverIfReady() {
        guard artworkHasLanded, !isClosing, !waitsForPageAppearance || pageIsVisible,
              !waitsForBackdrop || backdropIsResolved, let cover = overlay else { return }
        UIView.animate(withDuration: 0.1, animations: { cover.alpha = 0 }) { [weak self] _ in
            cover.removeFromSuperview()
            if self?.overlay === cover { self?.overlay = nil }
        }
    }

    private func startForegroundIfReady() {
        guard artworkHasLanded, !isClosing, !foregroundSequenceStarted,
              !waitsForPageAppearance || pageIsVisible,
              !waitsForBackdrop || backdropIsResolved else { return }
        foregroundSequenceStarted = true
        removeOpeningCoverIfReady()
        let now = CACurrentMediaTime()
        var readyAt = artworkLandedAt ?? now
        if waitsForBackdrop {
            readyAt = max(readyAt, backdropResolvedAt ?? now, pageAppearedAt ?? readyAt)
        }
        let pause = waitsForBackdrop && !backdropIsAvailable
            ? 0 : max(0, timing.artworkPause - (now - readyAt))
        startForegroundSequence(pause: usesZoom ? pause : 0)
    }

    private func finishEntranceIfReady() {
        guard stage == .complete, !isClosing, !waitsForPageAppearance || pageIsVisible else { return }
        blocksNavigation = false
        releaseInput()
    }

    private func startForegroundSequence(pause: TimeInterval) {
        sequence = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(pause))
                // An expired sleep can already be queued on this actor when
                // finishImmediately cancels us and reveals the complete page.
                try Task.checkCancellation()
                stage = .logo
                try await Task.sleep(for: .seconds(timing.stagger))
                try Task.checkCancellation()
                stage = .metadata
                try await Task.sleep(for: .seconds(timing.stagger))
                try Task.checkCancellation()
                stage = .controls
                try await Task.sleep(for: .seconds(timing.reveal))
                try Task.checkCancellation()
                if revealsEpisodesLast {
                    stage = .episodes
                    try await Task.sleep(for: .seconds(timing.episodeReveal))
                    try Task.checkCancellation()
                }
                stage = .complete
                backdropRequest = nil
                finishEntranceIfReady()
                sequence = nil
            } catch is CancellationError {
                // Disappearance, Reduce Motion, or Back owns the cancellation.
            } catch {
                PlozzLog.app.error("Detail entrance timing failed: \(String(describing: error))")
                finishImmediately()
            }
        }
    }

    func close(dismiss: DismissAction, pop: (@MainActor () -> Bool)?) {
        close(pop: pop) { dismiss() }
    }

    /// Pop the real stack under a visual cover; never replace SwiftUI's navigation delegate.
    func close(pop: (@MainActor () -> Bool)? = nil, dismiss: @escaping @MainActor () -> Void) {
        guard !isClosing else { return }
        guard usesZoom, let window, hasStarted, !UIAccessibility.isReduceMotionEnabled else {
            finishImmediately()
            returnArtwork = nil
            returnBackground = nil
            destinationArtwork = nil
            source = nil
            dismiss()
            return
        }
        if let inputGuard {
            inputGuard.setPhase(.returning)
        } else {
            inputGuard = DetailTransitionNavigation.installInputGuard(in: window, phase: .returning)
        }
        isClosing = true
        returnGeneration = UUID()
        HandoffDiagnostics.emit("detail RETURN_BEGIN source=\(HandoffDiagnostics.correlationID(sourceKey)) at=\(CACurrentMediaTime())")
        navigationChrome?.detailDisappeared(chromeToken)
        backdropRequest?.cancel()
        backdropRequest = nil
        returnMotionFinished = false
        returnNavigationFinished = !waitsForPageAppearance
        returnHandoffScheduled = false
        returnHandoffFinished = false
        DetailTransitionNavigation.beginSourceRestore(in: window, token: restoreToken, session: self)
        blocksNavigation = true
        sequence?.cancel()
        sequence = nil
        let interrupted = !artworkHasLanded || (waitsForBackdrop && !backdropIsAvailable)
        // Restore the source page immediately. A detail-page snapshot would
        // keep its background visible until the native pop finished.
        let screen = !preservesVideo && activationWindowSize == window.bounds.size
            ? returnBackground ?? DetailTransitionSurface()
            : DetailTransitionSurface()
        screen.alpha = 1
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening?.animator?.stopAnimation(true)
        opening = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        let cover = DetailTransitionOverlay(screen: screen, card: returnArtwork)
        cover.frame = window.bounds
        cover.backgroundColor = .clear
        cover.cardContainer.frame = cover.bounds
        cover.destination.image = destinationArtwork
        cover.destination.alpha = destinationArtwork == nil ? 0 : 1
        cover.card.alpha = destinationArtwork == nil ? 1 : 0
        if preservesVideo { cover.preserveVideo() }
        window.addSubview(cover)
        overlay = cover
        // The source is hidden until the native pop, so its visibility is not
        // a prerequisite. Its captured focused shape is already the right target.
        let validSource = source != nil && source?.itemKey == sourceKey
            && activationWindowSize == window.bounds.size
        let target = validSource ? activationGeometry : nil
        let animation = UIViewPropertyAnimator(duration: timing.reverse, curve: .easeInOut)
        if let target, returnArtwork != nil, !interrupted, !preservesVideo {
            cover.layoutIfNeeded()
            animation.addAnimations {
                cover.cardContainer.frame = target.frame
                cover.cardContainer.layer.cornerRadius = target.cornerRadius
                cover.destination.alpha = 0
                cover.card.alpha = 1
            }
        } else {
            cover.cardContainer.isHidden = interrupted || preservesVideo
            animation.addAnimations { cover.cardContainer.alpha = 0 }
        }
        animation.addCompletion { [weak self] position in
            guard let self, isClosing, position == .end else { return }
            returnMotionFinished = true
            HandoffDiagnostics.emit("detail RETURN_MOTION_FINISHED at=\(CACurrentMediaTime())")
            finishReturnIfReady()
        }
        animator = animation
        animation.startAnimation()
        CATransaction.flush()
        HandoffDiagnostics.emit("detail RETURN_POP_REQUESTED at=\(CACurrentMediaTime())")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // DismissAction can animate a native pop despite disablesAnimations.
            // Mutate the owning path only when the reverse cover is in place.
            if let pop {
                if pop() { return }
                PlozzLog.app.error("Detail return has no bound route; using native dismissal")
            }
            dismiss()
        }
        HandoffDiagnostics.emit("detail RETURN_POP_REQUEST_RETURNED at=\(CACurrentMediaTime())")
        finishReturnIfReady()
    }

    private func finishReturnIfReady() {
        guard isClosing, returnNavigationFinished, let cover = overlay else { return }
        guard let window else {
            finishImmediately()
            return
        }
        if !returnHandoffScheduled {
            prepareReturnFocus(in: window, under: cover)
        }
        guard returnMotionFinished, returnHandoffFinished else { return }
        cover.removeFromSuperview()
        HandoffDiagnostics.emit("detail RETURN_FINISHED source=\(HandoffDiagnostics.correlationID(sourceKey)) at=\(CACurrentMediaTime())")
        overlay = nil
        animator = nil
        releaseInput()
        DetailTransitionNavigation.endSourceRestore(token: restoreToken)
        returnArtwork = nil
        returnBackground = nil
        destinationArtwork = nil
        source = nil
        scrollPositions = []
        activationGeometry = nil
        activationWindowSize = nil
        stage = .complete
        blocksNavigation = false
        sequence = nil
        // The popped page stays hidden for its remaining lifetime.
    }

    private func prepareReturnFocus(in window: UIWindow, under cover: DetailTransitionOverlay) {
        returnHandoffScheduled = true
        // Navigation unlocks its focus tree after the Core Animation commit.
        // Cross that boundary as soon as the pop finishes, while the reverse
        // artwork is still moving, rather than adding this work after motion.
        returnFrame = DetailReturnFrame { [self] in
            returnFrame = nil
            guard isClosing, overlay === cover else { return }
            HandoffDiagnostics.emit("detail RETURN_HANDOFF_FRAME at=\(CACurrentMediaTime())")
            UIView.performWithoutAnimation {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if activationWindowSize == window.bounds.size {
                        scrollPositions.forEach { $0.restore(in: window) }
                    }
                    window.layoutIfNeeded()
                    HandoffDiagnostics.emit("detail RETURN_LAYOUT_FINISHED at=\(CACurrentMediaTime())")
                    restoreReturnFocus(in: window)
                    window.layoutIfNeeded()
                }
            }
            HandoffDiagnostics.emit("detail RETURN_FOCUS_REQUESTED at=\(CACurrentMediaTime())")
            DispatchQueue.main.async { [self] in
                guard isClosing, overlay === cover else { return }
                returnHandoffFinished = true
                finishReturnIfReady()
            }
        }
    }

    private func restoreReturnFocus(in window: UIWindow) {
        if let source, let sourceKey {
            let context = scrollPositions.first?.view.flatMap { $0.window === window ? $0 : nil }
            let original = source.itemKey == sourceKey && source.visibleFrame(in: window) != nil ? source : nil
            let live = original ?? DetailTransitionSourceReference.liveSource(
                in: window, itemKey: sourceKey, scrollContext: context, near: activationGeometry?.frame
            )
            if let live {
                live.restoreFocus(in: window, preferred: returnFocus)
                return
            }
        }
        guard let preferred = returnFocus as? any UIFocusItem,
              preferred.canBecomeFocused,
              TVNavigationExitProtectionFocus.containingView(of: preferred)?.window === window,
              let system = UIFocusSystem.focusSystem(for: window) else {
            PlozzLog.app.debug("Detail return has no surviving source focus target")
            return
        }
        system.requestFocusUpdate(to: preferred)
        system.updateFocusIfNeeded()
        if system.focusedItem !== preferred {
            PlozzLog.app.debug("Detail return focus request was not accepted by the current focus scope")
        }
    }

    func disappeared() {
        navigationChrome?.detailDisappeared(chromeToken)
        guard !isClosing else { return }
        finishImmediately()
    }

    func releaseReturnBackgroundForMemoryPressure() {
        if returnBackground != nil {
            PlozzLog.app.debug("Releasing the detail return backdrop after a memory warning")
            returnBackground = nil
        }
    }

    /// A ready user action takes precedence over decorative entrance work.
    public func finishOpeningForPrimaryAction() {
        guard !isClosing, blocksNavigation else { return }
        finishImmediately(releaseInputImmediately: false)
    }

    func finishImmediately(releaseInputImmediately: Bool = true) {
        returnFrame?.invalidate()
        returnFrame = nil
        let wasStarted = hasStarted
        returnGeneration = nil
        navigationTransitionPending = false
        hasStarted = true
        foregroundSequenceStarted = true
        backdropRequest?.cancel()
        backdropRequest = nil
        if !wasStarted, let window { DetailTransitionNavigation.take(in: window)?.discard() }
        sequence?.cancel()
        sequence = nil
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening?.animator?.stopAnimation(true)
        opening = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        overlay = nil
        earlyDestinationArtwork = nil
        DetailTransitionNavigation.endSourceRestore(token: restoreToken)
        releaseInput(force: releaseInputImmediately)
        stage = .complete
        isClosing = false
        blocksNavigation = false
    }

    private func installInputGuard(in window: UIWindow) -> DetailTransitionInputGuard {
        DetailTransitionNavigation.installInputGuard(in: window)
    }

    private func releaseInput(force: Bool = false) {
        if force { inputGuard?.invalidate() }
        else { inputGuard?.releaseWhenIdle() }
        inputGuard = nil
    }
}

@MainActor
private final class DetailReturnFrame: NSObject {
    private var link: CADisplayLink?
    private var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(fire))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func fire() {
        let action = action
        invalidate()
        action?()
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        action = nil
    }
}

private struct DetailEntranceSessionKey: EnvironmentKey {
    static let defaultValue: TVDetailEntranceSession? = nil
}

public extension EnvironmentValues {
    var detailEntranceSession: TVDetailEntranceSession? {
        get { self[DetailEntranceSessionKey.self] }
        set { self[DetailEntranceSessionKey.self] = newValue }
    }
}

private struct TVDetailPageTransition: ViewModifier {
    let isEnabled: Bool
    let waitsForBackdrop: Bool
    let revealsEpisodesLast: Bool
    @Environment(\.detailZoomEnabled) private var zoomEnabled

    func body(content: Content) -> some View {
        if zoomEnabled {
            content.modifier(TVDetailPageEntrance(
                isEnabled: isEnabled, waitsForBackdrop: waitsForBackdrop,
                revealsEpisodesLast: revealsEpisodesLast, usesZoom: true
            ))
        } else {
            content.modifier(TVDetailPageEntrance(
                isEnabled: isEnabled, waitsForBackdrop: false,
                revealsEpisodesLast: revealsEpisodesLast, usesZoom: false
            ))
        }
    }
}

private struct TVDetailPageEntrance: ViewModifier {
    let isEnabled: Bool
    let waitsForBackdrop: Bool
    let revealsEpisodesLast: Bool
    @State private var session: TVDetailEntranceSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.detailNavigationPop) private var pop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(isEnabled: Bool, waitsForBackdrop: Bool, revealsEpisodesLast: Bool, usesZoom: Bool) {
        self.isEnabled = isEnabled
        self.waitsForBackdrop = waitsForBackdrop
        self.revealsEpisodesLast = revealsEpisodesLast
        _session = State(initialValue: TVDetailEntranceSession(usesZoom: usesZoom))
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if session.usesZoom {
            entranceContent(content)
                .onExitCommand {
                    if isEnabled, !reduceMotion { session.close(dismiss: dismiss, pop: pop) }
                    else { dismiss() }
                }
        } else {
            entranceContent(content)
        }
    }

    private func entranceContent(_ content: Content) -> some View {
        content
            .opacity(session.isClosing ? 0 : 1)
            .animation(nil, value: session.isClosing)
            .environment(\.detailEntranceSession, isEnabled && !reduceMotion ? session : nil)
            .background {
                DetailEntrancePageAnchor(
                    session: session, enabled: isEnabled && !reduceMotion,
                    waitsForBackdrop: waitsForBackdrop, revealsEpisodesLast: revealsEpisodesLast
                )
            }
            .onDisappear { session.disappeared() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                session.releaseReturnBackgroundForMemoryPressure()
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { session.finishImmediately() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { session.finishImmediately() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { session.finishImmediately() }
            }
    }
}

private struct TVDetailStageReveal: ViewModifier {
    let stage: DetailEntranceStage
    @Environment(\.detailEntranceSession) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = reduceMotion
            || (session.map { $0.stage >= stage && !$0.isClosing } ?? true)
        let isEpisodeEntrance = stage == .episodes && session?.isClosing != true
        let reveal = isEpisodeEntrance ? session?.timing.episodeReveal : session?.timing.reveal
        let duration = session?.isClosing == true ? 0.12 : (reveal ?? 0)
        let travel = isEpisodeEntrance ? DetailEntranceMotion.episodeTravel : DetailEntranceMotion.foregroundTravel
        let animation: Animation? = reduceMotion ? nil
            : session?.isClosing == true ? .easeOut(duration: duration)
            : isEpisodeEntrance ? DetailEntranceMotion.episodeReveal(duration: duration)
            : DetailEntranceMotion.reveal(duration: duration)
        content
            .offset(y: visible ? 0 : travel)
            .mask { Rectangle().padding(-600).opacity(visible ? 1 : 0) }
            .animation(animation, value: visible)
    }
}

private struct DetailEntrancePageAnchor: UIViewControllerRepresentable {
    let session: TVDetailEntranceSession
    let enabled: Bool
    let waitsForBackdrop: Bool
    let revealsEpisodesLast: Bool

    final class Coordinator {
        let session: TVDetailEntranceSession
        init(session: TVDetailEntranceSession) { self.session = session }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIViewController(context: Context) -> DetailEntranceController {
        DetailEntranceController()
    }

    func updateUIViewController(_ controller: DetailEntranceController, context: Context) {
        controller.session = session
        let view = controller.anchor
        view.session = session
        view.enabled = enabled
        view.waitsForBackdrop = waitsForBackdrop
        view.revealsEpisodesLast = revealsEpisodesLast
        view.attach()
    }

    static func dismantleUIViewController(_ controller: DetailEntranceController, coordinator: Coordinator) {
        coordinator.session.pageDisappeared()
        coordinator.session.disappeared()
    }
}

private final class DetailEntranceController: UIViewController {
    let anchor = DetailEntranceAnchorView()
    weak var session: TVDetailEntranceSession?

    override func loadView() {
        anchor.isUserInteractionEnabled = false
        view = anchor
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session?.pageAppeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session?.pageDisappeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let transitionCoordinator { session?.navigationWillDisappear(using: transitionCoordinator) }
    }
}

private final class DetailEntranceAnchorView: UIView {
    weak var session: TVDetailEntranceSession?
    var enabled = true
    var waitsForBackdrop = false
    var revealsEpisodesLast = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    func attach() {
        guard let window, let session else { return }
        session.bind(to: window)
        let enabled = enabled
        let waitsForBackdrop = waitsForBackdrop
        let revealsEpisodesLast = revealsEpisodesLast
        DispatchQueue.main.async { [weak self, weak window, weak session] in
            guard self?.window === window, let window else { return }
            session?.attach(
                to: window, enabled: enabled,
                waitsForPageAppearance: true, waitsForBackdrop: waitsForBackdrop,
                revealsEpisodesLast: revealsEpisodesLast
            )
        }
    }
}

@MainActor
final class DetailTransitionOverlay: UIView {
    let screen: DetailTransitionSurface
    let card: DetailTransitionSurface
    let destination = UIImageView()
    let cardContainer = UIView()

    init(screen: DetailTransitionSurface, card: DetailTransitionSurface?) {
        self.screen = screen
        self.card = card ?? DetailTransitionSurface()
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        self.screen.contentMode = .scaleAspectFill
        self.screen.clipsToBounds = true
        self.card.contentMode = .scaleAspectFill
        self.card.clipsToBounds = true
        destination.contentMode = .scaleAspectFill
        destination.clipsToBounds = true
        destination.alpha = 0
        cardContainer.clipsToBounds = true
        cardContainer.layer.cornerCurve = .continuous
        addSubview(self.screen)
        addSubview(cardContainer)
        cardContainer.addSubview(self.card)
        cardContainer.addSubview(destination)
        self.card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        destination.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.card.alpha = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func preserveVideo() {
        backgroundColor = .clear
        screen.isHidden = true
        cardContainer.isHidden = true
        destination.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if screen.superview === self { screen.frame = bounds }
        card.frame = cardContainer.bounds
        destination.frame = cardContainer.bounds
    }

    func configureOpening(sourceFrame: CGRect?, cornerRadius: CGFloat) {
        screen.frame = bounds
        cardContainer.frame = sourceFrame ?? bounds
        cardContainer.layer.cornerRadius = cornerRadius
        card.frame = cardContainer.bounds
        destination.frame = cardContainer.bounds
    }

    func animateOpening(duration: TimeInterval, completion: @escaping () -> Void) -> UIViewPropertyAnimator {
        layoutIfNeeded()
        let animation = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UICubicTimingParameters(
                controlPoint1: CGPoint(x: DetailEntranceMotion.pickup.x, y: DetailEntranceMotion.pickup.y),
                controlPoint2: CGPoint(x: DetailEntranceMotion.landing.x, y: DetailEntranceMotion.landing.y)
            )
        )
        animation.addAnimations {
            self.cardContainer.frame = self.bounds
            self.cardContainer.layer.cornerRadius = 0
            // The blend shares the zoom's clock and cancellation instead of
            // continuing as a separate linear animation during an early Back.
            UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.calculationModeLinear]) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                    self.card.alpha = 0
                    self.screen.alpha = 0
                    self.destination.alpha = 1
                }
            }
        }
        animation.addCompletion { position in
            if position == .end { completion() }
        }
        animation.startAnimation()
        return animation
    }
}

/// A render-server snapshot avoids rasterizing the complete Home hierarchy on
/// the main thread. Uniform scaling crops the snapshot instead of stretching it.
@MainActor
final class DetailTransitionSurface: UIView {
    private let capturedView: UIView
    let captureSize: CGSize
    let image: UIImage?

    init() {
        capturedView = UIView()
        captureSize = .zero
        image = nil
        super.init(frame: .zero)
        clipsToBounds = true
    }

    init(image: UIImage) {
        self.image = image
        capturedView = UIImageView(image: image)
        captureSize = image.size
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(capturedView)
    }

    init(snapshot: UIView, size: CGSize) {
        image = nil
        capturedView = snapshot
        captureSize = size
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(capturedView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard captureSize.width > 0, captureSize.height > 0 else { return }
        let scale = max(bounds.width / captureSize.width, bounds.height / captureSize.height)
        capturedView.bounds = CGRect(origin: .zero, size: captureSize)
        capturedView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        capturedView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

@MainActor
enum DetailTransitionSnapshot {
    static func surface(of window: UIWindow, frame: CGRect? = nil) -> DetailTransitionSurface {
        let frame = frame ?? window.bounds
        let root = window.rootViewController?.viewIfLoaded ?? window
        let rect = root.convert(frame, from: window)
        if let snapshot = root.resizableSnapshotView(
            from: rect, afterScreenUpdates: false, withCapInsets: .zero
        ) {
            return DetailTransitionSurface(snapshot: snapshot, size: frame.size)
        }
        PlozzLog.app.debug("No rendered transition snapshot; using the neutral surface without blocking navigation")
        let result = DetailTransitionSurface()
        result.backgroundColor = window.backgroundColor ?? .black
        return result
    }

    static func image(of window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) {
                PlozzLog.app.debug("Detail transition using layer snapshot fallback")
                window.layer.render(in: context.cgContext)
            }
        }
    }

    static func crop(_ image: UIImage, to frame: CGRect) -> UIImage? {
        guard let source = image.cgImage, let cropped = source.cropping(to: frame) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

/// Navigation is suppressed during entrance; a fresh Select can queue the destination's primary action.
@MainActor
final class DetailTransitionInputGuard: UIGestureRecognizer {
    enum Phase { case opening, returning }
    private(set) var phase: Phase
    var onOpeningSelect: (() -> Void)?
    private var activePresses: Set<ObjectIdentifier> = []
    private var activeTouches: Set<ObjectIdentifier> = []
    private var releaseRequested = false
    private var removalScheduled = false

    init(phase: Phase = .opening) {
        self.phase = phase
        super.init(target: nil, action: nil)
        allowedPressTypes = [
            UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
            .pageUp, .pageDown, .select, .playPause
        ].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = true
        name = "Plozz cinematic navigation input"
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillDeactivate),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationWillDeactivate() { invalidate() }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func releaseWhenIdle() {
        if phase == .returning {
            HandoffDiagnostics.emit("detail RETURN_INPUT_RELEASE presses=\(activePresses.count) touches=\(activeTouches.count) at=\(CACurrentMediaTime())")
        }
        releaseRequested = true
        if activePresses.isEmpty, activeTouches.isEmpty { invalidate() }
    }

    func invalidate() {
        if phase == .returning {
            HandoffDiagnostics.emit("detail RETURN_INPUT_REMOVED at=\(CACurrentMediaTime())")
        }
        releaseRequested = false
        let window = view as? UIWindow
        view?.removeGestureRecognizer(self)
        if let window { DetailTransitionNavigation.refreshChromeInput(in: window) }
    }

    func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        if let window = view as? UIWindow { DetailTransitionNavigation.refreshChromeInput(in: window) }
    }

    private func finishInputIfIdle() {
        guard activePresses.isEmpty, activeTouches.isEmpty else { return }
        state = .ended
        guard releaseRequested, !removalScheduled else { return }
        removalScheduled = true
        // Keep suppression visible to passive observers handling this same
        // release event, including a swipe that began before visual completion.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            removalScheduled = false
            guard releaseRequested, activePresses.isEmpty, activeTouches.isEmpty else { return }
            invalidate()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let blocked = presses.filter { allowedPressTypes.contains(NSNumber(value: $0.type.rawValue)) }
        guard !blocked.isEmpty else { return }
        activePresses.formUnion(blocked.map(ObjectIdentifier.init))
        state = .began
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let identifiers = Set(presses.map(ObjectIdentifier.init))
        guard !activePresses.isDisjoint(with: identifiers) else { return }
        let selected = phase == .opening && presses.contains {
            $0.type == .select && activePresses.contains(ObjectIdentifier($0))
        }
        activePresses.subtract(identifiers)
        finishInputIfIdle()
        if selected { onOpeningSelect?() }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let identifiers = Set(presses.map(ObjectIdentifier.init))
        guard !activePresses.isDisjoint(with: identifiers) else { return }
        activePresses.subtract(identifiers)
        finishInputIfIdle()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches.map(ObjectIdentifier.init))
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let identifiers = Set(touches.map(ObjectIdentifier.init))
        guard !activeTouches.isDisjoint(with: identifiers) else { return }
        activeTouches.subtract(identifiers)
        finishInputIfIdle()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let identifiers = Set(touches.map(ObjectIdentifier.init))
        guard !activeTouches.isDisjoint(with: identifiers) else { return }
        activeTouches.subtract(identifiers)
        finishInputIfIdle()
    }
}
#endif
