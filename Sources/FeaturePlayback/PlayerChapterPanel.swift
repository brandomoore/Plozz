#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

struct PlayerChapterPanel: View {
    let model: PlayerControlsModel
    let spoilerSettings: SpoilerSettings
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let onSelect: (MediaChapter) -> Void
    @Environment(\.playerCardMetrics) private var metrics
    @State private var hasUserScrolled = false

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if metrics.isVertical {
                    FadingScrollView(
                        maxHeight: metrics.cardHeight,
                        fadeLength: metrics.contentPadding * 2,
                        verticalContentInset: 0,
                        fadesTop: hasUserScrolled
                    ) {
                        LazyVStack(spacing: 8) { chapters }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { hasUserScrolled = true }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: metrics.columnSpacing) { chapters }
                            .frame(height: metrics.cardHeight, alignment: .top)
                            .padding(.trailing, metrics.contentPadding)
                    }
                    .scrollClipDisabled()
                    .frame(height: metrics.cardHeight)
                }
            }
            .onAppear {
                if let id = MediaChapter.currentID(
                    in: model.infoCard.chapters, at: model.currentSeconds, duration: model.duration
                ) {
                    proxy.scrollTo(id, anchor: metrics.isVertical ? .top : .leading)
                }
            }
        }
        .accessibilityIdentifier("player-chapters")
    }

    private var chapters: some View {
        let entries = model.infoCard.chapters
        let showsArtwork = entries.contains { $0.imageURL != nil }
        return ForEach(Array(entries.enumerated()), id: \.element.id) { index, chapter in
            PlayerChapterButton(
                chapter: chapter, number: index + 1,
                showsArtwork: showsArtwork,
                nextStart: entries.indices.contains(index + 1) ? entries[index + 1].start : nil,
                model: model,
                spoilerSettings: spoilerSettings,
                focus: $focus
            ) {
                onSelect(chapter)
            }
            .id(chapter.id)
        }
    }
}

/// Only visible chapter buttons observe the playhead, not the player/tab root.
private struct PlayerChapterButton: View {
    let chapter: MediaChapter
    let number: Int
    let showsArtwork: Bool
    let nextStart: TimeInterval?
    let model: PlayerControlsModel
    let spoilerSettings: SpoilerSettings
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let action: () -> Void
    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.playerControlForeground) private var foreground

    private var isCurrent: Bool {
        let time = model.currentSeconds
        return time.isFinite && time >= chapter.start
            && (nextStart.map { time < $0 } ?? true)
            && (!model.duration.isFinite || model.duration <= 0 || time < model.duration)
    }

    private var hidesText: Bool {
        model.infoCard.artworkItem.map(spoilerSettings.shouldHideText(for:)) ?? false
    }

    private var hidesImage: Bool {
        model.infoCard.artworkItem.map(spoilerSettings.shouldHideThumbnail(for:)) ?? false
    }

    private var title: Text {
        if let title = chapter.title, !hidesText {
            Text(verbatim: title)
        } else {
            Text("Chapter \(number)", comment: "Fallback chapter title; the number is its position in the video's chapter list.")
        }
    }

    private var cardWidth: CGFloat {
        if !showsArtwork {
            return max(metrics.castCardWidth, contentInset * 2 + metrics.castNameSize * 6)
        }
        let imageHeight = max(44, metrics.cardHeight - metrics.castVerticalInset * 2
            - metrics.castNameSize * 1.5 - metrics.captionSize * 1.5 - 16)
        return imageHeight * 16 / 9 + 24
    }

    private var contentInset: CGFloat {
        max(metrics.contentPadding, metrics.panelCornerRadius * 2 / 3)
    }

    private var cornerRadius: CGFloat {
        metrics.isVertical ? metrics.panelCornerRadius - 6 : metrics.panelCornerRadius
    }

    var body: some View {
        chapterButton
            .focused($focus, equals: .chapter(chapter.id))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(Text(verbatim: PlayerControls.timeLabel(chapter.start)))
            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            .accessibilityIdentifier("player-chapter-\(number)")
    }

    private var chapterButton: some View {
        Button(action: action) { content }
            .buttonStyle(PlayerOverVideoCardStyle(
                focused: focus == .chapter(chapter.id),
                cornerRadius: cornerRadius,
                focusScale: metrics.isVertical ? 1 : 1.10,
                pressScale: metrics.isVertical ? 0.98 : 1,
                mediaGlass: true
            ))
    }

    @ViewBuilder
    private var content: some View {
        if metrics.isVertical {
            HStack(spacing: 12) {
                if showsArtwork {
                    thumbnail
                        .frame(width: metrics.castHeadshot * 16 / 9, height: metrics.castHeadshot)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                caption
                Spacer(minLength: 0)
            }
            .padding(.horizontal, showsArtwork ? 10 : metrics.contentPadding)
            .frame(height: metrics.castRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if showsArtwork {
            #if os(tvOS)
            let layout = PlayerMediaArtworkLayout(
                height: metrics.cardHeight, inset: contentInset, cornerRadius: cornerRadius
            )
            layout {
                thumbnail
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipShape(layout.thumbnailShape)
                caption
            }
            #else
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                    .frame(width: cardWidth - contentInset * 2,
                           height: (cardWidth - contentInset * 2) * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                caption
            }
            .padding(contentInset)
            .frame(width: cardWidth, height: metrics.cardHeight, alignment: .bottom)
            #endif
        } else {
            caption
                .fixedSize(horizontal: false, vertical: true)
                .padding(contentInset)
                .frame(width: cardWidth, height: metrics.cardHeight, alignment: .leading)
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(metrics.castNameFont)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(verbatim: PlayerControls.timeLabel(chapter.start))
                    .monospacedDigit()
                Image(systemName: "play.fill")
                    .opacity(isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .font(metrics.captionFont)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(foreground)
    }

    private var thumbnail: some View {
        FallbackAsyncImage(
            urls: hidesImage && spoilerSettings.mode == .placeholder ? [] : chapter.imageURL.map { [$0] } ?? [],
            variant: .landscapeCard,
            artworkPolicy: model.artworkPolicy
        ) {
            Image(systemName: "list.number")
                .font(metrics.titleFont)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .showingPlaceholderWhileLoading(true)
        .blur(radius: hidesImage && spoilerSettings.mode == .blur ? 28 : 0)
        .accessibilityHidden(true)
    }
}

/// Fits the artwork to the measured caption, rather than leaving an estimated top gutter.
struct PlayerMediaArtworkLayout: Layout {
    let height: CGFloat
    let inset: CGFloat
    let cornerRadius: CGFloat
    var aspectRatio: CGFloat = 16 / 9
    private let spacing: CGFloat = 8

    var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let captionHeight = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified).height : 0
        let artworkHeight = max(0, height - inset * 2 - (subviews.count > 1 ? spacing : 0) - captionHeight)
        return CGSize(width: artworkHeight * aspectRatio + inset * 2, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let width = bounds.width - inset * 2
        subviews[0].place(
            at: CGPoint(x: bounds.minX + inset, y: bounds.minY + inset), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: width / aspectRatio)
        )
        if subviews.count > 1 {
            subviews[1].place(
                at: CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset), anchor: .bottomLeading,
                proposal: ProposedViewSize(width: width, height: nil)
            )
        }
    }
}
#endif
