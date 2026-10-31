#if os(tvOS)
import CoreModels
import SwiftUI

/// A rail action, not a media item: no playback, watch-state, or context menu.
public struct MediaRowBrowseCard: View {
    private let width: CGFloat
    private let style: PosterCardView.Style
    private let showsSeriesArtwork: Bool
    private let featuredSize: CGSize?
    private let onFocus: () -> Void
    private let action: () -> Void
    @PlozzCardFocus private var focused: Bool
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.plozzCardCaptionsHidden) private var captionsHidden
    @Environment(\.plozzContinueWatchingCaptionsHidden) private var continueWatchingCaptionsHidden
    @Environment(\.plozzContinueWatchingCaptionsHiddenWithArtworkTitle) private var artworkCaptionsHidden
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.plozzContinueWatchingPlaybackDetails) private var playbackDetails

    public init(
        width: CGFloat, style: PosterCardView.Style = .poster, showsSeriesArtwork: Bool = false,
        featuredSize: CGSize? = nil, onFocus: @escaping () -> Void = {}, action: @escaping () -> Void
    ) {
        self.width = width
        self.style = style
        self.showsSeriesArtwork = showsSeriesArtwork
        self.featuredSize = featuredSize
        self.onFocus = onFocus
        self.action = action
    }

    private var aspectRatio: CGFloat {
        if let featuredSize { return featuredSize.width / featuredSize.height }
        if style == .poster { return showsSeriesArtwork ? playbackDetails.cardAspectRatio : 2 / 3 }
        return showsSeriesArtwork ? ContinueWatchingCardShape.aspectRatio : 16 / 9
    }

    private var showsCaption: Bool {
        if featuredSize != nil { return false }
        if showsSeriesArtwork || artworkPolicy.area == .continueWatching {
            return !(showsSeriesArtwork ? artworkCaptionsHidden : continueWatchingCaptionsHidden)
        }
        return !captionsHidden
    }

    private var radius: CGFloat {
        if featuredSize != nil { return 20 }
        return style == .poster ? metrics.posterArtworkCornerRadius : metrics.landscapeArtworkCornerRadius
    }

    public var body: some View {
        control
            .frame(width: width)
            .accessibilityLabel(Text("See all"))
            .accessibilityIdentifier("home-row-see-all")
            .onChange(of: focused) { _, value in if value { onFocus() } }
    }

    @ViewBuilder
    private var control: some View {
        if let featuredSize {
            if focusStyle.usesSystemEffect {
                NativeTVPoster(
                    image: nil, treatment: .original, aspectRatio: aspectRatio, fallbackWidth: width,
                    title: .localized("See all"), subtitle: nil, overlay: label,
                    focus: $focused, action: action
                )
                .frame(width: featuredSize.width, height: featuredSize.height)
            } else {
                artwork.frame(width: featuredSize.width, height: featuredSize.height)
                    .plozzFocusHalo(cornerRadius: radius, focusScale: 1.04, isFocused: focused)
                    .focusableCard(isFocused: $focused, cornerRadius: radius, action: action)
                    .plozzCardFocusTransition(isFocused: focused)
            }
        } else if cardStyle == .borderless, focusStyle.usesSystemEffect {
            let artworkWidth = width - 2 * metrics.borderlessCardSideMargin
            VStack(spacing: metrics.nativePosterCaptionSpacing) {
                NativeTVPoster(
                    image: nil, treatment: .original, aspectRatio: aspectRatio, fallbackWidth: artworkWidth,
                    title: .localized("See all"), subtitle: nil, overlay: label, focus: $focused, action: action
                )
                .frame(width: artworkWidth)
                if showsCaption {
                    SystemPosterCaption(
                        title: .localized("See all"), subtitle: nil, reservesSubtitleSpace: true, isFocused: focused
                    )
                    .frame(width: artworkWidth)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, metrics.borderlessCardSideMargin)
        } else {
            styledCard
                .focusableCard(isFocused: $focused, cornerRadius: radius, action: action)
                .plozzCardFocusTransition(isFocused: focused)
        }
    }

    @ViewBuilder
    private var styledCard: some View {
        if cardStyle == .framed {
            VStack(spacing: style == .poster ? metrics.posterCaptionTopSpacing : metrics.landscapeCaptionTopSpacing) {
                artwork.aspectRatio(aspectRatio, contentMode: .fit)
                if showsCaption {
                    caption.padding(.bottom, style == .poster ? metrics.posterCaptionInset : metrics.landscapeCaptionInset)
                }
            }
            .plozzFramedMediaCard(innerCornerRadius: radius, isFocused: focused && focusStyle.drawsFocusOutline)
            .plozzRestingCardShadow(isFocused: focused)
            .plozzCardFocusLift(
                isFocused: focused, cornerRadius: radius + metrics.cardInset,
                outlineScale: style == .poster ? PlozzTheme.Metrics.focusedCardScale : PlozzTheme.Metrics.mediumFocusedCardScale
            )
        } else {
            VStack(spacing: metrics.posterCaptionTopSpacing + metrics.focusCaptionPush(for: focusStyle)) {
                artwork.aspectRatio(aspectRatio, contentMode: .fit)
                    .plozzFocusHalo(
                        cornerRadius: radius, focusScale: PlozzTheme.Metrics.mediumFocusedCardScale, isFocused: focused
                    )
                if showsCaption {
                    caption.offset(y: focused ? 0 : -metrics.focusCaptionPush(for: focusStyle))
                }
            }
            .padding(.horizontal, metrics.borderlessCardSideMargin)
        }
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(palette.fill)
            .overlay { label }
    }

    private var label: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.forward").font(.title)
            if !showsCaption { Text("See all").font(.headline) }
        }
        .foregroundStyle(palette.primaryText)
    }

    private var caption: some View {
        VStack(spacing: style == .poster ? 2 : 4) {
            Text("See all").font(.subheadline.weight(.semibold))
            Text(verbatim: " ").font(.system(size: 20 * metrics.scale)).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
