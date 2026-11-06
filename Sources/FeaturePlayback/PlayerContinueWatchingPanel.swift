#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

struct PlayerContinueWatchingPanel: View {
    let items: [MediaItem]
    let spoilerSettings: SpoilerSettings
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let onSelect: (MediaItem) -> Void
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.plozzContinueWatchingPresentation) private var presentation
    @State private var hasUserScrolled = false

    var body: some View {
        Group {
            if metrics.isVertical {
                FadingScrollView(
                    maxHeight: metrics.cardHeight, fadeLength: metrics.contentPadding * 2,
                    verticalContentInset: 0, fadesTop: hasUserScrolled
                ) {
                    LazyVStack(spacing: 8) { cards }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { hasUserScrolled = true }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: metrics.columnSpacing) { cards }
                        .frame(height: metrics.cardHeight, alignment: .top)
                        .padding(.trailing, metrics.contentPadding)
                }
                .scrollClipDisabled()
                .frame(height: metrics.cardHeight, alignment: .top)
            }
        }
        .environment(\.plozzArtworkArea, .continueWatching)
        .environment(\.plozzCardCaptionView, .home)
        .environment(\.plozzCardCaptionIsShowcase, presentation.isShowcase)
        .accessibilityIdentifier("player-continue-watching")
    }

    private var cards: some View {
        ForEach(items, id: \.stablePresentationID) { item in
            PlayerContinueWatchingCard(item: item, spoilerSettings: spoilerSettings, focus: $focus) {
                onSelect(item)
            }
        }
    }
}

struct PlayerContinueWatchingCard: View {
    let item: MediaItem
    let spoilerSettings: SpoilerSettings
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let action: () -> Void
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.plozzContinueWatchingPresentation) private var presentation
    @Environment(\.plozzContinueWatchingPlaybackDetails) private var playbackDetails
    @Environment(\.plozzCardCaptionSettings) private var captions
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.playerControlForeground) private var foreground

    private var showsCaptions: Bool { presentation.showsCaptions(captions) }
    private var slot: PlayerControls.FocusSlot { .continueWatching(item.stablePresentationID) }
    private var isFocused: Bool { focus == slot }
    private var title: Text { item.posterCaptionText(spoilerSettings: spoilerSettings) }
    private var aspectRatio: CGFloat {
        switch presentation.artworkStyle {
        case .portraitPosters: 2 / 3
        case .thumbnail: 16 / 9
        case .logoAndArtwork: ContinueWatchingCardShape.aspectRatio
        }
    }
    private var inset: CGFloat {
        cardStyle == .framed ? metrics.contentPadding : 0
    }
    private var cornerRadius: CGFloat {
        if cardStyle == .borderless { return PlozzTheme.Metrics.mediumMediaCornerRadius }
        return metrics.isVertical ? metrics.panelCornerRadius - 6 : metrics.panelCornerRadius
    }

    var body: some View {
        Button(action: action) {
            if metrics.isVertical {
                compactContent
            } else {
                let layout = PlayerMediaArtworkLayout(
                    height: metrics.cardHeight, inset: inset, cornerRadius: cornerRadius,
                    aspectRatio: aspectRatio
                )
                layout {
                    artwork(cornerRadius: layout.thumbnailShape.cornerSize.width)
                    if showsCaptions { caption }
                }
            }
        }
        .buttonStyle(PlayerOverVideoCardStyle(
            focused: isFocused, cornerRadius: cornerRadius,
            focusScale: metrics.isVertical ? 1 : 1.10,
            pressScale: metrics.isVertical ? 0.98 : 1,
            mediaGlass: true, showsSurface: cardStyle == .framed
        ))
        .focused($focus, equals: slot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: item.posterCaptionSubtitle(showsRuntime: true) ?? ""))
        .accessibilityIdentifier("player-continue-watching-\(item.stablePresentationID)")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(metrics.castNameFont)
                .lineLimit(1)
            Text(verbatim: item.posterCaptionSubtitle(showsRuntime: playbackDetails == .progressOnly) ?? " ")
                .font(metrics.castRoleFont)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, cardStyle == .borderless ? metrics.contentPadding / 2 : 0)
        .padding(.bottom, cardStyle == .borderless ? metrics.contentPadding / 2 : 0)
    }

    private var compactContent: some View {
        HStack(spacing: 12) {
            artwork(cornerRadius: 8, showsIndicators: false)
                .frame(width: (metrics.castRowHeight - 12) * aspectRatio, height: metrics.castRowHeight - 12)
            VStack(alignment: .leading, spacing: 4) {
                if showsCaptions {
                    title.font(metrics.castNameFont).lineLimit(1)
                }
                if playbackDetails == .detailed {
                    EpisodeWatchStatePill(
                        item: item, showsWatched: false, showsBackground: false,
                        detailText: item.seasonEpisodeLabel, showsPlayGlyphWhenIdle: true
                    )
                    .font(metrics.castRoleFont)
                } else {
                    if showsCaptions, let subtitle = item.posterCaptionSubtitle(showsRuntime: true) {
                        Text(verbatim: subtitle).font(metrics.castRoleFont).lineLimit(1)
                    }
                    MediaCardPlaybackIndicators(
                        item: item, hidesStatus: true, badgeInset: 0,
                        progressHeight: 4
                    )
                    .frame(height: 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: metrics.castRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(cornerRadius: CGFloat, showsIndicators: Bool = true) -> some View {
        PosterCardView(
            item: item, style: presentation.artworkStyle.layout.cardStyle,
            spoilerSettings: spoilerSettings, showsSeriesArtwork: presentation.artworkStyle.showsSeriesArtwork,
            playsOnSelect: true
        ) {}
        .artworkOnly(
            cornerRadius: cornerRadius, playbackTextSize: metrics.captionSize,
            playbackInset: metrics.isVertical ? 6 : metrics.contentPadding / 2,
            showsPlaybackIndicators: showsIndicators
        )
        .plozzChromeFocused(isFocused)
        .accessibilityHidden(true)
    }
}
#endif
