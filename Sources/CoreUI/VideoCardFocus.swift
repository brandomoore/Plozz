import SwiftUI

/// Focus belongs to the video surface, not the player or its transport controls.
public struct VideoCardFocus {
    public let identifier: String
    public let title: String
    public let audible: Bool
    public let presentsEffect: Bool
    public let cornerRadius: CGFloat
    public let horizontalInset: CGFloat
    public let request: Int
    public let prefersFocus: Bool
    public let focused: (Bool) -> Void
    public let activate: () -> Void
    public let promote: () -> Void
    public let replace: () -> Void
    public let back: () -> Void
    public let caption: AnyView

    public init(
        identifier: String, title: String, audible: Bool, presentsEffect: Bool,
        cornerRadius: CGFloat, horizontalInset: CGFloat, request: Int, prefersFocus: Bool,
        focused: @escaping (Bool) -> Void, activate: @escaping () -> Void,
        promote: @escaping () -> Void, replace: @escaping () -> Void,
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
        } else {
            content
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - configuration.horizontalInset * 2)
            let height = geometry.size.height * width / max(1, geometry.size.width)
            button
            .buttonStyle(VideoCardButtonStyle(presentsEffect: configuration.presentsEffect))
            .modifier(VideoCardFrame(size: CGSize(width: width, height: height)))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: width)
        }
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
        }
        .buttonBorderShape(.roundedRectangle(radius: configuration.cornerRadius))
        .focused($focused)
        .accessibilityLabel(Text(verbatim: configuration.title))
        .accessibilityValue(configuration.audible ? Text("Audio on") : Text("Muted"))
        .accessibilityIdentifier(configuration.identifier)
        .contextMenu {
            Button("Make main picture", systemImage: "rectangle.inset.filled", action: configuration.promote)
            Button("Replace channel", systemImage: "arrow.triangle.2.circlepath", action: configuration.replace)
        }
    }
}

private struct VideoCardButtonStyle: PrimitiveButtonStyle {
    let presentsEffect: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if presentsEffect {
            Button(configuration).buttonStyle(.card)
        } else {
            configuration.label
                .focusable()
                .focusEffectDisabled()
                .onTapGesture(perform: configuration.trigger)
        }
    }
}

private struct VideoCardFrame: ViewModifier, Animatable {
    var size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    func body(content: Content) -> some View {
        content.frame(width: size.width, height: size.height)
    }
}
#endif
