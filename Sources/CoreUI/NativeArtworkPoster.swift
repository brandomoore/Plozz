#if os(tvOS)
import SwiftUI

/// Native artwork focus with captions outside the surface, matching media posters.
public struct NativeArtworkPoster<Artwork: View, Overlay: View>: View {
    private let width: CGFloat
    private let aspectRatio: CGFloat
    private let title: NativePosterText
    private let subtitle: String? // l10n:content — library metadata
    private let placeholderSymbol: String
    private let focus: PlozzCardFocus.Binding
    private let action: () -> Void
    private let artwork: Artwork
    private let overlay: Overlay
    private let placeholderTint: Color?
    @State private var resolution = ArtworkResolutionState()
    @Environment(\.plozzMetrics) private var metrics

    public init(
        width: CGFloat,
        aspectRatio: CGFloat = 1,
        title: String, // l10n:content — library title
        subtitle: String?, // l10n:content — library metadata
        localizedTitle: LocalizedStringResource? = nil,
        placeholderSymbol: String,
        placeholderTint: Color? = nil,
        focus: PlozzCardFocus.Binding,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.width = width
        self.aspectRatio = aspectRatio
        self.title = localizedTitle.map(NativePosterText.localized) ?? .content(title)
        self.subtitle = subtitle
        self.placeholderSymbol = placeholderSymbol
        self.focus = focus
        self.action = action
        self.artwork = artwork()
        self.overlay = overlay()
        self.placeholderTint = placeholderTint
    }

    public var body: some View {
        VStack(spacing: metrics.nativePosterCaptionSpacing) {
            NativeTVPoster(
                image: resolution.image, treatment: .original, aspectRatio: aspectRatio,
                fallbackWidth: width, title: title, subtitle: subtitle,
                overlay: ZStack {
                    if resolution.image == nil {
                        if let placeholderTint {
                            LinearGradient(
                                colors: [placeholderTint.opacity(0.55), Color(white: 0.07)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        } else {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                        }
                    }
                    overlay
                },
                focus: focus, action: action
            )
            .focused(focus.focusState)
            .frame(width: width)
            SystemPosterCaption(
                title: title, subtitle: subtitle,
                reservesSubtitleSpace: true, isFocused: focus.observation.isFocused
            )
            .frame(width: width)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .background {
            artwork
                .environment(\.artworkResolutionState, resolution)
                .frame(width: width, height: width / aspectRatio)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

public extension NativeArtworkPoster where Overlay == EmptyView {
    init(
        width: CGFloat,
        aspectRatio: CGFloat = 1,
        title: String, // l10n:content — library title
        subtitle: String?, // l10n:content — library metadata
        localizedTitle: LocalizedStringResource? = nil,
        placeholderSymbol: String,
        focus: PlozzCardFocus.Binding,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.init(
            width: width, aspectRatio: aspectRatio, title: title, subtitle: subtitle,
            localizedTitle: localizedTitle, placeholderSymbol: placeholderSymbol,
            focus: focus, action: action, artwork: artwork, overlay: { EmptyView() }
        )
    }
}
#endif
