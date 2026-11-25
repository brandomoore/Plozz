#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

enum PlozziOSMediaLayout {
    static func metrics(
        density: UIDensity, dynamicTypeSize: DynamicTypeSize, isRunningOnMac: Bool
    ) -> PlozzMetrics {
        isRunningOnMac
            ? .desktop(density: density, dynamicTypeSize: dynamicTypeSize)
            : .touch(density: density, dynamicTypeSize: dynamicTypeSize)
    }

    static func episodeWidth(
        metrics: PlozzMetrics, sizeClass: UserInterfaceSizeClass?,
        viewport: CGFloat = 0, cardStyle: CardStyle = .borderless
    ) -> CGFloat {
        let preferred: CGFloat = metrics.usesDesktopSizing ? metrics.landscapeWidth : (sizeClass == .regular ? 360 : 300)
        guard viewport > 0 else { return preferred }
        return framedTileArtworkWidth(
            viewport: viewport, metrics: metrics, sizeClass: sizeClass, cardStyle: cardStyle,
            preferred: metrics.usesDesktopSizing ? DesktopMediaRailLayout.landscapeMaximum * metrics.scale
                : preferred * metrics.scale
        )
    }

    static func libraryWidth(
        in viewport: CGFloat, metrics: PlozzMetrics, sizeClass: UserInterfaceSizeClass?, cardStyle: CardStyle
    ) -> CGFloat {
        framedTileArtworkWidth(
            viewport: viewport, metrics: metrics, sizeClass: sizeClass, cardStyle: cardStyle,
            preferred: metrics.density.iOSHomeLibraryWidth(
                horizontalSizeClass: sizeClass, isRunningOnMac: metrics.usesDesktopSizing
            )
        )
    }

    private static func framedTileArtworkWidth(
        viewport: CGFloat, metrics: PlozzMetrics, sizeClass: UserInterfaceSizeClass?, cardStyle: CardStyle,
        preferred: CGFloat
    ) -> CGFloat {
        let frame = cardStyle == .framed ? metrics.cardInset : 0
        let inset = PlozziOSMediaRailLayout.pageInset(for: sizeClass, usesDesktopSizing: metrics.usesDesktopSizing)
            + (metrics.usesDesktopSizing ? 0 : frame)
        let target = max(preferred, 14 * metrics.cardTitleFontSize)
        let gap = PlozziOSMediaRailLayout.visibleGap(metrics: metrics) + 2 * frame
        // Desktop tiles retain the same maximum as other landscape cards.
        return metrics.usesDesktopSizing
            ? DesktopMediaRailLayout.width(in: viewport, maximum: target, leadingInset: inset, spacing: gap)
            : PlozziOSMediaRailLayout.tileWidth(viewport: viewport, leadingInset: inset, preferred: target, spacing: gap)
    }
}

struct PlozziOSEpisodeStill<Placeholder: View>: View {
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    let item: MediaItem
    let spoilers: SpoilerSettings
    var showsPlaceholderWhileLoading = false
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        let source = EpisodeArtworkSource(
            item: item, spoilerSettings: spoilers, policy: artworkPolicy.forArea(.episodes)
        )
        FallbackAsyncImage(
            references: source.references, variant: .landscapeCard, artworkPolicy: source.policy,
            asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity,
            content: { image in
                ArtworkFillImage(image)
                    .blur(radius: spoilers.mode == .blur && spoilers.shouldHideThumbnail(for: item) ? 28 : 0)
            },
            placeholder: placeholder
        )
        .showingPlaceholderWhileLoading(showsPlaceholderWhileLoading)
    }
}

struct PlozziOSPosterCard: View {
    let item: MediaItem?
    var style: PosterCardView.Style = .poster
    var artworkPolicy: CardArtworkPolicy = .standard
    /// Identify the card by its show — artwork plus logo — instead of by the
    /// item's own thumbnail. Continue Watching opts in.
    var showsSeriesArtwork: Bool = false
    /// Spoiler protection for the card's artwork and text. Defaulted so the many
    /// callers that show already-watched or non-episode content stay unchanged;
    /// surfaces that can show unwatched episodes pass the profile's real settings.
    var spoilerSettings: SpoilerSettings = .default
    /// Keeps grid rows aligned when neighboring cards have no metadata subtitle.
    var reservesSubtitleSpace: Bool = false
    /// Draws the resume chip (play glyph + progress + time remaining) over the
    /// artwork, with an optional download badge — the same treatment tvOS uses.
    var showsResumeChip: Bool = false
    var downloadState: MediaDownloadBadgeState?
    /// Visible "…" menu. Touch cards need it: press-and-hold is undiscoverable.
    var showsActionsMenu: Bool = false
    /// Caller-owned context cue drawn on the artwork (e.g. "Continues" on a
    /// Related entry that continues the story you're looking at).
    var statusCue: LocalizedStringResource?
    var isPendingRemoval: Bool = false
    var captionHorizontalInset: CGFloat?

    var body: some View {
        PosterCardView(
            item: item ?? placeholderItem,
            style: style,
            artworkPolicy: artworkPolicy,
            spoilerSettings: spoilerSettings,
            showsSeriesArtwork: showsSeriesArtwork,
            reservesSubtitleSpace: reservesSubtitleSpace,
            statusCue: statusCue.map { Text($0) },
            showsResumeChip: showsResumeChip,
            downloadState: downloadState,
            showsActionsMenu: showsActionsMenu,
            isPendingRemoval: isPendingRemoval,
            captionHorizontalInset: captionHorizontalInset,
            action: {}
        )
        .redacted(reason: item == nil ? .placeholder : [])
        .allowsHitTesting(item != nil)
    }

    private var placeholderItem: MediaItem {
        MediaItem(
            id: "placeholder",
            title: "Loading…",
            kind: .folder
        )
    }
}

extension UIDensity {
    var iOSPosterMinimumWidth: CGFloat {
        max(86, CGFloat(116 * scale))
    }

    func iOSPosterGridColumns(
        horizontalSizeClass: UserInterfaceSizeClass?,
        isRunningOnMac: Bool = false
    ) -> [GridItem] {
        if isRunningOnMac {
            let metrics = PlozzMetrics.desktop(density: self)
            return [GridItem(
                .adaptive(minimum: metrics.posterWidth, maximum: metrics.posterWidth * 1.18),
                spacing: metrics.gridSpacing
            )]
        }
        let minimumWidth = if horizontalSizeClass == .regular {
            max(108, CGFloat(144 * scale))
        } else {
            iOSPosterMinimumWidth
        }
        let spacing: CGFloat = horizontalSizeClass == .regular ? 16 : 12
        return [
            GridItem(
                .adaptive(
                    minimum: minimumWidth,
                    maximum: minimumWidth * 1.55
                ),
                spacing: spacing
            )
        ]
    }

    func iOSLandscapeGridColumns(
        horizontalSizeClass: UserInterfaceSizeClass?,
        isRunningOnMac: Bool = false
    ) -> [GridItem] {
        if isRunningOnMac {
            let metrics = PlozzMetrics.desktop(density: self)
            return [GridItem(
                .adaptive(minimum: metrics.landscapeWidth, maximum: metrics.landscapeWidth * 1.18),
                spacing: metrics.gridSpacing
            )]
        }
        return [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 240 : 160), spacing: 12)]
    }

    func iOSHomeLibraryWidth(
        horizontalSizeClass: UserInterfaceSizeClass?,
        isRunningOnMac: Bool = false
    ) -> CGFloat {
        isRunningOnMac
            ? PlozzMetrics.desktop(density: self).landscapeWidth
            : max(164, CGFloat((horizontalSizeClass == .regular ? 260 : 220) * scale))
    }
}
#endif
