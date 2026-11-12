import SwiftUI
#if os(tvOS)
import CoreNetworking
import TVUIKit
import UIKit
#endif

/// Shared picture-layout and renderer-entry motion, separate from native focus timing.
public enum MultiviewMotion {
    public static var duration: TimeInterval {
        #if os(tvOS)
        0.5
        #else
        0.32
        #endif
    }

    public static var animation: Animation { .easeInOut(duration: duration) }
}

/// Focus belongs to the video surface, not the player or its transport controls.
public struct VideoCardFocus {
    public let identifier: String
    public let title: String
    public let audible: Bool
    public let presentsEffect: Bool
    public let cornerRadius: CGFloat
    public var horizontalInset: CGFloat
    public let request: Int
    public let prefersFocus: Bool
    public let focused: (Bool) -> Void
    public let activate: () -> Void
    public let promote: () -> Void
    public let replace: () -> Void
    public let remove: (() -> Void)?
    public let back: () -> Void
    public let caption: AnyView

    public init(
        identifier: String, title: String, audible: Bool, presentsEffect: Bool,
        cornerRadius: CGFloat, horizontalInset: CGFloat, request: Int, prefersFocus: Bool,
        focused: @escaping (Bool) -> Void, activate: @escaping () -> Void,
        promote: @escaping () -> Void, replace: @escaping () -> Void,
        remove: (() -> Void)? = nil,
        back: @escaping () -> Void = {}, caption: AnyView = AnyView(EmptyView())
    ) {
        self.identifier = identifier
        self.title = title
        self.audible = audible
        self.presentsEffect = presentsEffect
        self.cornerRadius = cornerRadius
        self.horizontalInset = horizontalInset
        self.request = request
        self.prefersFocus = prefersFocus
        self.focused = focused
        self.activate = activate
        self.promote = promote
        self.replace = replace
        self.remove = remove
        self.back = back
        self.caption = caption
    }
}

private struct VideoCardFocusKey: EnvironmentKey {
    static let defaultValue: VideoCardFocus? = nil
}

public extension EnvironmentValues {
    var videoCardFocus: VideoCardFocus? {
        get { self[VideoCardFocusKey.self] }
        set { self[VideoCardFocusKey.self] = newValue }
    }
}

public extension View {
    func videoCardFocusSurface() -> some View {
        modifier(VideoCardFocusModifier(background: AnyView(EmptyView())))
    }

    func videoCardFocusSurface<Background: View>(@ViewBuilder background: () -> Background) -> some View {
        modifier(VideoCardFocusModifier(background: AnyView(background())))
    }
}

private struct VideoCardFocusModifier: ViewModifier {
    @Environment(\.videoCardFocus) private var configuration
    let background: AnyView

    func body(content: Content) -> some View {
        #if os(tvOS)
        VideoCardSurface(configuration: configuration, content: content, background: background)
            .transition(.identity)
        #else
        content
        #endif
    }
}

#if os(tvOS)
private struct VideoCardSurface<Content: View>: View {
    let configuration: VideoCardFocus?
    let content: Content
    let background: AnyView
    @FocusState private var focused: Bool
    @State private var interactionState = VideoCardInteractionState()

    var body: some View {
        NativeVideoCard(configuration: configuration, focus: $focused, interactionState: interactionState,
                        background: background, content:
            content
                .clipShape(RoundedRectangle(cornerRadius: configuration?.cornerRadius ?? 0, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    configuration?.caption
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .background(VideoCardContextMenu(configuration: configuration, interactionState: interactionState)))
            .focused($focused)
            .modifier(VideoCardInset(horizontalInset: configuration?.horizontalInset ?? 0))
            .focusSection()
            .onExitCommand { configuration?.back() }
    }
}

/// One native content owner survives idle, editing and full-screen layout changes.
private struct NativeVideoCard<Content: View>: UIViewRepresentable {
    let configuration: VideoCardFocus?
    let focus: FocusState<Bool>.Binding
    let interactionState: VideoCardInteractionState
    let background: AnyView
    let content: Content

    func makeUIView(context: Context) -> Container {
        let container = Container(background: backgroundConfiguration(context).makeContentView())
        let host = hostingConfiguration(context).makeContentView()
        container.host = host
        container.card.contentView.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.card.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.card.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.card.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.card.contentView.bottomAnchor)
        ])
        return container
    }

    func updateUIView(_ view: Container, context: Context) {
        view.focus = focus
        view.update(configuration, enabled: context.environment.isEnabled,
                    reduceMotion: context.environment.accessibilityReduceMotion)
        view.interactionState = interactionState
        view.host?.configuration = hostingConfiguration(context)
        view.backgroundHost.configuration = backgroundConfiguration(context)
        let value: LocalizedStringResource = configuration?.audible == true ? "Audio on" : "Muted"
        var localizedValue = value
        localizedValue.locale = context.environment.locale
        let presentsEffect = configuration?.presentsEffect == true
        for (target, active) in [(view.idle as UIView, configuration != nil && !presentsEffect),
                                 (view.card as UIView, presentsEffect)] {
            target.isAccessibilityElement = active
            target.accessibilityElementsHidden = !active
            target.accessibilityIdentifier = active ? configuration?.identifier : nil
            target.accessibilityLabel = active ? configuration?.title : nil
            target.accessibilityValue = active ? String(localized: localizedValue) : nil
            target.accessibilityTraits = active ? .button : []
        }
    }

    private func hostingConfiguration(_ context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .environment(\.self, context.environment)
                .ignoresSafeArea()
        }
            .margins(.all, 0)
    }

    private func backgroundConfiguration(_ context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            background
                .environment(\.self, context.environment)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .ignoresSafeArea()
        }
        .margins(.all, 0)
    }

    final class Container: UIView {
        let card = Card()
        let idle = IdleControl()
        private let motion = UIView()
        private let backing = UIView()
        let backgroundHost: UIView & UIContentView
        var host: (UIView & UIContentView)?
        var interactionState: VideoCardInteractionState?
        var focus: FocusState<Bool>.Binding?
        private var configuration: VideoCardFocus?
        private var reduceMotion = false
        private var origin: CGRect?
        private var animator: UIViewPropertyAnimator?
        private var requestsFocus = false
        private var explicitFocusRequest: Bool?
        private var requestScheduled = false
        private var changingMode = false
        private var reportedFocus = false
        private var nativeFocusInsets = NSDirectionalEdgeInsets.zero

        init(background: UIView & UIContentView) {
            backgroundHost = background
            super.init(frame: .zero)
            nativeFocusInsets = card.focusSizeIncrease
            // Apply TVUIKit's sizing to the complete surface, not a second
            // independently animated transform inside the card.
            card.focusSizeIncrease = .zero
            addSubview(motion)
            addSubview(idle)
            motion.addSubview(background)
            motion.addSubview(card)
            backing.backgroundColor = .black
            backing.isUserInteractionEnabled = false
            card.contentView.addSubview(backing)
            background.isUserInteractionEnabled = false
            card.contentView.clipsToBounds = false
            card.onFocus = { [weak self] coordinator in self?.nativeFocusChanged(coordinator) }
            idle.onFocus = { [weak self] in self?.reportFocus() }
            let action = UIAction { [weak self] _ in
                guard let self, self.interactionState?.isPresentingMenu != true else { return }
                self.configuration?.activate()
            }
            idle.addAction(action, for: .primaryActionTriggered)
            card.addAction(action, for: .primaryActionTriggered)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            card.eligible ? [card] : [idle]
        }

        func update(_ next: VideoCardFocus?, enabled: Bool, reduceMotion: Bool) {
            let modeChanged = configuration?.presentsEffect != next?.presentsEffect
            if modeChanged, window != nil, !card.contentView.bounds.isEmpty {
                let layer = card.contentView.layer.presentation() ?? card.contentView.layer
                origin = layer.convert(layer.bounds, to: window?.layer.presentation() ?? window?.layer)
                animator?.stopAnimation(true)
                animator = nil
                changingMode = true
            }
            let explicitRequest = configuration?.request != next?.request
            // A destination chosen while waking supersedes the old control's
            // focus until the pending native handoff finishes.
            if explicitRequest { explicitFocusRequest = next?.prefersFocus == true }
            requestsFocus = explicitFocusRequest
                ?? (requestsFocus || (modeChanged && (idle.isFocused || card.isFocused || next?.audible == true)))
            configuration = next
            self.reduceMotion = reduceMotion
            card.eligible = enabled && next?.presentsEffect == true
            idle.eligible = enabled && next != nil && next?.presentsEffect != true
            idle.isUserInteractionEnabled = idle.eligible
            idle.isHidden = !idle.eligible
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                animator?.stopAnimation(true)
                animator = nil
                origin = nil
            }
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty else { return }
            let resized = motion.bounds.size != bounds.size
            idle.frame = bounds
            motion.bounds = bounds
            motion.center = CGPoint(x: bounds.midX, y: bounds.midY)
            backgroundHost.frame = bounds
            card.contentSize = bounds.size
            let intrinsic = card.intrinsicContentSize
            card.frame = bounds.insetBy(dx: -max(0, intrinsic.width - bounds.width) / 2,
                                       dy: -max(0, intrinsic.height - bounds.height) / 2)
            card.layoutIfNeeded()
            // Cover the floating clip where the video and native corner masks
            // diverge, without expanding the hosted content's layout or hit area.
            backing.frame = card.contentView.bounds.insetBy(dx: -40, dy: -40)
            if changingMode { preserveOrigin() }
            else if resized, animator?.isRunning != true {
                UIView.performWithoutAnimation { motion.transform = focusTransform }
            }
            scheduleFocusUpdate()
        }

        private var focusTransform: CGAffineTransform {
            guard card.isFocused, card.eligible, !bounds.isEmpty else { return .identity }
            let width = bounds.width - nativeFocusInsets.leading - nativeFocusInsets.trailing
            let height = bounds.height - nativeFocusInsets.top - nativeFocusInsets.bottom
            let scale = min(width / bounds.width, height / bounds.height)
            return CGAffineTransform(scaleX: scale, y: scale)
        }

        private func nativeFocusChanged(_ coordinator: UIFocusAnimationCoordinator) {
            reportFocus()
            guard !changingMode else { return }
            if let animator, animator.isRunning {
                animator.stopAnimation(false)
                animator.finishAnimation(at: .current)
                self.animator = nil
            }
            if reduceMotion {
                UIView.performWithoutAnimation { motion.transform = focusTransform }
                return
            }
            coordinator.addCoordinatedAnimations { [weak self] in
                guard let self else { return }
                self.motion.transform = self.focusTransform
            }
        }

        private func scheduleFocusUpdate() {
            guard window != nil, !requestScheduled,
                  requestsFocus || changingMode || explicitFocusRequest != nil else { return }
            requestScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer {
                    self.requestScheduled = false
                    self.explicitFocusRequest = nil
                }
                guard let window = self.window else { return }
                window.layoutIfNeeded()
                if self.requestsFocus {
                    self.requestsFocus = false
                    let target: UIView = self.card.eligible ? self.card : self.idle
                    if target.canBecomeFocused, let system = UIFocusSystem.focusSystem(for: target) {
                        let update = {
                            self.focus?.wrappedValue = true
                            window.layoutIfNeeded()
                            system.requestFocusUpdate(to: target)
                            system.updateFocusIfNeeded()
                            self.card.layoutIfNeeded()
                        }
                        if self.changingMode || self.reduceMotion {
                            UIView.performWithoutAnimation {
                                var transaction = Transaction(animation: nil)
                                transaction.disablesAnimations = true
                                withTransaction(transaction, update)
                            }
                        }
                        else { update() }
                        if !target.isFocused {
                            PlozzLog.app.debug("Video card focus request was not accepted by the current focus scope")
                        }
                    }
                }
                self.finishModeChange()
            }
        }

        private func preserveOrigin() {
            guard let origin, let window else { return }
            UIView.performWithoutAnimation {
                motion.transform = .identity
                let target = card.contentView.convert(card.contentView.bounds, to: window)
                guard !target.isEmpty else { return }
                motion.transform = CGAffineTransform(
                    translationX: origin.midX - target.midX, y: origin.midY - target.midY)
                    .scaledBy(x: origin.width / target.width, y: origin.height / target.height)
            }
        }

        private func finishModeChange() {
            guard changingMode else { return }
            preserveOrigin()
            changingMode = false
            guard origin != nil else { return }
            self.origin = nil
            if reduceMotion {
                motion.transform = focusTransform
            } else {
                let animator = UIViewPropertyAnimator(duration: MultiviewMotion.duration, curve: .easeInOut) { [weak self] in
                    guard let self else { return }
                    self.motion.transform = self.focusTransform
                }
                self.animator = animator
                animator.startAnimation()
            }
        }

        private func reportFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let focused = self.idle.isFocused || self.card.isFocused
                guard focused != self.reportedFocus else { return }
                self.reportedFocus = focused
                self.configuration?.focused(focused)
            }
        }
    }

    final class Card: TVCardView {
        var eligible = false
        var onFocus: ((UIFocusAnimationCoordinator) -> Void)?
        override var canBecomeFocused: Bool { eligible && super.canBecomeFocused }
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(coordinator)
        }

    }

    final class IdleControl: UIControl {
        var eligible = false
        var onFocus: (() -> Void)?
        override var canBecomeFocused: Bool { eligible }
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?()
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if isFocused, presses.contains(where: { $0.type == .select }) {
                sendActions(for: .primaryActionTriggered)
            } else {
                super.pressesEnded(presses, with: event)
            }
        }
    }
}

@MainActor
private final class VideoCardInteractionState {
    var isPresentingMenu = false
}

private struct VideoCardContextMenu: UIViewRepresentable {
    let configuration: VideoCardFocus?
    let interactionState: VideoCardInteractionState
    @Environment(\.videoCardFocusMemory) private var focusMemory
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> MenuView { MenuView() }

    func updateUIView(_ view: MenuView, context: Context) {
        view.configuration = isEnabled ? configuration : nil
        view.interactionState = interactionState
        view.focusMemory = focusMemory
        view.locale = locale
        view.scheduleFocusCheck()
    }

    static func dismantleUIView(_ view: MenuView, coordinator: ()) { view.stop() }

    final class MenuView: UIView, UIContextMenuInteractionDelegate {
        var configuration: VideoCardFocus?
        var interactionState: VideoCardInteractionState?
        weak var focusMemory: VideoCardFocusMemory?
        var locale = Locale.current
        private lazy var interaction = UIContextMenuInteraction(delegate: self)
        private var isPresented = false
        private var pendingAction: (() -> Void)?
        private var pendingCheck: Task<Void, Never>?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { stop(); return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusChanged(_:)),
                name: UIFocusSystem.didUpdateNotification, object: nil)
            scheduleFocusCheck()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleFocusCheck()
        }

        @objc private func focusChanged(_ notification: Notification) {
            if configuration != nil,
               let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
               let next = context.nextFocusedItem, containsPicture(next) {
                focusMemory?.target = next
            }
            scheduleFocusCheck()
        }

        private func containsPicture(_ item: any UIFocusItem) -> Bool {
            if let view = item as? UIView, isDescendant(of: view) { return true }
            guard let frame = NativeFocusRegion.frame(of: item, in: self) else { return false }
            return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                && abs(frame.width - bounds.width) <= max(32, bounds.width * 0.05)
                && abs(frame.height - bounds.height) <= max(32, bounds.height * 0.05)
        }

        func scheduleFocusCheck() {
            pendingCheck?.cancel()
            pendingCheck = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                guard self.configuration != nil else { self.detach(); return }
                guard !self.isPresented else { return }
                guard let window = self.window,
                      let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                      self.containsPicture(focused),
                      let target = focused as? UIView ?? NativeFocusRegion.owningController(of: focused)?.viewIfLoaded else {
                    self.detach()
                    return
                }
                self.focusMemory?.target = focused
                guard self.interaction.view !== target else { return }
                self.detach()
                target.addInteraction(self.interaction)
            }
        }

        private func detach() {
            pendingAction = nil
            interaction.dismissMenu()
            interaction.view?.removeInteraction(interaction)
            isPresented = false
            interactionState?.isPresentingMenu = false
        }

        func stop() {
            pendingCheck?.cancel()
            pendingCheck = nil
            NotificationCenter.default.removeObserver(self)
            detach()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let configuration, window != nil else { return nil }
            func action(
                _ title: LocalizedStringResource, symbol: String, destructive: Bool = false,
                perform: @escaping () -> Void
            ) -> UIAction {
                var localizedTitle = title
                localizedTitle.locale = locale
                return UIAction(
                    title: String(localized: localizedTitle), image: UIImage(systemName: symbol),
                    attributes: destructive ? .destructive : []
                ) { [weak self] _ in
                    guard let self, self.configuration?.identifier == configuration.identifier else { return }
                    self.pendingAction = perform
                }
            }
            var actions = [
                action("Make main video", symbol: "rectangle.inset.filled", perform: configuration.promote),
                action("Replace channel", symbol: "arrow.triangle.2.circlepath", perform: configuration.replace)
            ]
            if let remove = configuration.remove {
                actions.append(action("Remove", symbol: "minus.circle", destructive: true, perform: remove))
            }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: actions) }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            isPresented = true
            interactionState?.isPresentingMenu = true
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            menuPreview()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            menuPreview()
        }

        private func menuPreview() -> UITargetedPreview? {
            guard window != nil else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            // Anchor the menu to the picture without snapshotting or moving its live renderer.
            return UITargetedPreview(view: self, parameters: parameters)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?
        ) {
            let identifier = self.configuration?.identifier
            let complete: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.isPresented = false
                self.interactionState?.isPresentingMenu = false
                self.scheduleFocusCheck()
                let action = self.pendingAction
                self.pendingAction = nil
                guard self.window != nil, self.configuration?.identifier == identifier else { return }
                action?()
                self.scheduleFocusCheck()
            }
            // The native preview must return to its original bounds before those bounds change.
            if let animator { animator.addCompletion(complete) }
            else { complete() }
        }

        deinit {
            pendingCheck?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// Scoped to one Multiview workspace; remembers the actual native picture owner.
@MainActor
public final class VideoCardFocusMemory {
    fileprivate weak var target: (any UIFocusItem)?
    public init() {}
}

private struct VideoCardFocusMemoryKey: EnvironmentKey {
    static let defaultValue: VideoCardFocusMemory? = nil
}

public extension EnvironmentValues {
    var videoCardFocusMemory: VideoCardFocusMemory? {
        get { self[VideoCardFocusMemoryKey.self] }
        set { self[VideoCardFocusMemoryKey.self] = newValue }
    }
}

/// Bridges the empty space above the toolbar before UIKit chooses a picture.
public struct VideoCardFocusReturnGuide: UIViewRepresentable {
    @Environment(\.videoCardFocusMemory) private var memory
    public init() {}

    public func makeUIView(context: Context) -> GuideView { GuideView() }
    public func updateUIView(_ view: GuideView, context: Context) { view.memory = memory }
    public static func dismantleUIView(_ view: GuideView, coordinator: ()) { view.stop() }

    public final class GuideView: UIView {
        fileprivate weak var memory: VideoCardFocusMemory?
        private let guide = UIFocusGuide()
        private var guideConstraints: [NSLayoutConstraint] = []

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            addLayoutGuide(guide)
            guideConstraints = [
                guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: trailingAnchor),
                guide.topAnchor.constraint(equalTo: topAnchor),
                guide.heightAnchor.constraint(equalToConstant: 32)
            ]
            NSLayoutConstraint.activate(guideConstraints)
            guide.isEnabled = false
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusChanged(_:)),
                name: UIFocusSystem.didUpdateNotification, object: nil)
        }

        @objc private func focusChanged(_ notification: Notification) {
            guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            let target = memory?.target
            let returning = NativeFocusRegion.contains(context.nextFocusedItem, in: self)
                && NativeFocusRegion.frame(of: target, in: self) != nil
            guide.preferredFocusEnvironments = returning ? target.map { [$0] } ?? [] : []
            guide.isEnabled = returning
        }

        fileprivate func stop() {
            NotificationCenter.default.removeObserver(self)
            guide.isEnabled = false
            guide.preferredFocusEnvironments = []
            NSLayoutConstraint.deactivate(guideConstraints)
            guideConstraints = []
            guide.owningView?.removeLayoutGuide(guide)
        }
    }
}

private struct VideoCardInset: ViewModifier {
    let horizontalInset: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - horizontalInset * 2)
            let height = geometry.size.height * width / max(1, geometry.size.width)
            content
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}
#endif
