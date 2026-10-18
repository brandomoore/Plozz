#if canImport(SwiftUI)
import CoreModels
import SwiftUI

enum NativePosterIndicatorLayer: Equatable {
    case combined, background, foreground
}

private struct NativePosterIndicatorLayerKey: EnvironmentKey {
    static let defaultValue = NativePosterIndicatorLayer.combined
}

extension EnvironmentValues {
    var nativePosterIndicatorLayer: NativePosterIndicatorLayer {
        get { self[NativePosterIndicatorLayerKey.self] }
        set { self[NativePosterIndicatorLayerKey.self] = newValue }
    }
}

public struct MediaCardPlaybackIndicators: View {
    /// Only the playback and request facts this view actually renders.
    ///
    /// SwiftUI compares a view's stored inputs field-by-field to decide whether
    /// to re-run its body, and `MediaItem` has 56 stored properties including
    /// several arrays. Storing the whole item made every card pay a 56-field
    /// deep comparison — plus a full struct copy — on every update pass. In a
    /// Time Profiler trace of ordinary browsing, `MediaItem.__derived_struct_equals`
    /// and `initializeWithCopy for MediaItem` were among the hottest symbols on
    /// the main thread. Narrowing the input is Apple's prescribed fix.
    private let playback: MediaPlaybackIndicatorState
    private let hidesStatus: Bool
    private let progressBarEnabled: Bool
    private let badgeInset: CGFloat
    private let progressHeight: CGFloat
    private let progressHorizontalInset: CGFloat
    private let progressBottomInset: CGFloat
    private let artworkCornerRadius: CGFloat?
    /// Offline state for this item, drawn bottom-trailing. Lives here (rather than
    /// only inside the resume chip) because "is this downloaded?" is wanted on
    /// EVERY card, including plain browsing posters that carry no chip.
    private let downloadState: MediaDownloadBadgeState?
    private var rendersStatus = true
    private var rendersBottom = true
    private var rendersScrim = true

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.plozzShowsUnwatchedEpisodeCount) private var showsUnwatchedEpisodeCount
    /// Whether an unowned title can be requested, or is merely flagged as absent.
    @Environment(\.plozzSeerConnected) private var seerConnected
    /// Published by the hosting card so this chrome can settle back at rest and
    /// come to full strength on focus (tvOS only — see ``PlozzMediaChrome``).
    @Environment(\.plozzChromeIsFocused) private var isFocused
    @Environment(\.nativePosterIndicatorLayer) private var nativeIndicatorLayer

    public init(
        item: MediaItem,
        hidesStatus: Bool = false,
        showsProgressBar: Bool = true,
        badgeInset: CGFloat,
        progressHeight: CGFloat = 0,
        progressHorizontalInset: CGFloat = 0,
        progressBottomInset: CGFloat = 0,
        downloadState: MediaDownloadBadgeState? = nil,
        artworkCornerRadius: CGFloat? = nil
    ) {
        self.init(
            playback: MediaPlaybackIndicatorState(item),
            hidesStatus: hidesStatus, showsProgressBar: showsProgressBar,
            badgeInset: badgeInset, progressHeight: progressHeight,
            progressHorizontalInset: progressHorizontalInset, progressBottomInset: progressBottomInset,
            downloadState: downloadState, artworkCornerRadius: artworkCornerRadius
        )
    }

    init(
        playback: MediaPlaybackIndicatorState,
        hidesStatus: Bool,
        showsProgressBar: Bool,
        badgeInset: CGFloat,
        progressHeight: CGFloat,
        progressHorizontalInset: CGFloat,
        progressBottomInset: CGFloat,
        downloadState: MediaDownloadBadgeState? = nil,
        artworkCornerRadius: CGFloat?
    ) {
        self.playback = playback
        self.hidesStatus = hidesStatus
        self.progressBarEnabled = showsProgressBar
        self.badgeInset = badgeInset
        self.progressHeight = progressHeight
        self.progressHorizontalInset = progressHorizontalInset
        self.progressBottomInset = progressBottomInset
        self.downloadState = downloadState
        self.artworkCornerRadius = artworkCornerRadius
    }

    public var body: some View {
        Color.clear
            // One scrim for ALL bottom chrome, drawn beneath it. Shared with the
            // resume chip (``MediaArtworkChromeScrim``) so a card's bottom edge
            // darkens identically whichever treatment it carries.
            //
            // It used to live inside `progressBar`, which meant a downloaded but
            // unstarted card had its badge floating on bare artwork, and the ramp
            // was a full-length linear fade whose darkening was so spread out it
            // was hard to see at all. The shared scrim holds clear until ~62% and
            // then ramps, so the darkening is concentrated where the chrome is.
            .overlay {
                if nativeIndicatorLayer != .foreground, rendersScrim, let artworkScrim {
                    artworkScrim
                }
            }
            .overlay(alignment: .topTrailing) {
                if rendersStatus { statusIndicator }
            }
            .overlay(alignment: .bottom) {
                if nativeIndicatorLayer != .foreground && rendersBottom && progressBarEnabled {
                    progressBar
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if nativeIndicatorLayer != .foreground && rendersBottom { downloadBadge }
            }
            .allowsHitTesting(false)
    }

    struct BitmapInputs: Equatable {
        let playback: MediaPlaybackIndicatorState
        let hidesStatus: Bool
        let progressBarEnabled: Bool
        let badgeInset: CGFloat
        let progressHeight: CGFloat
        let progressHorizontalInset: CGFloat
        let progressBottomInset: CGFloat
        let artworkCornerRadius: CGFloat?
        let downloadState: MediaDownloadBadgeState?
        let rendersStatus: Bool
        let rendersBottom: Bool
        let rendersScrim: Bool
    }

    var bitmapInputs: BitmapInputs {
        BitmapInputs(
            playback: playback, hidesStatus: hidesStatus, progressBarEnabled: progressBarEnabled,
            badgeInset: badgeInset, progressHeight: progressHeight,
            progressHorizontalInset: progressHorizontalInset, progressBottomInset: progressBottomInset,
            artworkCornerRadius: artworkCornerRadius, downloadState: downloadState,
            rendersStatus: rendersStatus, rendersBottom: rendersBottom, rendersScrim: rendersScrim
        )
    }

    fileprivate init(bitmapInputs: BitmapInputs) {
        self.init(
            playback: bitmapInputs.playback, hidesStatus: bitmapInputs.hidesStatus,
            showsProgressBar: bitmapInputs.progressBarEnabled, badgeInset: bitmapInputs.badgeInset,
            progressHeight: bitmapInputs.progressHeight,
            progressHorizontalInset: bitmapInputs.progressHorizontalInset,
            progressBottomInset: bitmapInputs.progressBottomInset,
            downloadState: bitmapInputs.downloadState, artworkCornerRadius: bitmapInputs.artworkCornerRadius
        )
        rendersStatus = bitmapInputs.rendersStatus
        rendersBottom = bitmapInputs.rendersBottom
        rendersScrim = bitmapInputs.rendersScrim
    }

    var statusOnly: Self {
        var result = self
        result.rendersBottom = false
        return result
    }

    var withoutStatus: Self {
        var result = self
        result.rendersStatus = false
        return result
    }

    var withoutScrim: Self {
        var result = self
        result.rendersScrim = false
        return result
    }

    var artworkScrim: MediaArtworkChromeScrim? {
        hasTopChrome || hasBottomChrome
            ? MediaArtworkChromeScrim(top: hasTopChrome, bottom: hasBottomChrome) : nil
    }

    private var showsProgressBar: Bool {
        MediaPlaybackIndicatorPresentation.showsProgress(for: playback)
    }

    /// Any chrome along the card's bottom edge that needs the artwork darkened
    /// behind it — the progress bar, the download badge, or both.
    private var hasBottomChrome: Bool {
        rendersBottom && ((progressBarEnabled && showsProgressBar) || downloadState != nil)
    }

    /// Only the library mark needs the TOP of the artwork darkened. The watched
    /// badge, unwatched flag, and episode counts have filled shapes that carry their
    /// own contrast; the library mark is a bare glyph and the scrim is the entire
    /// reason it stays legible over pale artwork.
    private var hasTopChrome: Bool {
        guard rendersStatus, case .library = status else { return false }
        return true
    }

    private var status: MediaPlaybackIndicatorPresentation.Status? {
        MediaPlaybackIndicatorPresentation.status(
            for: playback, hidesStatus: hidesStatus, indicator: watchStatusIndicator,
            showsEpisodeCount: showsUnwatchedEpisodeCount, seerConnected: seerConnected
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // A title that isn't in the library takes this slot INSTEAD of watch
        // state, not alongside it. Watch state cannot apply to something you
        // don't have — you have neither watched it nor left it unwatched — so
        // the unwatched flag on an external credit was never information, and
        // the two never compete for the corner.
        switch status {
        case .library(let mark):
            if nativeIndicatorLayer != .background {
                MediaLibraryMarkView(mark: mark, size: metrics.watchedBadgeSize)
                    .padding(floatingBadgeInset)
            }
        case .episodeCount(let count):
            episodeCountBadge(count)
        case .watched:
            if nativeIndicatorLayer != .background {
                MediaWatchedBadge(size: metrics.watchedBadgeSize)
                    .padding(floatingBadgeInset)
            }
        case .unwatched:
            MediaUnwatchedCorner(size: metrics.unwatchedFlagSize)
        case nil:
            EmptyView()
        }
    }

    private func episodeCountBadge(_ count: Int) -> some View {
        MediaEpisodeCountBadge(
            count: count, indicator: watchStatusIndicator, size: metrics.watchedBadgeSize,
            cornerRadius: artworkCornerRadius ?? metrics.posterArtworkCornerRadius
        )
        .padding(watchStatusIndicator == .watched ? floatingBadgeInset : 0)
        .accessibilityLabel(Text("Unwatched episodes: \(count)"))
    }

    private var floatingBadgeInset: CGFloat {
        max(badgeInset, MediaWatchIndicatorStyle.floatingInset(for: metrics.watchedBadgeSize))
    }

    /// Offline indicator, pinned to ONE fixed spot in the bottom-trailing corner.
    /// It never moves for the progress bar — a badge that shifts depending on
    /// whether an item happens to be part-watched reads as a glitch across a wall
    /// of cards. The bar yields to it instead (see ``progressTrailingInset``).
    @ViewBuilder
    private var downloadBadge: some View {
        if let downloadState {
            // Same size the resume chip drew it at, so a downloaded card's badge
            // doesn't change scale depending on which chrome path it takes. The
            // larger `watchedBadgeSize` would eat half an 86pt poster.
            MediaDownloadBadge(state: downloadState, size: downloadBadgeSize)
                .padding(.trailing, progressHorizontalInset)
                .padding(.bottom, downloadBadgeBottomInset)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
    }

    private var downloadBadgeSize: CGFloat { metrics.resumeChipAccessorySize }

    /// Centres the badge on the bar's line rather than sharing its baseline — the
    /// badge is taller than the bar, so a shared baseline leaves its mass sitting
    /// above the line. Derived only from constants, so the badge lands in the
    /// identical spot on every card whether or not a bar is drawn.
    private var downloadBadgeBottomInset: CGFloat {
        max(0, progressBottomInset - (downloadBadgeSize - progressHeight) / 2)
    }

    /// The bar runs from the leading edge to just before the download badge, so
    /// the two sit on one line and neither is obscured. With no badge it reaches
    /// the card's normal inset.
    ///
    /// The gap it leaves before the badge is the SAME value as the bar's own edge
    /// inset, so the whole strip is evenly spaced: inset · bar · inset · badge ·
    /// inset.
    private var progressTrailingInset: CGFloat {
        guard downloadState != nil else { return progressHorizontalInset }
        return progressHorizontalInset * 2 + downloadBadgeSize
    }

    @ViewBuilder
    private var progressBar: some View {
        if showsProgressBar, let percentage = playback.playedPercentage {
            let shadowRadius = progressHeight * 0.25
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Matches ``ResumeProgressCapsule`` — the same white bar the
                    // resume chip and the detail Play button draw — so progress
                    // reads identically wherever it appears. Deliberately not the
                    // brand blue: colour is reserved for specific moments, and a
                    // white bar sits better over arbitrary artwork.
                    Capsule(style: .continuous)
                        .fill(PlozzMediaChrome.track(isFocused: isFocused))
                    Capsule(style: .continuous)
                        .fill(PlozzMediaChrome.foreground(isFocused: isFocused))
                        .frame(
                            width: max(
                                progressHeight,
                                geometry.size.width * percentage
                            )
                        )
                        .shadow(
                            color: .black.opacity(0.35),
                            radius: shadowRadius
                        )
                }
            }
            .frame(height: progressHeight)
            .padding(.leading, progressHorizontalInset)
            .padding(.trailing, progressTrailingInset)
            .padding(.bottom, progressBottomInset)
        }
    }
}

enum NativePosterIndicators: View, Equatable {
    case playback(MediaCardPlaybackIndicators.BitmapInputs)
    case episode(isWatched: Bool, hasProgress: Bool, isVisible: Bool,
                 style: WatchStatusIndicator, badgeSize: CGFloat, flagSize: CGFloat)

    static func media(_ indicators: MediaCardPlaybackIndicators) -> Self {
        .playback(indicators.bitmapInputs)
    }

    func hasContent(indicator: WatchStatusIndicator, showsEpisodeCount: Bool, seerConnected: Bool) -> Bool {
        switch self {
        case .playback(let inputs):
            if inputs.rendersBottom { return true }
            return inputs.rendersStatus && MediaPlaybackIndicatorPresentation.status(
                for: inputs.playback, hidesStatus: inputs.hidesStatus, indicator: indicator,
                showsEpisodeCount: showsEpisodeCount, seerConnected: seerConnected
            ) != nil
        case let .episode(isWatched, hasProgress, isVisible, style, _, _):
            return isVisible && (style == .watched ? isWatched : !isWatched && !hasProgress)
        }
    }

    @ViewBuilder var body: some View {
        switch self {
        case .playback(let inputs):
            MediaCardPlaybackIndicators(bitmapInputs: inputs)
        case let .episode(isWatched, hasProgress, isVisible, style, badgeSize, flagSize):
            Color.clear.overlay(alignment: .topTrailing) {
                if isVisible {
                    switch style {
                    case .watched:
                        if isWatched {
                            MediaWatchedBadge(size: badgeSize)
                                .padding(max(12, MediaWatchIndicatorStyle.floatingInset(for: badgeSize)))
                        }
                    case .unwatched:
                        if !isWatched && !hasProgress {
                            MediaUnwatchedCorner(size: flagSize)
                        }
                    }
                }
            }
        }
    }
}

enum MediaWatchIndicatorStyle {
    /// The badge and flag fill. Fixed sRGB values rather than system colours so
    /// the mark looks the same in every theme and appearance.
    static func fill(_ color: WatchIndicatorColor) -> Color {
        switch color {
        case .white: .white
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .green: Color(red: 0.19, green: 0.78, blue: 0.35)
        case .yellow: Color(red: 1.0, green: 0.80, blue: 0.0)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.0)
        case .red: Color(red: 1.0, green: 0.23, blue: 0.19)
        case .pink: Color(red: 1.0, green: 0.18, blue: 0.53)
        case .purple: Color(red: 0.69, green: 0.32, blue: 0.87)
        }
    }

    /// The check glyph over `fill(_:)`: dark on the light fills, white otherwise.
    static func foreground(_ color: WatchIndicatorColor) -> Color {
        switch color {
        case .white, .yellow, .orange, .green: Color(white: 0.13)
        case .blue, .red, .pink, .purple: .white
        }
    }

    static let edge = Color.white.opacity(0.32)
    static let countFill = Color(white: 0.08).opacity(0.88)
    static let countForeground = Color.white
    static let countEdge = Color.white.opacity(0.18)

    static func floatingInset(for size: CGFloat) -> CGFloat {
        16 * size / PlozzTheme.Metrics.watchedBadgeSize
    }
}

struct MediaWatchedBadge: View {
    let size: CGFloat
    @Environment(\.plozzWatchIndicatorColor) private var color
    private var scale: CGFloat { size / PlozzTheme.Metrics.watchedBadgeSize }

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.53, weight: .bold))
            .foregroundStyle(MediaWatchIndicatorStyle.foreground(color))
            .frame(width: size, height: size)
            .background(Circle().fill(MediaWatchIndicatorStyle.fill(color)))
            .overlay(Circle().stroke(MediaWatchIndicatorStyle.edge, lineWidth: scale))
            .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: scale)
    }
}

struct MediaUnwatchedCorner: View {
    let size: CGFloat
    @Environment(\.plozzWatchIndicatorColor) private var color
    private var scale: CGFloat { size / PlozzTheme.Metrics.unwatchedFlagSize }

    var body: some View {
        TopTrailingCornerFlag()
            .fill(MediaWatchIndicatorStyle.fill(color))
            .shadow(color: .black.opacity(0.28), radius: 8 * scale)
            .overlay {
                TopTrailingCornerFlagEdge().stroke(.black.opacity(0.3), lineWidth: scale)
            }
            .frame(width: size, height: size)
    }
}

struct MediaEpisodeCountBadge: View {
    let count: Int
    let indicator: WatchStatusIndicator
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.nativePosterIndicatorLayer) private var nativeIndicatorLayer
    private var scale: CGFloat { size / PlozzTheme.Metrics.watchedBadgeSize }

    private var digits: some View {
        Text(count, format: .number.grouping(.never))
            .font(.system(size: 24 * scale, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(MediaWatchIndicatorStyle.countForeground)
    }

    @ViewBuilder var body: some View {
        switch indicator {
        case .watched:
            if nativeIndicatorLayer != .background {
                digits
                    .padding(.horizontal, 12 * scale)
                    .frame(minWidth: size, minHeight: size)
                    .background(RoundedRectangle(cornerRadius: 11 * scale).fill(MediaWatchIndicatorStyle.countFill))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11 * scale)
                            .stroke(MediaWatchIndicatorStyle.countEdge, lineWidth: scale)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: scale)
            }
        case .unwatched:
            let height = 52 * scale
            let width = max(48, 24 + CGFloat(String(count).count) * 16) * scale
            let radius = min(cornerRadius, height / 2)
            digits
                .opacity(nativeIndicatorLayer == .background ? 0 : 1)
                .padding(.horizontal, 12 * scale)
                .frame(maxWidth: width, minHeight: height, maxHeight: height)
                // Only the inner corner is rounded; the artwork clips the outer corner and shadow.
                .background {
                    if nativeIndicatorLayer != .foreground {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: radius,
                            bottomTrailingRadius: 0, topTrailingRadius: 0, style: .circular
                        )
                        .fill(MediaWatchIndicatorStyle.countFill)
                        .shadow(color: .black.opacity(0.28), radius: 8 * scale)
                        .overlay {
                            TopTrailingCurvedCornerEdge(radius: radius)
                                .stroke(MediaWatchIndicatorStyle.countEdge, lineWidth: scale)
                        }
                    }
                }
        }
    }
}

/// The playback and request facts a card's indicators draw from — scalars lifted out
/// of `MediaItem` so a card's comparison surface is bounded by what it shows.
/// See ``MediaCardPlaybackIndicators``'s stored property for the measurements.
public struct MediaPlaybackIndicatorState: Equatable, Sendable {
    public let kind: MediaItemKind
    public let isPlayed: Bool
    public let playedPercentage: Double?
    public let unwatchedEpisodeCount: Int?
    public let resumePosition: Double?
    /// Ownership and request availability are separate: a pending request is
    /// still unowned, but must invalidate the snapshot to replace the plus.
    public let isNotInLibrary: Bool
    private let availability: MediaAvailabilityStatus?

    public init(_ item: MediaItem) {
        kind = item.kind
        isPlayed = item.isPlayed
        playedPercentage = item.playedPercentage ?? item.resumeProgressFraction
        unwatchedEpisodeCount = item.unwatchedEpisodeCount
        resumePosition = item.resumePosition
        // Same shared classifier the corner mark and the detail page use, so a card
        // and its page can't disagree. Cards judge the item alone (no index work in
        // a card path), which is exactly `identitySources: []`.
        isNotInLibrary = TitleClassifier.isNotOwnedForBadge(item)
        availability = item.availability
    }

    public func episodeCountAccessibilityLabel(enabled: Bool, hidesStatus: Bool) -> LocalizedStringResource? {
        guard let count = MediaPlaybackIndicatorPresentation.episodeCount(
            for: self, enabled: enabled, hidesStatus: hidesStatus
        ) else { return nil }
        return LocalizedStringResource("Unwatched episodes: \(count)")
    }

    /// The corner mark this card should wear, if any. Shares
    /// ``MediaLibraryMark/mark(for:seerConnected:)`` without needing the full item.
    func libraryMark(seerConnected: Bool) -> MediaLibraryMark? {
        MediaLibraryMark.mark(
            isNotInLibrary: isNotInLibrary,
            availability: availability,
            seerConnected: seerConnected
        )
    }
}

enum MediaPlaybackIndicatorPresentation {
    enum Status: Equatable {
        case library(MediaLibraryMark), episodeCount(Int), watched, unwatched
    }

    static func status(
        for item: MediaPlaybackIndicatorState, hidesStatus: Bool, indicator: WatchStatusIndicator,
        showsEpisodeCount: Bool, seerConnected: Bool
    ) -> Status? {
        guard !hidesStatus, PosterCardPresentation.showsWatchStatus(for: item.kind) else { return nil }
        if let mark = item.libraryMark(seerConnected: seerConnected) { return .library(mark) }
        if let count = episodeCount(for: item, enabled: showsEpisodeCount, hidesStatus: hidesStatus) {
            return .episodeCount(count)
        }
        switch indicator {
        case .watched:
            return showsWatchedBadge(for: item, hidesStatus: hidesStatus) ? .watched : nil
        case .unwatched:
            return showsUnwatchedFlag(for: item, hidesStatus: hidesStatus) ? .unwatched : nil
        }
    }

    static func episodeCount(
        for item: MediaPlaybackIndicatorState, enabled: Bool, hidesStatus: Bool
    ) -> Int? {
        guard enabled, !hidesStatus, !item.isNotInLibrary,
              item.kind == .series || item.kind == .season,
              let count = item.unwatchedEpisodeCount, count > 0 else { return nil }
        return count
    }

    /// Whether this card should wear a progress bar.
    ///
    /// A saved resume point is progress however small it looks as a fraction. The
    /// old test asked only whether the percentage cleared one percent, which on a
    /// feature-length film is the first minute — so starting something, or
    /// restarting something already seen, produced a card indistinguishable from an
    /// untouched one, while the server's own app showed a bar. The place the viewer
    /// left off is the single most useful thing a card can say, and it does not
    /// become less true for being early.
    ///
    /// The upper bound stays: something watched through has no resume point of its
    /// own and reports a full percentage, and it should wear the watched mark
    /// rather than a bar pinned at the end.
    static func showsProgress(for item: MediaPlaybackIndicatorState) -> Bool {
        guard PosterCardPresentation.showsPlaybackIndicators(for: item.kind),
              let percentage = item.playedPercentage,
              percentage < 0.99
        else { return false }
        if let resume = item.resumePosition, resume > 0 { return true }
        // No resume point: a container reporting the fraction of its episodes
        // watched. Keep a floor there, since zero progress is not progress.
        return percentage > 0.01
    }

    static func hasStartedPlayback(_ item: MediaPlaybackIndicatorState) -> Bool {
        if let percentage = item.playedPercentage, percentage > 0 { return true }
        if let resume = item.resumePosition, resume > 0 { return true }
        return false
    }

    static func showsWatchedBadge(
        for item: MediaPlaybackIndicatorState,
        hidesStatus: Bool
    ) -> Bool {
        item.isPlayed && !showsProgress(for: item) && !hidesStatus
    }

    static func showsUnwatchedFlag(
        for item: MediaPlaybackIndicatorState,
        hidesStatus: Bool
    ) -> Bool {
        let hasNoUnwatchedEpisodes = (item.kind == .series || item.kind == .season)
            && item.unwatchedEpisodeCount == 0
        return !item.isPlayed && !hasStartedPlayback(item) && !hidesStatus && !hasNoUnwatchedEpisodes
    }
}
#endif
