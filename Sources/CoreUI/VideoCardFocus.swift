import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Shared picture-layout and renderer-entry motion, separate from native focus timing.
public enum MultiviewMotion {
    public static var animation: Animation {
        #if os(tvOS)
        .easeInOut(duration: 0.5)
        #else
        .easeInOut(duration: 0.32)
        #endif
    }
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
        modifier(VideoCardFocusModifier())
    }
}

private struct VideoCardFocusModifier: ViewModifier {
    @Environment(\.videoCardFocus) private var configuration

    func body(content: Content) -> some View {
        #if os(tvOS)
        if let configuration {
            VideoCardSurface(configuration: configuration, content: content)
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
private struct VideoCardSurface<Content: View>: View {
    let configuration: VideoCardFocus
    let content: Content
    @FocusState private var focused: Bool
    @State private var handledRequest: Int?

    var body: some View {
        button
            .buttonStyle(VideoCardButtonStyle(presentsEffect: configuration.presentsEffect))
            .modifier(VideoCardInset(horizontalInset: configuration.horizontalInset))
        .focusSection()
        .onChange(of: focused) { _, value in configuration.focused(value) }
        .task(id: FocusRequest(revision: configuration.request, effect: configuration.presentsEffect)) {
            let explicitRequest = handledRequest != configuration.request
            handledRequest = configuration.request
            guard explicitRequest ? configuration.prefersFocus : configuration.audible else { return }
            // A style replacement has a new native focus owner even when this binding was already true.
            focused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
        .onExitCommand(perform: configuration.back)
    }

    private struct FocusRequest: Equatable {
        let revision: Int
        let effect: Bool
    }

    private var button: some View {
        Button(action: configuration.activate) {
            content
                .clipShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    configuration.caption
                        .padding(16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .contentShape(RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous))
                .background(VideoCardContextMenu(configuration: configuration))
        }
        .buttonBorderShape(.roundedRectangle(radius: configuration.cornerRadius))
        .focused($focused)
        .accessibilityLabel(Text(verbatim: configuration.title))
        .accessibilityValue(configuration.audible ? Text("Audio on") : Text("Muted"))
        .accessibilityIdentifier(configuration.identifier)
    }
}

private struct VideoCardContextMenu: UIViewRepresentable {
    let configuration: VideoCardFocus
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> MenuView { MenuView() }

    func updateUIView(_ view: MenuView, context: Context) {
        view.configuration = isEnabled ? configuration : nil
        view.locale = locale
        view.scheduleFocusCheck()
    }

    static func dismantleUIView(_ view: MenuView, coordinator: ()) { view.stop() }

    final class MenuView: UIView, UIContextMenuInteractionDelegate {
        var configuration: VideoCardFocus?
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
                self, selector: #selector(focusChanged),
                name: UIFocusSystem.didUpdateNotification, object: nil)
            scheduleFocusCheck()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleFocusCheck()
        }

        @objc private func focusChanged() { scheduleFocusCheck() }

        func scheduleFocusCheck() {
            pendingCheck?.cancel()
            pendingCheck = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                guard self.configuration != nil else { self.detach(); return }
                guard !self.isPresented else { return }
                guard let window = self.window,
                      let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem,
                      let frame = NativeFocusRegion.frame(of: focused, in: self),
                      self.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                      abs(frame.width - self.bounds.width) <= max(32, self.bounds.width * 0.05),
                      abs(frame.height - self.bounds.height) <= max(32, self.bounds.height * 0.05),
                      let target = focused as? UIView ?? NativeFocusRegion.owningController(of: focused)?.viewIfLoaded else {
                    self.detach()
                    return
                }
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
                action("Make main picture", symbol: "rectangle.inset.filled", perform: configuration.promote),
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

private struct VideoCardButtonStyle: PrimitiveButtonStyle {
    let presentsEffect: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if presentsEffect {
            Button(configuration).buttonStyle(.card)
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
