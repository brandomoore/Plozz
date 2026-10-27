#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeaturePlayback
import Observation
import SwiftUI
import UIKit

/// The in-place live player restricts only its own window, never another scene.
@MainActor
public enum PlozziOSWindowOrientation {
    private static let owners = NSMapTable<UIWindow, PlozziOSOrientationHostingController>.weakToWeakObjects()

    public static func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let window else { return .all }
        var controller = window.rootViewController
        var presentedPlayer: PlozziOSOrientationHostingController?
        while let current = controller {
            if let player = current as? PlozziOSOrientationHostingController, !player.isBeingDismissed {
                presentedPlayer = player
            }
            controller = current.presentedViewController
        }
        return presentedPlayer?.supportedInterfaceOrientations
            ?? owners.object(forKey: window)?.supportedInterfaceOrientations
            ?? browsingMask(for: window.traitCollection.userInterfaceIdiom, windowSize: window.bounds.size)
    }

    static func browsingMask(for idiom: UIUserInterfaceIdiom, windowSize: CGSize = .zero) -> UIInterfaceOrientationMask {
        usesCompactPhonePolicy(idiom: idiom, windowSize: windowSize) ? .portrait : .all
    }

    static func usesCompactPhonePolicy(idiom: UIUserInterfaceIdiom, windowSize: CGSize) -> Bool {
        idiom == .phone && min(windowSize.width, windowSize.height) < 600
    }

    static func restoreOrientation(for window: UIWindow?) {
        guard let window, window.isKeyWindow,
              window.rootViewController?.presentedViewController == nil,
              let scene = window.windowScene, scene.activationState == .foregroundActive else { return }
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let mask = supportedOrientations(for: window)
        guard let current = PlozziOSPlayerOrientation.mask(for: scene.effectiveGeometry.interfaceOrientation),
              mask.intersection(current).isEmpty else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            PlozzLog.playback.error("Restoring browsing orientation failed: \(error.localizedDescription)")
        }
    }

    static func acquire(_ owner: PlozziOSOrientationHostingController, for window: UIWindow) {
        owners.setObject(owner, forKey: window)
    }

    @discardableResult
    static func release(_ owner: PlozziOSOrientationHostingController, for window: UIWindow) -> Bool {
        guard owners.object(forKey: window) === owner else { return false }
        owners.removeObject(forKey: window)
        return true
    }
}

@MainActor
@Observable
final class PlozziOSPlayerOrientation {
    private(set) var preference: PlaybackOrientation
    private(set) var isPlaybackActive: Bool
    private(set) var hasGeometryRequestFailed = false
    private(set) var isAvailable = false
    @ObservationIgnored weak var host: PlozziOSOrientationHostingController?
    @ObservationIgnored var close: () -> Void = {}

    init(preference: PlaybackOrientation, isPlaybackActive: Bool = true) {
        self.preference = preference
        self.isPlaybackActive = isPlaybackActive
    }

    var requestedMask: UIInterfaceOrientationMask {
        isPlaybackActive ? Self.mask(for: preference) : .portrait
    }

    var supportedMask: UIInterfaceOrientationMask { isAvailable ? requestedMask : .all }

    static func mask(for preference: PlaybackOrientation) -> UIInterfaceOrientationMask {
        switch preference {
        case .auto: .all
        case .landscape: .landscape
        case .portrait: .portrait
        }
    }

    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }

    static func supportsPreference(
        idiom: UIUserInterfaceIdiom,
        windowSize: CGSize, screenSize: CGSize
    ) -> Bool {
        guard PlozziOSWindowOrientation.usesCompactPhonePolicy(idiom: idiom, windowSize: windowSize) else { return false }
        guard windowSize.width > 0, windowSize.height > 0 else { return false }
        // Compare independently of rotation while UIKit transitions between coordinate spaces.
        return abs(min(windowSize.width, windowSize.height) - min(screenSize.width, screenSize.height)) < 1
            && abs(max(windowSize.width, windowSize.height) - max(screenSize.width, screenSize.height)) < 1
    }

    func updatePreference(_ value: PlaybackOrientation) {
        guard preference != value else { return }
        preference = value
        host?.applyOrientation()
    }

    func beginPlayback() {
        guard !isPlaybackActive else { return }
        isPlaybackActive = true
        host?.applyOrientation()
    }

    func updateAvailability(_ value: Bool) {
        guard isAvailable != value else { return }
        isAvailable = value
        host?.applyOrientation()
    }

    func geometryRequestFailed(_ error: Error) {
        PlozzLog.playback.error("Player orientation request failed: \(error.localizedDescription)")
        hasGeometryRequestFailed = true
    }

    func clearGeometryFailure() {
        hasGeometryRequestFailed = false
    }
}

/// Owns a full-screen cover or an in-place player's window-scoped orientation policy.
final class PlozziOSOrientationHostingController: UIHostingController<AnyView> {
    typealias GeometryRequest = @MainActor (
        UIWindowScene, UIInterfaceOrientationMask, @escaping @MainActor (Error) -> Void
    ) -> Void

    let orientation: PlozziOSPlayerOrientation
    private let ownsWindowOrientation: Bool
    private let requestGeometry: GeometryRequest
    private let currentInterfaceOrientation: @MainActor (UIWindowScene) -> UIInterfaceOrientation
    private weak var orientationWindow: UIWindow?
    var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)?
    private var reportedInterfaceOrientation: UIInterfaceOrientation?
    private var requestGeneration = 0
    private var hasAppeared = false
    private var geometryTask: Task<Void, Error>?

    init(
        rootView: AnyView, orientation: PlozziOSPlayerOrientation,
        ownsWindowOrientation: Bool = false,
        currentInterfaceOrientation: @escaping @MainActor (UIWindowScene) -> UIInterfaceOrientation = {
            $0.effectiveGeometry.interfaceOrientation
        },
        requestGeometry: @escaping GeometryRequest = { scene, mask, onError in
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: onError)
        }
    ) {
        self.orientation = orientation
        self.ownsWindowOrientation = ownsWindowOrientation
        self.requestGeometry = requestGeometry
        self.currentInterfaceOrientation = currentInterfaceOrientation
        super.init(rootView: rootView)
        modalPresentationStyle = .fullScreen
        orientation.host = self
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        !ownsWindowOrientation && hasPendingPresentation ? .all : orientation.supportedMask
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        let current = presentingViewController?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation
        if let current, let mask = PlozziOSPlayerOrientation.mask(for: current),
           !mask.intersection(orientation.requestedMask).isEmpty { return current }
        return orientation.requestedMask == .landscape ? .landscapeRight : .portrait
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        orientation.host = self
        hasAppeared = true
        refreshAvailability()
        applyOrientation()
        reportInterfaceOrientation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshAvailability()
        reportInterfaceOrientation()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.reportInterfaceOrientation()
        }
    }

    var acceptsLiveRotation: Bool {
        hasAppeared && orientation.isAvailable && !hasPendingPresentation && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func reportInterfaceOrientation() {
        guard acceptsLiveRotation, let scene = view.window?.windowScene else { return }
        let current = scene.effectiveGeometry.interfaceOrientation
        guard current != reportedInterfaceOrientation else { return }
        reportedInterfaceOrientation = current
        Task { @MainActor [weak self, weak scene] in
            guard let self, self.hasAppeared, let scene,
                  scene.activationState == .foregroundActive,
                  scene.effectiveGeometry.interfaceOrientation == current else { return }
            self.onInterfaceOrientationChange?(current)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // An embedded live owner can be covered by its own controls without ending playback.
        if isBeingDismissed || (!ownsWindowOrientation && presentingViewController == nil) { tearDown() }
    }

    func tearDown() {
        hasAppeared = false
        requestGeneration += 1
        geometryTask?.cancel()
        geometryTask = nil
        if orientation.host === self {
            orientation.host = nil
        }
        releaseWindowOrientation()
    }

    private func releaseWindowOrientation() {
        guard let window = orientationWindow else { return }
        orientationWindow = nil
        guard PlozziOSWindowOrientation.release(self, for: window) else { return }
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        PlozziOSWindowOrientation.restoreOrientation(for: window)
    }

    private func refreshAvailability() {
        guard let window = view.window, window.windowScene != nil else { return }
        orientation.updateAvailability(PlozziOSPlayerOrientation.supportsPreference(
            idiom: traitCollection.userInterfaceIdiom,
            windowSize: window.bounds.size, screenSize: window.screen.bounds.size
        ))
    }

    func invalidateOrientationPreferences() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        presentingViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if ownsWindowOrientation {
            viewIfLoaded?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    func applyOrientation() {
        requestGeneration += 1
        geometryTask?.cancel()
        geometryTask = nil
        if ownsWindowOrientation {
            if hasAppeared, orientation.isAvailable, let window = viewIfLoaded?.window {
                if orientationWindow !== window {
                    releaseWindowOrientation()
                    orientationWindow = window
                    PlozziOSWindowOrientation.acquire(self, for: window)
                }
            } else {
                releaseWindowOrientation()
            }
        }
        invalidateOrientationPreferences()
        guard hasAppeared, orientation.isAvailable, let scene = view.window?.windowScene,
              scene.activationState == .foregroundActive else { return }
        let generation = requestGeneration
        geometryTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(3)
            var requests = 0
            var nextRequest = ContinuousClock.now
            defer {
                if self?.requestGeneration == generation { self?.geometryTask = nil }
            }
            while ContinuousClock.now < deadline {
                // A yield alone can run again before UIKit commits a pending sheet dismissal.
                try await Task.sleep(for: .milliseconds(50))
                guard let self, self.requestGeneration == generation, self.orientation.host === self,
                      self.hasAppeared, self.orientation.isAvailable,
                      self.viewIfLoaded?.window?.windowScene === scene,
                      scene.activationState == .foregroundActive else { return }
                let mask = self.orientation.supportedMask
                if let current = PlozziOSPlayerOrientation.mask(for: self.currentInterfaceOrientation(scene)),
                   !mask.intersection(current).isEmpty {
                    self.orientation.clearGeometryFailure()
                    return
                }
                if let transition = self.transitionCoordinator ?? self.presentedViewController?.transitionCoordinator,
                   transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                       guard let self, self.requestGeneration == generation, self.orientation.host === self else { return }
                       self.applyOrientation()
                   }) {
                    return
                }
                guard self.canRequestGeometry else { continue }
                guard requests == 0 || self.orientation.hasGeometryRequestFailed else { continue }
                guard requests < 3 else { return }
                guard ContinuousClock.now >= nextRequest else { continue }
                requests += 1
                nextRequest = .now + .milliseconds(200)
                self.orientation.clearGeometryFailure()
                self.invalidateOrientationPreferences()
                self.requestGeometry(scene, mask) { [weak self] error in
                    guard let self, self.requestGeneration == generation, self.orientation.host === self else { return }
                    self.orientation.geometryRequestFailed(error)
                }
            }
            PlozzLog.playback.error("Player orientation did not settle before the presentation deadline.")
        }
    }

    private var canRequestGeometry: Bool {
        !hasPendingPresentation && transitionCoordinator == nil && viewIfLoaded?.window?.isKeyWindow == true
    }

    private var hasPendingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            guard !current.isBeingPresented, !current.isBeingDismissed,
                  current.presentedViewController == nil else { return true }
            if let transition = current.transitionCoordinator,
               let from = transition.viewController(forKey: .from),
               let to = transition.viewController(forKey: .to), from !== to {
                return true
            }
            controller = current.parent
        }
        return false
    }

}

extension View {
    func plozziOSLivePlayerOrientation(
        isPresented: Bool, orientation: PlaybackOrientation, isActive: Bool = true
    ) -> some View {
        modifier(PlozziOSLiveOrientationModifier(
            isPresented: isPresented, preference: orientation, isActive: isActive
        ))
    }

    func plozziOSPlayerCover<Content: View>(
        item: Binding<PlozziOSPlaybackRequest?>,
        orientation: PlaybackOrientation,
        @ViewBuilder content: @escaping (PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> Content
    ) -> some View {
        background {
            PlozziOSPlayerPresentation(
                item: item,
                preference: UIDevice.current.userInterfaceIdiom == .phone ? orientation : .auto,
                content: content
            )
                .frame(width: 0, height: 0)
        }
    }
}

struct PlozziOSLiveRotationPolicy {
    enum Action: Equatable { case expand, returnToGuide }
    private(set) var automaticallyExpanded = false
    private(set) var awaitsUpright = false

    func effectivePreference(_ preference: PlaybackOrientation, isPresented: Bool, canExpand: Bool) -> PlaybackOrientation {
        if isPresented { return preference }
        return preference == .auto && canExpand && !awaitsUpright ? .auto : .portrait
    }

    mutating func interfaceChanged(
        _ interface: UIInterfaceOrientation, preference: PlaybackOrientation,
        isPresented: Bool, canExpand: Bool
    ) -> Action? {
        guard preference == .auto else { automaticallyExpanded = false; return nil }
        if interface.isLandscape, !isPresented, canExpand, !awaitsUpright {
            automaticallyExpanded = true
            return .expand
        }
        if interface == .portrait, isPresented, automaticallyExpanded {
            automaticallyExpanded = false
            return .returnToGuide
        }
        return nil
    }

    mutating func closed(interface: UIInterfaceOrientation, device: UIDeviceOrientation) {
        automaticallyExpanded = false
        awaitsUpright = device.isLandscape || (interface.isLandscape && device != .portrait)
    }

    mutating func deviceChanged(_ device: UIDeviceOrientation) {
        if device == .portrait { awaitsUpright = false }
    }

    mutating func cancelAutomaticReturn() {
        automaticallyExpanded = false
    }
}

private struct PlozziOSLiveOrientationModifier: ViewModifier {
    let isPresented: Bool
    let preference: PlaybackOrientation
    let isActive: Bool
    @State private var target: LiveChannelRotationTarget?

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(LiveChannelRotationTargetKey.self) { target = $0 }
            .overlay(alignment: .top) {
                if isActive, UIDevice.current.userInterfaceIdiom == .phone {
                    PlozziOSLiveOrientationOwner(isPresented: isPresented, preference: preference, target: target)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct PlozziOSLiveOrientationOwner: View {
    let isPresented: Bool
    let preference: PlaybackOrientation
    let target: LiveChannelRotationTarget?
    @State private var orientation: PlozziOSPlayerOrientation
    @State private var policy = PlozziOSLiveRotationPolicy()
    @Environment(\.scenePhase) private var scenePhase

    init(isPresented: Bool, preference: PlaybackOrientation, target: LiveChannelRotationTarget?) {
        self.isPresented = isPresented
        self.preference = preference
        self.target = target
        _orientation = State(initialValue: PlozziOSPlayerOrientation(
            preference: isPresented ? preference : .portrait
        ))
    }

    private var effectivePreference: PlaybackOrientation {
        policy.effectivePreference(preference, isPresented: isPresented, canExpand: target?.canExpand == true)
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        orientation.host?.viewIfLoaded?.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
    }

    private func handleRotation(_ value: UIInterfaceOrientation) {
        guard scenePhase == .active, orientation.host?.acceptsLiveRotation == true, let target else { return }
        switch policy.interfaceChanged(value, preference: preference, isPresented: isPresented,
                                       canExpand: target.canExpand) {
        case .expand: target.expand()
        case .returnToGuide: target.returnToGuide()
        case nil: break
        }
    }

    var body: some View {
        PlozziOSLiveOrientationAttachment(orientation: orientation, onInterfaceOrientationChange: handleRotation)
            .frame(width: 0, height: 0)
            .onChange(of: effectivePreference, initial: true) { _, value in orientation.updatePreference(value) }
            .onChange(of: isPresented) { wasPresented, presented in
                if wasPresented, !presented {
                    policy.closed(interface: interfaceOrientation, device: UIDevice.current.orientation)
                }
            }
            .onChange(of: preference) { _, _ in policy.cancelAutomaticReturn() }
            .onChange(of: target) { _, target in
                if target == nil, !isPresented { policy.cancelAutomaticReturn() }
                handleRotation(interfaceOrientation)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                policy.deviceChanged(UIDevice.current.orientation)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { orientation.host?.applyOrientation() }
            }
            .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
            .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }
}

private struct PlozziOSLiveOrientationAttachment: UIViewControllerRepresentable {
    let orientation: PlozziOSPlayerOrientation
    let onInterfaceOrientationChange: (UIInterfaceOrientation) -> Void

    func makeUIViewController(context: Context) -> PlozziOSOrientationHostingController {
        PlozziOSOrientationHostingController(
            rootView: AnyView(Color.clear), orientation: orientation, ownsWindowOrientation: true
        )
    }

    func updateUIViewController(_ controller: PlozziOSOrientationHostingController, context: Context) {
        controller.onInterfaceOrientationChange = onInterfaceOrientationChange
    }

    static func dismantleUIViewController(_ controller: PlozziOSOrientationHostingController, coordinator: ()) {
        controller.tearDown()
    }
}

struct PlozziOSPlayerPresentation<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    @Binding var item: PlozziOSPlaybackRequest?
    let preference: PlaybackOrientation
    let content: (PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.onAppear = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateUIViewController(_ controller: Anchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.request = item
        coordinator.preference = preference
        coordinator.makeContent = { request, orientation in
            AnyView(PresentationContent(request: request, orientation: orientation, content: content)
                .environment(\.self, environment))
        }
        coordinator.clearRequest = { id in
            if item?.id == id { item = nil }
        }
        coordinator.reconcile()
    }

    private struct PresentationContent: View {
        @Environment(\.scenePhase) private var scenePhase
        let request: PlozziOSPlaybackRequest
        let orientation: PlozziOSPlayerOrientation
        let content: (PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> Content

        var body: some View {
            content(request, orientation)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { orientation.host?.applyOrientation() }
                }
        }
    }

    static func dismantleUIViewController(_ controller: Anchor, coordinator: Coordinator) {
        coordinator.request = nil
        coordinator.host?.tearDown()
        coordinator.host?.dismiss(animated: false)
        coordinator.host = nil
    }

    final class Anchor: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    @MainActor
    final class Coordinator {
        weak var anchor: Anchor?
        var host: PlozziOSOrientationHostingController?
        var request: PlozziOSPlaybackRequest?
        var presentedID: UUID?
        var preference: PlaybackOrientation = .auto
        var makeContent: ((PlozziOSPlaybackRequest, PlozziOSPlayerOrientation) -> AnyView)?
        var clearRequest: ((UUID) -> Void)?
        private var transitioning = false

        func close(_ id: UUID) {
            guard presentedID == id else { return }
            if request?.id == id { request = nil }
            clearRequest?(id)
            // The full-screen presenter may not receive another SwiftUI update while hidden.
            reconcile()
        }

        func reconcile() {
            guard !transitioning else { return }
            if let host {
                guard request?.id == presentedID else {
                    transitioning = true
                    let window = host.viewIfLoaded?.window
                    host.tearDown()
                    host.dismiss(animated: true) { [weak self] in
                        guard let self else { return }
                        self.host = nil
                        self.presentedID = nil
                        self.transitioning = false
                        PlozziOSWindowOrientation.restoreOrientation(for: window)
                        self.reconcile()
                    }
                    return
                }
                if let request, let makeContent {
                    host.orientation.updatePreference(preference)
                    host.rootView = makeContent(request, host.orientation)
                }
                return
            }
            guard let request, let makeContent, let anchor, anchor.view.window != nil else { return }
            var presenter: UIViewController = anchor
            while let parent = presenter.parent { presenter = parent }
            guard presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
            let orientation = PlozziOSPlayerOrientation(preference: preference, isPlaybackActive: false)
            orientation.close = { [weak self] in self?.close(request.id) }
            let host = PlozziOSOrientationHostingController(
                rootView: makeContent(request, orientation), orientation: orientation
            )
            self.host = host
            presentedID = request.id
            transitioning = true
            presenter.present(host, animated: true) { [weak self] in
                self?.transitioning = false
                self?.reconcile()
            }
        }
    }
}
#endif
