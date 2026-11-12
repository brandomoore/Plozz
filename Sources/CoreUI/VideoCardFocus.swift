import SwiftUI
#if os(tvOS)
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
        if let configuration {
            VideoCardSurface(configuration: configuration, content: content, background: background)
                .transition(.identity)
        } else {
            content
                .transition(.identity)
        }
        #else
        content
        #endif
    }
}

#if os(tvOS)
@MainActor @Observable
public final class VideoCardEntryTransition {
    public private(set) var scale = CGSize(width: 1, height: 1)
    public private(set) var offset = CGSize.zero
    public private(set) var isActive = false
    private var revision = 0

    public init() {}

    public func prepare(from source: CGRect, to destination: CGRect) {
        revision += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isActive = true
            scale = CGSize(width: source.width / destination.width, height: source.height / destination.height)
            offset = CGSize(width: source.midX - destination.midX, height: source.midY - destination.midY)
        }
    }

    public func animate() {
        let revision = revision
        withAnimation(MultiviewMotion.animation) {
            scale = CGSize(width: 1, height: 1)
            offset = .zero
        } completion: {
            if self.revision == revision { self.isActive = false }
        }
    }

    public func cancel() {
        revision += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scale = CGSize(width: 1, height: 1)
            offset = .zero
            isActive = false
        }
    }
}

public extension EnvironmentValues {
    @Entry var videoCardEntryTransition: VideoCardEntryTransition?
}

private struct VideoCardSurface<Content: View>: View {
    let configuration: VideoCardFocus
    let content: Content
    let background: AnyView
    @FocusState private var focused: Bool
    @State private var handledRequest: Int?
    @State private var handledEffect: Bool?
    @State private var restoringEffect = false
    @State private var interactionState = VideoCardInteractionState()
    @State private var entryTransition = VideoCardEntryTransition()

    var body: some View {
        button
            .buttonStyle(VideoCardButtonStyle(
                presentsEffect: configuration.presentsEffect,
                restoringEffect: restoringEffect || handledEffect != true && configuration.presentsEffect))
            .geometryGroup()
            .background { background.allowsHitTesting(false).accessibilityHidden(true) }
            .scaleEffect(entryTransition.scale)
            .offset(entryTransition.offset)
            .modifier(VideoCardInset(horizontalInset: configuration.horizontalInset))
            .environment(\.videoCardEntryTransition, entryTransition)
        .focusSection()
        .onChange(of: focused) { _, value in
            configuration.focused(value)
            if !value { restoringEffect = false }
        }
        .task(id: FocusRequest(revision: configuration.request, effect: configuration.presentsEffect)) {
            let explicitRequest = handledRequest != configuration.request
            let restoresEffect = handledEffect != true && configuration.presentsEffect
            handledRequest = configuration.request
            handledEffect = configuration.presentsEffect
            guard explicitRequest ? configuration.prefersFocus : configuration.audible else { return }
            // A style replacement has a new native focus owner even when this binding was already true.
            focused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            restoringEffect = restoresEffect
            focused = true
        }
        .onExitCommand(perform: configuration.back)
    }

    private struct FocusRequest: Equatable {
        let revision: Int
        let effect: Bool
    }

    private var button: some View {
        Button {
            if !interactionState.isPresentingMenu { configuration.activate() }
        } label: {
            content
                .clipShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    configuration.caption
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
                .background(VideoCardContextMenu(configuration: configuration, interactionState: interactionState))
        }
        .buttonBorderShape(.roundedRectangle(radius: configuration.cornerRadius))
        .focused($focused)
        .accessibilityLabel(Text(verbatim: configuration.title))
        .accessibilityValue(configuration.audible ? Text("Audio on") : Text("Muted"))
        .accessibilityIdentifier(configuration.identifier)
    }
}

@MainActor
private final class VideoCardInteractionState {
    var isPresentingMenu = false
}

private struct VideoCardContextMenu: UIViewRepresentable {
    let configuration: VideoCardFocus
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

private struct VideoCardButtonStyle: PrimitiveButtonStyle {
    let presentsEffect: Bool
    let restoringEffect: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if presentsEffect {
            Button(configuration).buttonStyle(.card)
                .transaction {
                    // The whole card owns entry motion; later focus moves remain native.
                    if restoringEffect {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
                }
                .transition(.identity)
        } else {
            configuration.label
                .focusable()
                .focusEffectDisabled()
                .onTapGesture(perform: configuration.trigger)
                .transition(.identity)
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
