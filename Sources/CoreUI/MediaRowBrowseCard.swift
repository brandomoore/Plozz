#if os(tvOS)
import CoreModels
import SwiftUI

/// A rail action, not a media item: no playback, watch-state, or context menu.
public struct MediaRowBrowseCard: View {
    private let width: CGFloat
    private let style: PosterCardView.Style
    private let showsSeriesArtwork: Bool
    private let featuredSize: CGSize?
    private let posters: [MediaItem]
    private let onFocus: () -> Void
    private let onFocusChange: ((Bool) -> Void)?
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
        featuredSize: CGSize? = nil, posters: [MediaItem] = [], onFocus: @escaping () -> Void = {},
        onFocusChange: ((Bool) -> Void)? = nil, action: @escaping () -> Void
    ) {
        self.width = width
        self.style = style
        self.showsSeriesArtwork = showsSeriesArtwork
        self.featuredSize = featuredSize
        self.posters = posters
        self.onFocus = onFocus
        self.onFocusChange = onFocusChange
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
            .onChange(of: focused) { _, value in
                if value { onFocus() }
                onFocusChange?(value)
            }
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

    /// With posters: a dark card holding a 3×3 grid of the row's own posters and a bold
    /// chevron. Without them (Featured rows): a soft surface with an arrow badge.
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(LinearGradient(
                colors: posters.isEmpty
                    ? [palette.cardSurface, palette.fill]
                    : [Color(white: 0.17), Color(white: 0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .overlay {
                shape.fill(RadialGradient(
                    colors: [Color.white.opacity(focused ? 0.12 : 0.05), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 360
                ))
            }
            .overlay { shape.strokeBorder(palette.cardBorder, lineWidth: 1.5) }
            .overlay { label }
    }

    @ViewBuilder
    private var label: some View {
        if posters.isEmpty {
            badgeLabel
        } else {
            posterGridLabel
        }
    }

    /// Nine of the row's posters in a grid, with a chevron beside them.
    private var posterGridLabel: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let gap = width * 0.03
            // Squarer than a poster, so the grid fills a narrow card; the picture is cropped.
            let tileAspect: CGFloat = 0.8
            let fitByWidth = (width * 0.70 - 2 * gap) / 3
            let fitByHeight = ((height * 0.82 - 2 * gap) / 3) * tileAspect
            let tileWidth = min(fitByWidth, fitByHeight)
            let tileHeight = tileWidth / tileAspect
            HStack(spacing: width * 0.04) {
                VStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<3, id: \.self) { column in
                                posterTile(index: row * 3 + column)
                                    .frame(width: tileWidth, height: tileHeight)
                            }
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: tileWidth * 1.1, weight: .heavy))
                    .foregroundStyle(.white.opacity(focused ? 1 : 0.88))
                    .frame(width: tileWidth * 0.62)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    @ViewBuilder
    private func posterTile(index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if posters.indices.contains(index) {
            let item = posters[index]
            FallbackAsyncImage(
                references: item.artworkReferences(for: item.kind == .episode ? .seriesPoster : .poster),
                variant: .posterPreview,
                content: { image in image.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { Color.white.opacity(0.14) }
            )
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
        } else {
            shape.fill(.white.opacity(0.1))
        }
    }

    private var badgeLabel: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(focused ? palette.accent : palette.primaryText.opacity(0.16))
                Circle()
                    .strokeBorder(palette.primaryText.opacity(focused ? 0 : 0.28), lineWidth: 1.5)
                Image(systemName: "arrow.right")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(focused ? palette.onAccent : palette.primaryText)
            }
            .frame(width: 92, height: 92)
            if !showsCaption {
                Text("See all").font(.headline.weight(.semibold))
            }
        }
        .foregroundStyle(palette.primaryText)
        .animation(.easeOut(duration: 0.2), value: focused)
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
