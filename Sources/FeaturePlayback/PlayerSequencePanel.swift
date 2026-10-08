#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlayerSequenceLayout {
    let metrics: PlayerCardMetrics
    let cardMetrics: PlozzMetrics
    let contained: Bool
    let hasError: Bool

    var compact: Bool { metrics.contentHeight < 160 }
    var gap: CGFloat { compact ? 6 : 10 }
    var columnSpacing: CGFloat { metrics.columnSpacing }
    var containerVerticalInset: CGFloat { contained ? metrics.contentPadding / 2 : 0 }
    var rowHeight: CGFloat {
        metrics.cardHeight - containerVerticalInset * 2
            - (hasError ? 36 + gap : 0)
    }
    var titleHeight: CGFloat {
        if contained {
            #if canImport(UIKit)
            return ceil(UIFont.systemFont(ofSize: metrics.castNameSize, weight: .semibold).lineHeight)
            #else
            return (metrics.castNameSize * 1.4).rounded(.up)
            #endif
        }
        return (metrics.castNameSize * (compact ? 1.4 : 2.45)).rounded(.up)
    }
    var bottomInset: CGFloat { cardMetrics.cardInset + (contained ? 0 : cardMetrics.landscapeCaptionInset) }
    var captionFocusTravel: CGFloat { cardMetrics.focusCaptionPush(for: .system) / 2 }
    var imageHeight: CGFloat {
        rowHeight - cardMetrics.cardInset - bottomInset
            - cardMetrics.landscapeCaptionTopSpacing - titleHeight
    }
    var imageWidth: CGFloat { (imageHeight * 16 / 9).rounded() }
    var cardWidth: CGFloat {
        imageWidth + cardMetrics.cardInset * 2
    }
    var previousArtworkPeek: CGFloat { 24 }
    var episodePeekInset: CGFloat {
        previousArtworkPeek + columnSpacing + cardMetrics.cardInset
    }
    func episodeOffset(for index: Int) -> CGFloat {
        max(0, CGFloat(index) * (cardWidth + columnSpacing) - episodePeekInset)
    }
}

/// Episode cards live inside one player panel; playlist cards stand alone.
/// Only visible entries are built; playlist pages are still requested on demand.
struct PlayerSequencePanel: View {
    enum Source: Equatable { case episodes, playlist }

    @Environment(\.playerCardMetrics) private var metrics
    @Environment(\.plozzMetrics) private var cardMetrics
    let player: PlayerViewModel
    let source: Source
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    @State private var episodePosition = ScrollPosition(idType: PlayerEpisodeEntry.ID.self)
    @State private var episodeOffset = CGPoint.zero
    @State private var previousEpisodeLoadID: PlayerEpisodeEntry.ID?
    @State private var nextEpisodeLoadID: PlayerEpisodeEntry.ID?
    @State private var displayedEpisodes: EpisodeRowContent?
    @State private var episodeRowIsScrolling = false
    @State private var nativeEpisodeFocusID: PlayerEpisodeEntry.ID?

    private struct EpisodeRowContent: Equatable {
        let entries: [PlayerEpisodeEntry]
        let previousError: AppError?
        let nextError: AppError?

        @MainActor init(_ browser: PlayerEpisodeBrowser) {
            entries = browser.episodes
            previousError = browser.previousLoadError
            nextError = browser.nextLoadError
        }
    }

    private var layout: PlayerSequenceLayout {
        PlayerSequenceLayout(
            metrics: metrics,
            cardMetrics: cardMetrics,
            contained: source == .episodes,
            hasError: source == .playlist && player.playlistContext?.loadError != nil
        )
    }

    var body: some View {
        Group {
            if source == .episodes {
                content
                    .modifier(PlayerEpisodePanelSurface(layout: layout))
            } else {
                content.frame(height: metrics.cardHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            if source == .episodes { await player.episodeBrowser?.loadIfNeeded() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: layout.gap) {
            if source == .episodes, let browser = player.episodeBrowser {
                episodeContent(browser)
            } else if source == .playlist, let playlist = player.playlistContext {
                if playlist.totalCount == 0 {
                    emptyRow("This playlist is empty.")
                } else {
                    playlistRow(playlist)
                }
                if let error = playlist.loadError {
                    errorRow(error) { playlist.retry() }
                }
            }
        }
    }

    @ViewBuilder
    private func episodeContent(_ browser: PlayerEpisodeBrowser) -> some View {
        if let error = browser.loadError {
            errorRow(error) { Task { await browser.loadIfNeeded() } }
        } else if browser.isLoading || !browser.hasLoaded {
            PlayerEpisodeLoadingRow(layout: layout, showsPrevious: browser.initialHasPreviousEpisode)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading episodes…")
        } else if browser.episodes.isEmpty {
            emptyRow("No episodes available")
        } else {
            #if os(tvOS)
            nativeEpisodeRow(browser)
            #else
            episodeRow(browser)
            #endif
        }
    }

    #if os(tvOS)
    private func nativeEpisodeRow(_ browser: PlayerEpisodeBrowser) -> some View {
        var elements = browser.episodes.map(NativeEpisodeElement.episode)
        if let error = browser.previousLoadError { elements.insert(.previousError(error), at: 0) }
        if let error = browser.nextLoadError { elements.append(.nextError(error)) }
        return PlayerEpisodeNativeRow(
            items: elements, initialID: browser.initialEntryID,
            layout: layout, spoilerSettings: player.spoilerSettings, focus: $focus
        ) { visible in
            if let id = browser.episodes.first?.id, visible.contains(.episode(id)) {
                previousEpisodeLoadID = id
            }
            if let id = browser.episodes.last?.id, visible.contains(.episode(id)) {
                nextEpisodeLoadID = id
            }
        } onFocus: { id in
            nativeEpisodeFocusID = id
        } onSelect: { element in
            switch element {
            case .episode(let entry):
                player.playEpisode(entry.item)
            case .previousError:
                Task { await browser.retryPrevious() }
            case .nextError:
                Task { await browser.retryNext() }
            }
        }
        .frame(height: layout.rowHeight)
        .focused($focus, equals: nativeEpisodeFocusTarget(browser))
        .task(id: previousEpisodeLoadID) {
            guard previousEpisodeLoadID != nil else { return }
            await browser.loadPrevious()
        }
        .task(id: nextEpisodeLoadID) {
            guard nextEpisodeLoadID != nil else { return }
            await browser.loadNext()
        }
    }

    private func nativeEpisodeFocusTarget(_ browser: PlayerEpisodeBrowser) -> PlayerControls.FocusSlot? {
        return (nativeEpisodeFocusID ?? browser.initialEntryID ?? browser.episodes.first?.id)
            .map(PlayerControls.FocusSlot.episodeItem)
    }
    #endif

    private func emptyRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(metrics.titleFont)
            .padding(metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: layout.rowHeight)
            .background {
                if source == .playlist {
                    PlayerOverVideoSurface(focused: false, cornerRadius: metrics.panelCornerRadius)
                }
            }
    }

    private func errorRow(_ error: AppError, retry: @escaping () -> Void) -> some View {
        HStack {
            Text(error.userMessage)
                .font(.caption)
            Button("Try Again", action: retry)
                .font(.caption)
        }
        .padding(.horizontal, cardMetrics.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 36)
        .background {
            if source == .playlist {
                PlayerOverVideoSurface(focused: false, cornerRadius: cardMetrics.landscapeCardCornerRadius)
            }
        }
    }

    private func episodeRetry(
        _ error: AppError, title: LocalizedStringKey, retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(metrics.castNameFont)
            Text(error.userMessage)
                .font(.caption)
                .lineLimit(2)
            Button("Try Again", action: retry)
                .font(.caption)
        }
        .padding(metrics.contentPadding)
        .frame(
            width: metrics.isVertical ? nil : layout.cardWidth,
            height: metrics.isVertical ? max(120, metrics.castRowHeight) : layout.rowHeight,
            alignment: .leading
        )
        .background(.white.opacity(0.08), in: RoundedRectangle(
            cornerRadius: cardMetrics.landscapeCardCornerRadius,
            style: .continuous
        ))
    }

    private func episodeRow(_ browser: PlayerEpisodeBrowser) -> some View {
        let latest = EpisodeRowContent(browser)
        let displayed = displayedEpisodes ?? latest
        return sequenceScroll {
            if let error = displayed.previousError {
                episodeRetry(error, title: "Earlier episodes") {
                    Task { await browser.retryPrevious() }
                }
            }
            ForEach(displayed.entries) { entry in
                card(
                    entry.item, focusSlot: .episodeItem(entry.id),
                    selected: false, episodeBadge: entry.badge
                ) { player.playEpisode(entry.item) }
                .id(entry.id)
            }
            if let error = displayed.nextError {
                episodeRetry(error, title: "Later episodes") {
                    Task { await browser.retryNext() }
                }
            }
        }
        .scrollPosition($episodePosition)
        .onScrollGeometryChange(for: CGPoint.self) {
            CGPoint(x: $0.contentOffset.x + $0.contentInsets.leading,
                    y: $0.contentOffset.y + $0.contentInsets.top)
        } action: { _, offset in
            episodeOffset = offset
        }
        .onScrollPhaseChange { _, phase, context in
            episodeRowIsScrolling = phase != .idle
            if phase == .idle {
                episodeOffset = CGPoint(
                    x: context.geometry.contentOffset.x + context.geometry.contentInsets.leading,
                    y: context.geometry.contentOffset.y + context.geometry.contentInsets.top
                )
                updateDisplayedEpisodes(latest)
            }
        }
        .onChange(of: latest) { _, value in
            // Native focus scrolling has an absolute destination. Inserting
            // before it mid-animation invalidates that destination and focus.
            if !episodeRowIsScrolling { updateDisplayedEpisodes(value) }
        }
        .onScrollTargetVisibilityChange(idType: PlayerEpisodeEntry.ID.self) {
            if let id = displayed.entries.first?.id, $0.contains(id) {
                previousEpisodeLoadID = id
            }
            if let id = displayed.entries.last?.id, $0.contains(id) {
                nextEpisodeLoadID = id
            }
        }
        .task(id: previousEpisodeLoadID) {
            guard previousEpisodeLoadID != nil else { return }
            await browser.loadPrevious()
        }
        .task(id: nextEpisodeLoadID) {
            guard nextEpisodeLoadID != nil else { return }
            await browser.loadNext()
        }
        .onAppear {
            displayedEpisodes = latest
            if let id = browser.initialEntryID {
                if metrics.isVertical {
                    episodePosition.scrollTo(id: id, anchor: .top)
                } else if let index = latest.entries.firstIndex(where: { $0.id == id }) {
                    episodePosition.scrollTo(x: layout.episodeOffset(for: index))
                }
            }
        }
    }

    private func updateDisplayedEpisodes(_ latest: EpisodeRowContent) {
        guard let previous = displayedEpisodes, previous != latest else { return }
        let prependedCount = previous.entries.first.flatMap { first in
            latest.entries.firstIndex { $0.id == first.id }
        } ?? 0
        let pitch = metrics.isVertical ? metrics.castRowHeight + 8 : layout.cardWidth + layout.columnSpacing
        let retryPitch = metrics.isVertical ? max(120, metrics.castRowHeight) + 8 : pitch
        let errorDelta = (latest.previousError == nil ? 0 : 1) - (previous.previousError == nil ? 0 : 1)
        let shift = CGFloat(prependedCount) * pitch + CGFloat(errorDelta) * retryPitch
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedEpisodes = latest
            if shift != 0 {
                if metrics.isVertical {
                    episodePosition.scrollTo(y: max(0, episodeOffset.y + shift))
                } else {
                    episodePosition.scrollTo(x: max(0, episodeOffset.x + shift))
                }
            }
        }
    }

    private func playlistRow(_ playlist: VideoPlaylistPlaybackContext) -> some View {
        ScrollViewReader { proxy in
            sequenceScroll {
                ForEach(0..<playlist.totalCount, id: \.self) { index in
                    Group {
                        if let item = playlist.items[index] {
                            card(
                                item, focusSlot: .sequenceItem(index),
                                selected: index == playlist.currentIndex
                            ) {
                                Task { await player.playPlaylistItem(at: index) }
                            }
                        } else {
                            RoundedRectangle(cornerRadius: metrics.isVertical ? 14 : cardMetrics.landscapeCardCornerRadius)
                                .fill(.white.opacity(0.12))
                                .frame(
                                    width: metrics.isVertical ? nil : layout.cardWidth,
                                    height: metrics.isVertical ? metrics.castRowHeight : layout.rowHeight
                                )
                                .task(id: playlist.retryGeneration) {
                                    do {
                                        _ = try await playlist.item(at: index)
                                    } catch is CancellationError {
                                        return
                                    } catch {
                                        // The context exposes the error beside the row.
                                    }
                                }
                        }
                    }
                    .id(index)
                }
            }
            .onAppear {
                if playlist.currentIndex > 0 {
                    proxy.scrollTo(
                        playlist.currentIndex, anchor: metrics.isVertical ? .top : .leading
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func sequenceScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if metrics.isVertical {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8, content: content)
                    .scrollTargetLayout()
                    .padding(.vertical, metrics.contentPadding)
            }
            .frame(height: layout.rowHeight)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: layout.columnSpacing, content: content)
                    .scrollTargetLayout()
                    .padding(.trailing, metrics.contentPadding)
            }
            .frame(height: layout.rowHeight)
            .scrollClipDisabled()
        }
    }

    private func card(
        _ item: MediaItem, focusSlot: PlayerControls.FocusSlot, selected: Bool,
        episodeBadge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == focusSlot
        return Button(action: action) {
            Group {
                if metrics.isVertical {
                    HStack(spacing: 12) {
                        thumbnail(item)
                            .frame(
                                width: (metrics.castRowHeight - 12) * 16 / 9,
                                height: metrics.castRowHeight - 12
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            if let episodeBadge {
                                Text(verbatim: episodeBadge)
                                    .font(metrics.castRoleFont)
                                    .foregroundStyle(.secondary)
                            }
                            title(item)
                                .font(metrics.castNameFont)
                                .lineLimit(source == .episodes ? 1 : 2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: metrics.castRowHeight)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        thumbnail(item)
                            .frame(width: layout.imageWidth, height: layout.imageHeight)
                            .clipShape(RoundedRectangle(
                                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                                style: .continuous
                            ))
                            .plozzMediaEdge(
                                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                            )
                            .overlay(alignment: .bottomLeading) {
                                if source == .episodes, let episodeBadge {
                                    PlayerEpisodeArtworkOverlay(badge: episodeBadge, layout: layout)
                                }
                            }
                        Group {
                            if source == .episodes {
                                PlozzMarqueeText(
                                    text: title(item), font: metrics.castNameFont,
                                    color: .primary, inset: 0, isFocused: isFocused
                                )
                            } else {
                                title(item)
                                    .font(metrics.castNameFont)
                                    .fontWeight(selected ? .bold : .semibold)
                                    .lineLimit(layout.compact ? 1 : 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: layout.titleHeight, alignment: .center)
                        .padding(.horizontal, cardMetrics.landscapeCaptionHorizontalInset)
                        .padding(.top, cardMetrics.landscapeCaptionTopSpacing)
                    }
                    .padding([.top, .horizontal], cardMetrics.cardInset)
                    .padding(.bottom, layout.bottomInset)
                    .frame(width: layout.cardWidth, height: layout.rowHeight, alignment: .topLeading)
                }
            }
        }
        .buttonStyle(PlayerSequenceCardStyle(
            focused: isFocused,
            cornerRadius: metrics.isVertical ? 14 : cardMetrics.landscapeCardCornerRadius,
            contained: source == .episodes,
            focusScale: metrics.isVertical ? 1 : 1.10
        ))
        .focusEffectDisabled(source == .episodes)
        .focused($focus, equals: focusSlot)
        .accessibilityLabel(title(item))
        .accessibilityValue(Text(verbatim: episodeBadge ?? ""))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func title(_ item: MediaItem) -> Text {
        if player.spoilerSettings.shouldHideText(for: item) {
            return Text(player.spoilerSettings.maskedTitle(for: item))
        }
        return Text(verbatim: item.title)
    }

    @ViewBuilder
    private func thumbnail(_ item: MediaItem) -> some View {
        if item.kind == .episode {
            let source = EpisodeArtworkSource(item: item, spoilerSettings: player.spoilerSettings)
            FallbackAsyncImage(
                references: source.references, variant: .landscapeCard,
                asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity
            ) {
                thumbnailPlaceholder
            }
            .blur(radius: player.spoilerSettings.shouldHideThumbnail(for: item)
                  && player.spoilerSettings.mode == .blur ? 28 : 0)
        } else {
            FallbackAsyncImage(
                references: item.artworkReferences(for: .episodeThumbnail), variant: .landscapeCard
            ) {
                thumbnailPlaceholder
            }
        }
    }

    private var thumbnailPlaceholder: some View {
        Image(systemName: "play.rectangle")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.12))
    }
}

struct PlayerEpisodeArtworkOverlay: View {
    let badge: String
    let layout: PlayerSequenceLayout

    var body: some View {
        MediaArtworkChromeScrim(top: false, bottom: true)
            .overlay(alignment: .bottomLeading) {
                Text(verbatim: badge)
                    .font(layout.metrics.castRoleFont.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(layout.cardMetrics.resumeChipInset)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous
            ))
            .allowsHitTesting(false)
    }
}

struct PlayerEpisodeLoadingRow: View {
    let layout: PlayerSequenceLayout
    let showsPrevious: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView(layout.metrics.isVertical ? .vertical : .horizontal, showsIndicators: false) {
                if layout.metrics.isVertical {
                    VStack(spacing: 8) {
                        ForEach(0..<6) { _ in PlayerEpisodeLoadingCard(layout: layout) }
                    }
                    .padding(.vertical, layout.metrics.contentPadding)
                } else {
                    let count = max(2, Int(ceil(geometry.size.width / (layout.cardWidth + layout.columnSpacing))) + 2)
                    HStack(spacing: layout.columnSpacing) {
                        ForEach(0..<count, id: \.self) { _ in
                            PlayerEpisodeLoadingCard(layout: layout)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .offset(x: showsPrevious ? -layout.episodeOffset(for: 1) : 0)
                }
            }
            .scrollDisabled(true)
            .scrollClipDisabled()
        }
        .frame(height: layout.rowHeight)
    }
}

struct PlayerEpisodeLoadingCard: View {
    let layout: PlayerSequenceLayout
    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if layout.metrics.isVertical {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.fill)
                        .frame(
                            width: (layout.metrics.castRowHeight - 12) * 16 / 9,
                            height: layout.metrics.castRowHeight - 12
                        )
                    Capsule()
                        .fill(palette.fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: layout.metrics.castNameSize * 0.7)
                }
                .padding(.horizontal, 12)
                .frame(height: layout.metrics.castRowHeight)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(
                        cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous
                    )
                    .fill(palette.fill)
                    .frame(width: layout.imageWidth, height: layout.imageHeight)
                    Capsule()
                        .fill(palette.fill)
                        .frame(width: layout.imageWidth * 0.65, height: layout.metrics.castNameSize * 0.7)
                        .frame(height: layout.titleHeight)
                        .padding(.horizontal, layout.cardMetrics.landscapeCaptionHorizontalInset)
                        .padding(.top, layout.cardMetrics.landscapeCaptionTopSpacing)
                }
                .padding([.top, .horizontal], layout.cardMetrics.cardInset)
                .padding(.bottom, layout.bottomInset)
                .frame(width: layout.cardWidth, height: layout.rowHeight, alignment: .topLeading)
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

struct PlayerEpisodePanelSurface: ViewModifier {
    let layout: PlayerSequenceLayout

    func body(content: Content) -> some View {
        content
            .frame(height: layout.rowHeight)
            .padding(.horizontal, layout.metrics.contentPadding)
            .padding(.vertical, layout.containerVerticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Keep TVUIKit's focused projection out of the panel's glass compositor.
                Color.clear.modifier(PanelGlassBackground(cornerRadius: layout.metrics.panelCornerRadius))
            }
            .clipShape(RoundedRectangle(
                cornerRadius: layout.metrics.panelCornerRadius,
                style: .continuous
            ))
    }
}

private struct PlayerSequenceCardStyle: ButtonStyle {
    let focused: Bool
    let cornerRadius: CGFloat
    let contained: Bool
    let focusScale: CGFloat

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if contained {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        } else {
            PlayerOverVideoCardStyle(
                focused: focused, cornerRadius: cornerRadius, focusScale: focusScale
            ).makeBody(configuration: configuration)
        }
    }
}
#endif
