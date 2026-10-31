#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The shared watch-state chip shown over an episode thumbnail on both iOS and
/// tvOS detail pages. It renders the same three states everywhere so the
/// resume affordance is consistent across platforms:
///  - **in progress** → `▶ [progress bar] 12m` (reusing ``ResumeProgressCapsule``,
///    the exact bar used inside the hero Play/Resume button),
///  - **watched** → a checkmark,
///  - **not started** → the plain runtime (e.g. `52m`).
///
/// The `showsRuntimeWhenIdle` / `showsWatched` flags let a platform opt out of
/// the idle/watched forms: tvOS keeps its own corner watched badge and shows the
/// chip only while an episode is in progress, whereas iOS uses the chip for all
/// three states. When there's nothing to show the view renders empty (no chip).
public struct EpisodeWatchStatePill: View {
    private let item: MediaItem
    private let showsRuntimeWhenIdle: Bool
    private let showsWatched: Bool
    private let showsBackground: Bool
    private let barWidth: CGFloat
    private let barHeight: CGFloat
    private let playGlyphHeight: CGFloat?
    private let detailText: String?
    private let showsPlayGlyphWhenIdle: Bool
    private let spacing: CGFloat
    private var fittingFontSize: CGFloat?

    @Environment(\.plozzChromeIsFocused) private var isFocused
    @Environment(\.plozzShowsProgressBars) private var showsProgressBars

    /// - Parameters:
    ///   - detailText: a short qualifier shown immediately before the duration
    ///     (e.g. `S4 E1`), joined with `·`. Continue Watching uses it so a card
    ///     whose artwork is the *show* still says which episode you are on.
    ///   - showsPlayGlyphWhenIdle: draws the play glyph on the not-started form
    ///     too. An unstarted episode has no progress to draw, so the bar is
    ///     omitted and the glyph alone carries "this resumes".
    public init(
        item: MediaItem,
        showsRuntimeWhenIdle: Bool = true,
        showsWatched: Bool = true,
        showsBackground: Bool = true,
        barWidth: CGFloat = 54,
        barHeight: CGFloat = 5,
        playGlyphHeight: CGFloat? = nil,
        detailText: String? = nil,
        showsPlayGlyphWhenIdle: Bool = false,
        spacing: CGFloat = 8
    ) {
        self.item = item
        self.showsRuntimeWhenIdle = showsRuntimeWhenIdle
        self.showsWatched = showsWatched
        self.showsBackground = showsBackground
        self.barWidth = barWidth
        self.barHeight = barHeight
        self.playGlyphHeight = playGlyphHeight
        self.detailText = detailText
        self.showsPlayGlyphWhenIdle = showsPlayGlyphWhenIdle
        self.spacing = spacing
    }

    fileprivate func fittingText(size: CGFloat?) -> Self {
        var result = self
        result.fittingFontSize = size
        return result
    }

    private enum State {
        case watched
        /// `remaining` is optional: an item can be resumable without a known
        /// runtime (some providers omit it, and a series-level entry has none), and
        /// the glyph + bar are the useful part. Requiring the label meant those
        /// items lost the whole chip and fell back to the plain full-width bar, so
        /// Continue Watching showed two different treatments side by side.
        case inProgress(fraction: Double, remaining: String?)
        /// Not started. The duration is optional so a provider that reports no
        /// runtime can still show a `detailText`-only chip — without it a Continue
        /// Watching card, which has no caption to fall back on, would say nothing
        /// at all about which episode it is.
        case runtime(String?)
    }

    private var state: State? {
        if showsWatched, item.isPlayed {
            return .watched
        }
        if let fraction = item.resumeProgressFraction {
            return .inProgress(fraction: fraction, remaining: item.resumeRemainingText)
        }
        if showsRuntimeWhenIdle, let runtime = item.runtime?.runtimeBadgeText {
            return .runtime(runtime)
        }
        if showsPlayGlyphWhenIdle, detailText?.isEmpty == false {
            return .runtime(nil)
        }
        return nil
    }

    public var body: some View {
        if let state {
            content(for: state)
                .foregroundStyle(PlozzMediaChrome.foreground(isFocused: isFocused))
                .lineLimit(1)
                // Flat. Legibility is the scrim's job (`MediaArtworkChromeScrim`);
                // a shadow here made the chip read as a sticker on the artwork
                // rather than part of it.
                .modifier(
                    PillBackground(enabled: showsBackground)
                )
        }
    }

    @ViewBuilder
    private func content(for state: State) -> some View {
        switch state {
        case .watched:
            Image(systemName: "checkmark")
                .fontWeight(.bold)
                .accessibilityLabel("Watched")
        case let .inProgress(fraction, remaining):
            playbackContent(fraction: fraction, text: joined(remaining), showsPlay: true)
            .accessibilityLabel(
                remaining.map { Text("\($0) left") }
                    ?? Text(
                        "Partly watched",
                        comment: """
                            Accessibility label for the progress chip on a partly \
                            watched card, used when the remaining time is unknown. \
                            Describes watch state, not a command.
                            """
                    )
            )
        case let .runtime(text):
            // Nothing has been watched, so there is no progress to draw. Omitting
            // the bar rather than drawing an empty one keeps the chip honest — an
            // unstarted episode showing a 0% bar reads as a stalled download.
            if let label = joined(text) {
                playbackContent(fraction: nil, text: label, showsPlay: showsPlayGlyphWhenIdle)
            }
        }
    }

    @ViewBuilder
    private func playbackContent(fraction: Double?, text: String?, showsPlay: Bool) -> some View {
        if let fittingFontSize, let text {
            ViewThatFits(in: .horizontal) {
                playbackRow(fraction: fraction, text: text, showsPlay: showsPlay)
                    .fixedSize(horizontal: true, vertical: true)
                if showsPlay {
                    playbackRow(fraction: fraction, text: text, showsPlay: false)
                        .fixedSize(horizontal: true, vertical: true)
                }
                Text(verbatim: text)
                    .fixedSize(horizontal: true, vertical: true)
                // Only after both decorations yield may the label get smaller.
                // Extreme widths wrap rather than ellipsize or shrink indefinitely.
                Text(verbatim: text)
                    .font(.system(size: fittingFontSize * 0.85, weight: .semibold))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .minimumScaleFactor(1)
        } else {
            playbackRow(fraction: fraction, text: text, showsPlay: showsPlay)
        }
    }

    private func playbackRow(fraction: Double?, text: String?, showsPlay: Bool) -> some View {
        HStack(spacing: spacing) {
            if showsPlay { playGlyph }
            if showsProgressBars, let fraction {
                ResumeProgressCapsule(
                    progress: fraction, onLight: false,
                    width: barWidth, height: barHeight, flexesToFitRow: fittingFontSize == nil
                )
                .layoutPriority(0)
            }
            if let text {
                Text(verbatim: text).layoutPriority(1)
            }
        }
    }

    /// `detailText` and a duration as one dotted run — "S4 E1 · 22m" — dropping
    /// either side when it is absent.
    private func joined(_ duration: String?) -> String? {  // l10n:content — joins a hand-built S/E designation with a formatted duration
        let parts = [detailText, duration].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var playGlyph: some View {
        if let playGlyphHeight {
            Image(systemName: "play.fill")
                .resizable()
                .scaledToFit()
                .frame(height: playGlyphHeight)
        } else {
            Image(systemName: "play.fill")
        }
    }
}

/// Wraps pill content in the optional dark capsule. When disabled the pill has
/// no background at all — legibility comes from the host image's dark scrim plus
/// the text shadow — matching the "no solid background behind text" rule.
private struct PillBackground: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
        } else {
            content
        }
    }
}

/// The shared resume/runtime chip overlay drawn on a landscape thumbnail — used
/// identically by episode cards and immediate-play (Continue Watching / landscape
/// library) cards so both read the same. A soft bottom-leading legibility scrim
/// with the white play/progress/time chip (in progress) or plain runtime (not
/// started), no solid capsule. Renders nothing when the item has no runtime to
/// show. Callers gate it on artwork being visible (not blurred/hidden).
public struct ResumeChipOverlay: View {
    private let item: MediaItem
    private let downloadState: MediaDownloadBadgeState?
    private let showsMenu: Bool
    private let detailText: String?
    private let showsPlayGlyphWhenIdle: Bool
    private let bottomScrimStart: CGFloat?
    private let bottomScrimDepth: CGFloat?
    private let compactHorizontalLayout: Bool
    private var rendersScrim = true

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - downloadState: optional trailing download affordance. `nil` renders the
    ///     chip as before, so surfaces with no download concept are unaffected.
    ///   - showsMenu: draws the visible "…" actions menu. A press-and-hold menu is
    ///     discoverable on tvOS (cards focus before they're chosen) but hidden on a
    ///     touch card, so touch surfaces opt in.
    ///   - detailText: a short qualifier shown before the duration (e.g. `S4 E1`).
    ///   - showsPlayGlyphWhenIdle: give the not-started form a play glyph and no
    ///     progress bar.
    ///   - bottomScrimStart: where the legibility scrim starts darkening, as a
    ///     fraction of the artwork's height. `nil` keeps the shared default.
    ///   - bottomScrimDepth: how dark that scrim gets at the bottom edge. `nil`
    ///     keeps the shared default; a host that lays its own wash over the same
    ///     region passes less, since the two compound.
    public init(
        item: MediaItem,
        downloadState: MediaDownloadBadgeState? = nil,
        showsMenu: Bool = false,
        detailText: String? = nil,
        showsPlayGlyphWhenIdle: Bool = false,
        bottomScrimStart: CGFloat? = nil,
        bottomScrimDepth: CGFloat? = nil,
        compactHorizontalLayout: Bool = false
    ) {
        self.item = item
        self.downloadState = downloadState
        self.showsMenu = showsMenu
        self.detailText = detailText
        self.showsPlayGlyphWhenIdle = showsPlayGlyphWhenIdle
        self.bottomScrimStart = bottomScrimStart
        self.bottomScrimDepth = bottomScrimDepth
        self.compactHorizontalLayout = compactHorizontalLayout
    }

    public var body: some View {
        // The scrim exists for the chrome's legibility, so with nothing to show
        // there's nothing to darken — a card with no runtime stays clean.
        if hasBottomChrome || showsMenu {
            Color.clear
                .overlay {
                    if rendersScrim, let artworkScrim { artworkScrim }
                }
                .overlay(alignment: .topLeading) {
                    if showsMenu {
                        MediaItemEllipsisMenu(item: item)
                    }
                }
            .allowsHitTesting(showsMenu)
            .overlay(alignment: .bottom) {
                // The bar is sized against the CARD, not a constant. At its full
                // width it fits a landscape thumbnail comfortably, but a poster in
                // a dense grid can be ~86pt wide, where a fixed bar plus the time
                // text would overflow the card. Reading the host's width keeps the
                // wide cards pixel-identical and only shrinks where it must.
                //
                // On a card whose bar is flexible (see `flexesToFitRow`) this is a
                // CEILING rather than the width: the label outranks the bar, so
                // what it actually gets is whatever the label leaves, up to this.
                // The ceiling itself stays the tuned width — a share of the card
                // was tried instead and gave a gauge that ran most of the way
                // across a wide tvOS card.
                GeometryReader { geometry in
                    let spacingInset = compactHorizontalLayout
                        ? min(metrics.resumeChipInset, geometry.size.width * 0.05) : metrics.resumeChipInset
                    let barWidth = min(
                        metrics.resumeChipBarWidth,
                        max(20, geometry.size.width * 0.42)
                    )
                    let stacksDownload = prioritizesText && dynamicTypeSize.isAccessibilitySize && downloadState != nil
                    let layout = stacksDownload
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacingInset * 0.5))
                        : AnyLayout(HStackLayout(alignment: .center, spacing: spacingInset * 0.5))
                    layout {
                        if item.cardRuntimeText != nil
                            || item.resumeProgressFraction != nil
                            || (showsPlayGlyphWhenIdle && detailText?.isEmpty == false) {
                            EpisodeWatchStatePill(
                                item: item,
                                showsRuntimeWhenIdle: true,
                                showsWatched: false,
                                showsBackground: false,
                                barWidth: barWidth,
                                barHeight: metrics.resumeChipBarHeight,
                                detailText: detailText,
                                showsPlayGlyphWhenIdle: showsPlayGlyphWhenIdle,
                                spacing: compactHorizontalLayout ? spacingInset * 0.5 : 8
                            )
                            .fittingText(size: prioritizesText ? metrics.resumeChipFontSize : nil)
                            .font(.system(size: metrics.resumeChipFontSize, weight: .semibold))
                            // The card grows with Dynamic Type to keep this label
                            // whole (see `PlozzMetrics.continueWatchingWidth`),
                            // but that growth is capped so a card can't outgrow a
                            // phone. Past the cap this is what keeps "S1, E1 ·
                            // 43m" readable instead of "S1, E1 · 4…": a smaller
                            // label still says which episode, a truncated one
                            // does not.
                            .minimumScaleFactor(0.6)
                        }
                        // Keeps the download badge pinned trailing whether or not
                        // the pill is present, so it never drifts to the leading edge.
                        if !stacksDownload {
                            Spacer(minLength: spacingInset * 0.5)
                        }
                        if let downloadState {
                            MediaDownloadBadge(
                                state: downloadState,
                                size: metrics.resumeChipAccessorySize
                            )
                            .frame(maxWidth: stacksDownload ? .infinity : nil, alignment: .trailing)
                        }
                    }
                    .background {
                        if prioritizesText {
                            GeometryReader { contentGeometry in
                                Color.clear.preference(
                                    key: PortraitPlaybackHeightKey.self,
                                    value: ceil(contentGeometry.size.height) + metrics.resumeChipInset + 4
                                )
                            }
                        }
                    }
                    .padding(metrics.resumeChipInset)
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .bottom
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }

    var withoutScrim: Self {
        var result = self
        result.rendersScrim = false
        return result
    }

    private var prioritizesText: Bool {
        #if os(iOS)
        compactHorizontalLayout
        #else
        false
        #endif
    }

    var artworkScrim: MediaArtworkChromeScrim? {
        guard hasBottomChrome || showsMenu else { return nil }
        return MediaArtworkChromeScrim(
            top: showsMenu, bottom: hasBottomChrome,
            bottomStart: bottomScrimStart ?? 0.52,
            bottomDepth: bottomScrimDepth ?? 0.78
        )
    }

    /// Anything to draw along the bottom edge. Resume progress counts even with no
    /// runtime text — see `EpisodeWatchStatePill.State.inProgress`.
    private var hasBottomChrome: Bool {
        item.cardRuntimeText != nil
            || item.resumeProgressFraction != nil
            || downloadState != nil
            // A designation alone is worth a chip: on a series-artwork card it is
            // the only thing naming the episode.
            || (showsPlayGlyphWhenIdle && detailText?.isEmpty == false)
    }

}
#endif
