#if canImport(SwiftUI)
import CoreUI
import SwiftUI

public enum PlayerTouchLayout {
    public static let edgeInset: CGFloat = 24
    public static let horizontalInset: CGFloat = 21
    public static let playDiameter: CGFloat = 92
    public static let skipDiameter: CGFloat = 64
    public static let timelineRowHeight: CGFloat = 38
    public static let cardSpacing: CGFloat = 12

    public static func usesCompactTransport(contentHeight: CGFloat) -> Bool {
        contentHeight > 0 && contentHeight < 352
    }

    public static func usesCompactTransport(in viewport: CGSize) -> Bool {
        usesCompactTransport(contentHeight: viewport.height - 2 * edgeInset)
    }

    public static func usesCompactTitle(in viewport: CGSize) -> Bool {
        viewport.height > 0 && viewport.height < 352
    }

    public static func transportSpacing(in viewport: CGSize) -> CGFloat {
        transportSpacing(
            availableWidth: viewport.width - 2 * horizontalInset, portrait: viewport.height > viewport.width
        )
    }

    public static func transportSpacing(availableWidth: CGFloat, portrait: Bool = false) -> CGFloat {
        min(portrait ? 39 : 68, max(0, (availableWidth - playDiameter - 2 * skipDiameter) / 2))
    }

    public static func scrubPreviewSize(availableSize: CGSize, maximumWidth: CGFloat = 360) -> CGSize {
        let height = max(0, availableSize.height - 2 * edgeInset - 44 - timelineRowHeight - 24)
        let width = max(0, min(maximumWidth, availableSize.width - 2 * horizontalInset, height * 16 / 9))
        return CGSize(width: width, height: width * 9 / 16)
    }
}

#if os(iOS)
public struct PlayerTouchScrubPreview: View {
    private let image: CGImage?
    private let size: CGSize

    public init(image: CGImage?, availableSize: CGSize, maximumWidth: CGFloat = 360) {
        self.image = image
        self.size = PlayerTouchLayout.scrubPreviewSize(availableSize: availableSize, maximumWidth: maximumWidth)
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.72))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

public extension View {
    func playerTouchChromeHidden(_ hidden: Bool) -> some View {
        modifier(PlayerTouchChromeVisibility(hidden: hidden))
    }
}

private struct PlayerTouchChromeVisibility: ViewModifier {
    let hidden: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        // Opacity alone leaves native glass controls in the accessibility tree.
        if hidden {
            content.hidden()
        } else {
            content
        }
    }
}

extension View {
    func playerTouchPanelAction() -> some View {
        buttonStyle(PlayerTouchPanelActionStyle())
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PlayerTouchPanelActionStyle: PrimitiveButtonStyle {
    @Environment(\.playerControlForeground) private var foreground

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .foregroundStyle(foreground)
                .frame(minWidth: 20, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .tint(foreground)
    }
}

/// Keep native edge margins without adding them to the window's safe area.
public struct PlayerTouchChromePadding: ViewModifier {
    private let isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    public func body(content: Content) -> some View {
        content.modifier(WindowSafeAreaPadding(
            isEnabled: isEnabled, minimumInset: PlayerTouchLayout.edgeInset,
            minimumHorizontalInset: PlayerTouchLayout.horizontalInset
        ))
    }
}
#endif

public struct PlayerGlassControlGroup<Content: View>: View {
    private let content: Content
    @Environment(\.playerUsesNativeGlass) private var nativeGlass

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Group {
            if nativeGlass, #available(iOS 26.0, tvOS 26.0, *) {
                #if os(iOS)
                controls.glassEffect(.clear, in: Capsule())
                #else
                controls.glassEffect(.regular, in: Capsule())
                #endif
            } else {
                controls
                    .plozzFrostedBackground(Capsule())
                    .plozzFrostedBorder(Capsule())
            }
        }
        .environment(\.playerControlsGrouped, true)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack(spacing: 12) { content }
    }
}

private struct PlayerControlsGroupedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var playerControlsGrouped: Bool {
        get { self[PlayerControlsGroupedKey.self] }
        set { self[PlayerControlsGroupedKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func playerTouchTab(selected: Bool) -> some View {
        modifier(PlayerTouchTabModifier(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlayerTouchTabModifier: ViewModifier {
    let selected: Bool
    @Environment(\.playerUsesNativeGlass) private var nativeGlass

    func body(content: Content) -> some View {
        if nativeGlass, #available(iOS 26.0, tvOS 26.0, *) {
            content
                .buttonStyle(PlayerNativeTouchTabStyle())
                .controlSize(.regular)
                .buttonSizing(.flexible)
                .frame(minHeight: 44)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            content.buttonStyle(PlayerTabButtonStyle(focused: false, selected: selected))
        }
    }
}

@available(iOS 26.0, tvOS 26.0, *)
private struct PlayerNativeTouchTabStyle: PrimitiveButtonStyle {
    @Environment(\.playerControlForeground) private var foreground

    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            button(configuration).buttonStyle(.glass(.clear))
        } else {
            button(configuration).buttonStyle(PlayerClearTouchTabStyle())
        }
        #else
        button(configuration).buttonStyle(.glass)
        #endif
    }

    private func button(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 2)
                .frame(minHeight: 28)
        }
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private struct PlayerClearTouchTabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.clear.interactive(), in: Capsule())
    }
}
#endif
#endif
