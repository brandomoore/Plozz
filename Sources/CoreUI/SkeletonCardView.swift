#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// A non-interactive placeholder that mirrors `PosterCardView`'s outer geometry
/// exactly (same glass surface, paddings, artwork aspect/corner radii and the
/// two text lines beneath) but renders soft neutral fills instead of a real
/// `MediaItem`.
///
/// Like `PosterCardView`, it renders in whichever per-profile `CardStyle` is
/// active (read from `\.plozzCardStyle`): the framed glass card ("Cards") or the
/// borderless artwork-only look ("Posters"). Matching the active style is what
/// keeps the loading state from looking off — a borderless profile would
/// otherwise see framed glass skeletons swap out for borderless artwork.
///
/// Keeping this in lock-step with `PosterCardView` — via the shared
/// `PlozzTheme.Metrics` and the same layout structure — is what makes a skeleton
/// row pixel-for-pixel 1:1 with the loaded row, so nothing shifts or reflows when
/// real content swaps in. Home's explicit waiting destination can supply a focus
/// binding to use the same controls as loaded cards; ordinary skeletons stay inert.
public struct SkeletonCardView: View {
    public enum Style { case poster, landscape }

    private let style: Style
    /// Mirrors `PosterCardView`'s series-artwork mode, which draws no caption at
    /// all. The skeleton is deliberately pixel-1:1 with the loaded card, so it has
    /// to drop the caption too — otherwise Continue Watching visibly shrinks the
    /// moment real cards replace the placeholders.
    private let captionOverride: Bool?
    @Environment(\.plozzCardCaptionsHidden) private var captionsHidden
    private var showsCaption: Bool { (captionOverride ?? !captionsHidden) && !showsSeriesArtwork }
    /// Mirrors `PosterCardView`'s series-artwork shape: taller than 16:9 (it
    /// reserves a band for its chrome) and narrower to compensate. Kept explicit
    /// rather than inferred from `showsCaption` so the placeholder and the real
    /// card can't quietly disagree about the shape of the row.
    private let showsSeriesArtwork: Bool
    private let isFocused: Bool
    private let showsProgress: Bool
    private let focus: PlozzCardFocus.Binding?

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    /// Per-profile card presentation (framed glass card vs borderless artwork),
    /// mirrored from `PosterCardView` so the placeholder matches whichever look the
    /// real cards will render in.
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    public init(
        style: Style = .poster,
        showsCaption: Bool? = nil,
        showsSeriesArtwork: Bool = false,
        isFocused: Bool = false,
        showsProgress: Bool = false,
        focus: PlozzCardFocus.Binding? = nil
    ) {
        self.style = style
        self.captionOverride = showsCaption
        self.showsSeriesArtwork = showsSeriesArtwork
        self.isFocused = isFocused
        self.showsProgress = showsProgress
        self.focus = focus
    }

    /// The artwork slot this placeholder reserves — identical to
    /// `PosterCardView.size` for the same inputs.
    private var artworkSize: CGSize {
        guard showsSeriesArtwork else {
            return CGSize(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
        }
        let width = metrics.continueWatchingWidth
        return CGSize(
            width: width,
            height: (width / ContinueWatchingCardShape.aspectRatio).rounded()
        )
    }

    @ViewBuilder
    public var body: some View {
        if let focus {
            cardBody
                .focusableCard(
                    isFocused: focus, cornerRadius: borderlessCornerRadius,
                    nativeFocusInContent: cardStyle == .borderless, action: {}
                )
                .plozzCardFocusTransition(isFocused: isFocused)
        } else {
            cardBody
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        #if os(tvOS)
        if focusStyle.usesSystemEffect && cardStyle == .borderless {
            nativeCard
        } else {
            styledBody
        }
        #else
        styledBody
        #endif
    }

    private var surfaceFocused: Bool { isFocused && focusStyle.drawsFocusOutline }

    @ViewBuilder
    private var styledBody: some View {
        switch cardStyle {
        case .framed:
            switch style {
            case .poster: posterCard
            case .landscape: landscapeCard
            }
        case .borderless:
            borderlessCard
        }
    }

    // Mirrors `PosterCardView.posterCard`.
    private var posterCard: some View {
        VStack(alignment: .leading, spacing: metrics.posterCaptionTopSpacing) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.posterArtworkCornerRadius, style: .continuous)
                        .fill(palette.fill)
                }
                .clipShape(RoundedRectangle(cornerRadius: metrics.posterArtworkCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: metrics.posterArtworkCornerRadius)
                .overlay {
                    SkeletonLoadingIndicator(isVisible: showsProgress)
                }

            // Match PosterCardView's caption: VStack(spacing: 2), subheadline +
            // size-20 fonts. Reusing the same fonts (via hidden sizing text) keeps
            // the caption block the exact same height, so the row never shifts
            // vertically when real content swaps in.
            if showsCaption {
                textLines(contentWidth: metrics.posterWidth - 2 * metrics.posterCaptionInset, spacing: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], metrics.posterCaptionInset)
            }
        }
        .shimmering()
        .plozzFramedMediaCard(
            innerCornerRadius: metrics.posterArtworkCornerRadius,
            isFocused: surfaceFocused
        )
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .plozzRestingCardShadow(isFocused: isFocused)
        .plozzCardFocusLift(
            isFocused: isFocused, cornerRadius: metrics.posterCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.focusedCardScale
        )
    }

    // Mirrors `PosterCardView.landscapeCard`.
    private var landscapeCard: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            RoundedRectangle(cornerRadius: metrics.landscapeArtworkCornerRadius, style: .continuous)
                .fill(palette.fill)
                .frame(width: artworkSize.width, height: artworkSize.height)
                .clipShape(RoundedRectangle(cornerRadius: metrics.landscapeArtworkCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: metrics.landscapeArtworkCornerRadius)
                .overlay {
                    SkeletonLoadingIndicator(isVisible: showsProgress)
                }

            // PosterCardView's landscape caption uses VStack(spacing: 4).
            if showsCaption {
                textLines(contentWidth: artworkSize.width - 2 * metrics.landscapeCaptionInset, spacing: 4)
                    .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
                    .frame(width: artworkSize.width, alignment: .leading)
            }
        }
        .shimmering()
        .plozzFramedMediaCard(
            innerCornerRadius: metrics.landscapeArtworkCornerRadius,
            isFocused: surfaceFocused
        )
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .plozzRestingCardShadow(isFocused: isFocused)
        .plozzCardFocusLift(
            isFocused: isFocused, cornerRadius: metrics.landscapeCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.mediumFocusedCardScale
        )
    }

    #if os(tvOS)
    // MARK: Native (system focus, "Posters" style)

    /// Mirrors `PosterCardView.nativePosterCard`. The placeholder art is
    /// a native poster itself, so it keeps the same clearance for focus growth
    /// and the same corners as the real one.
    private var nativeCard: some View {
        VStack(spacing: metrics.nativePosterCaptionSpacing) {
            nativeArtwork.frame(maxWidth: .infinity)
            if showsCaption {
                nativeCaption
                    .offset(y: isFocused ? metrics.nativePosterCaptionFocusTravel : 0)
            }
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
    }

    @ViewBuilder
    private var nativeArtwork: some View {
        let artwork = NativePosterPlaceholder(
            aspectRatio: borderlessAspectRatio,
            fallbackWidth: nativeArtworkWidth,
            fill: palette.fill,
            focus: focus,
            showsProgress: showsProgress
        )
        if let focus {
            artwork.focused(focus.focusState)
        } else {
            artwork
        }
    }

    /// The artwork width a native poster is given: the card's own artwork width.
    private var nativeArtworkWidth: CGFloat {
        switch style {
        case .poster: metrics.posterWidth
        case .landscape: artworkSize.width
        }
    }

    /// `SystemPosterCaption`'s footprint at rest: a line for each font, centred
    /// pills in them, and the focus travel reserved beneath.
    private var nativeCaption: some View {
        let title = UIFont.systemFont(ofSize: metrics.cardTitleFontSize, weight: .semibold)
        let subtitle = UIFont.systemFont(ofSize: metrics.cardSubtitleFontSize)
        return VStack(spacing: 2) {
            nativeCaptionLine(height: ceil(title.lineHeight), fraction: 0.7, pill: (16 * metrics.scale).rounded())
            nativeCaptionLine(height: ceil(subtitle.lineHeight), fraction: 0.45, pill: (13 * metrics.scale).rounded())
        }
        .padding(.bottom, metrics.nativePosterCaptionFocusTravel)
        .shimmering()
    }

    private func nativeCaptionLine(height: CGFloat, fraction: CGFloat, pill: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(palette.fill)
            .frame(width: (nativeArtworkWidth * fraction).rounded(), height: pill)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
    #endif

    // MARK: Borderless ("Posters" style)

    /// Mirrors `PosterCardView.borderlessCard`: no
    /// glass surface, just the full-bleed artwork placeholder rounded at the outer
    /// radius, with the caption held off the artwork edge and riding up to the
    /// resting gap. Reserving the *focused* caption spacing (`borderlessCaptionSpacing`)
    /// and pushing the caption up by `focusCaptionPush` reproduces the real card's
    /// footprint exactly, so nothing shifts when real content swaps in.
    private var borderlessCard: some View {
        VStack(alignment: .leading, spacing: borderlessCaptionSpacing) {
            borderlessArtwork

            // Match BorderlessCardCaption: VStack(spacing: 2), same fonts, held off
            // the rounded artwork edge by the shared caption inset.
            if showsCaption {
                textLines(contentWidth: borderlessCaptionContentWidth, spacing: 2)
                    .padding(.horizontal, borderlessCaptionInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Match the real caption's drawing offset without changing its slot.
                    .offset(y: focusStyle.usesSystemEffect || isFocused ? 0 : -captionPush)
                    .shimmering()
            }
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .compositingGroup()
    }

    /// The full-bleed artwork placeholder for a borderless card, clipped to the
    /// outer radius, with the same shared focus treatment as loaded artwork.
    private var borderlessArtwork: some View {
        Color.clear
            .aspectRatio(borderlessAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: borderlessCornerRadius, style: .continuous)
                    .fill(palette.fill)
                    .shimmering()
            }
            .clipShape(RoundedRectangle(cornerRadius: borderlessCornerRadius, style: .continuous))
            .plozzMediaEdge(cornerRadius: borderlessCornerRadius)
            .overlay {
                SkeletonLoadingIndicator(isVisible: showsProgress)
            }
            .plozzFocusHalo(
                cornerRadius: borderlessCornerRadius,
                focusScale: PlozzTheme.Metrics.mediumFocusedCardScale,
                isFocused: isFocused
            )
    }

    /// Aspect ratio for the borderless full-bleed image (matches `PosterCardView`).
    private var borderlessAspectRatio: CGFloat {
        switch style {
        case .poster: return 2.0 / 3.0
        case .landscape: return showsSeriesArtwork
            ? ContinueWatchingCardShape.aspectRatio
            : 16.0 / 9.0
        }
    }

    /// Matches the loaded card's platform-specific artwork rounding.
    private var borderlessCornerRadius: CGFloat {
        switch style {
        case .poster: return metrics.borderlessPosterCornerRadius
        case .landscape: return metrics.borderlessLandscapeCornerRadius
        }
    }

    /// Horizontal caption clearance for a borderless card, matching
    /// `PosterCardView.borderlessCaptionInset`.
    private var borderlessCaptionInset: CGFloat {
        switch style {
        case .poster: return metrics.posterCaptionInset
        case .landscape: return metrics.landscapeCaptionInset
        }
    }

    /// Artwork↔caption gap reserved for a borderless card — always the *focused*
    /// size (base + focus push), matching `PosterCardView.borderlessCaptionSpacing`
    /// so the footprint never changes with focus.
    private var borderlessCaptionSpacing: CGFloat {
        let base: CGFloat
        switch style {
        case .poster: base = metrics.posterCaptionTopSpacing
        case .landscape: base = metrics.landscapeCaptionTopSpacing
        }
        return base + captionPush
    }

    /// The real card's focus push for the active focus style — a skeleton has to
    /// reserve exactly what the card it stands in for reserves, or the row shifts
    /// the moment real content swaps in.
    private var captionPush: CGFloat {
        metrics.focusCaptionPush(for: focusStyle)
    }

    /// Approximate width available to the borderless caption pills — the card slot
    /// minus its side margins and the caption inset. Only drives the cosmetic pill
    /// lengths, not layout height.
    private var borderlessCaptionContentWidth: CGFloat {
        let slot: CGFloat
        switch style {
        case .poster: slot = metrics.posterWidth
        case .landscape: slot = metrics.cardSlotWidth(
            for: .landscape,
            cardStyle: .borderless,
            showsSeriesArtwork: showsSeriesArtwork
        )
        }
        return slot - 2 * metrics.borderlessCardSideMargin - 2 * borderlessCaptionInset
    }

    /// Two fully-rounded placeholder pills standing in for the card's title and
    /// subtitle. Each pill is laid inside a hidden sizing `Text` using the *same*
    /// font the real card uses, so the line reserves the identical height — the
    /// capsule is just a shorter shape leading-aligned within it. This keeps the
    /// caption block height pixel-identical to `PosterCardView` (no vertical shift
    /// on load) while giving the placeholders soft, fully-rounded edges.
    private func textLines(contentWidth: CGFloat, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            capsuleLine(font: .system(size: metrics.cardTitleFontSize, weight: .semibold), width: max(contentWidth * 0.7, 1), height: (16 * metrics.scale).rounded())
            capsuleLine(font: .system(size: metrics.cardSubtitleFontSize), width: max(contentWidth * 0.45, 1), height: (13 * metrics.scale).rounded())
        }
    }

    private func capsuleLine(font: Font, width: CGFloat, height: CGFloat) -> some View {
        // The hidden text drives the line's height to match the real caption's
        // font metrics exactly; the capsule (shorter) is overlaid, leading-aligned.
        Text(verbatim: " ")
            .font(font)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(palette.fill)
                    .frame(width: width, height: height)
            }
    }
}

struct SkeletonLoadingIndicator: View {
    let isVisible: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if isVisible {
                ProgressView().tint(palette.primaryText)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
