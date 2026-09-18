#if os(tvOS)
import SwiftUI

/// Native artwork focus with captions outside the surface, matching media posters.
public struct NativeArtworkPoster<Artwork: View>: View {
    private let width: CGFloat
    private let aspectRatio: CGFloat
    private let title: NativePosterText
    private let subtitle: String? // l10n:content — library metadata
    private let placeholderSymbol: String
    private let focus: PlozzCardFocus.Binding
    private let action: () -> Void
    private let artwork: Artwork
    @State private var resolution = ArtworkResolutionState()
    @Environment(\.plozzMetrics) private var metrics

    public init(
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
        self.width = width
        self.aspectRatio = aspectRatio
        self.title = localizedTitle.map(NativePosterText.localized) ?? .content(title)
        self.subtitle = subtitle
        self.placeholderSymbol = placeholderSymbol
        self.focus = focus
        self.action = action
        self.artwork = artwork()
    }

    public var body: some View {
        VStack(spacing: metrics.nativePosterCaptionSpacing) {
            NativeTVPoster(
                image: resolution.image, treatment: .original, aspectRatio: aspectRatio,
                fallbackWidth: width, title: title, subtitle: subtitle,
                overlay: Group {
                    if resolution.image == nil {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }
                },
                focus: focus, action: action
            )
            .focused(focus.focusState)
            .frame(width: width)
            SystemPosterCaption(
                title: title, subtitle: subtitle,
                reservesSubtitleSpace: true, isFocused: focus.observed.wrappedValue
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
#endif
