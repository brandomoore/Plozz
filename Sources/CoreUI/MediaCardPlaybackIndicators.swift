#if canImport(SwiftUI)
import CoreModels
import SwiftUI

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

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.plozzShowsUnwatchedEpisodeCount) private var showsUnwatchedEpisodeCount
    /// Whether an unowned title can be requested, or is merely flagged as absent.
    @Environment(\.plozzSeerConnected) private var seerConnected
    /// Published by the hosting card so this chrome can settle back at rest and
    /// come to full strength on focus (tvOS only — see ``PlozzMediaChrome``).
    @Environment(\.plozzChromeIsFocused) private var isFocused

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
        self.playback = MediaPlaybackIndicatorState(item)
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
                if hasTopChrome || hasBottomChrome {
                    MediaArtworkChromeScrim(top: hasTopChrome, bottom: hasBottomChrome)
                }
            }
            .overlay(alignment: .topTrailing) {
                statusIndicator
            }
            .overlay(alignment: .bottom) {
                if progressBarEnabled {
                    progressBar
                }
            }
            .overlay(alignment: .bottomTrailing) {
                downloadBadge
            }
            .allowsHitTesting(false)
    }

    private var showsProgressBar: Bool {
        MediaPlaybackIndicatorPresentation.showsProgress(for: playback)
    }

    /// Any chrome along the card's bottom edge that needs the artwork darkened
    /// behind it — the progress bar, the download badge, or both.
    private var hasBottomChrome: Bool {
        (progressBarEnabled && showsProgressBar) || downloadState != nil
    }

    /// Only the library mark needs the TOP of the artwork darkened. The watched
    /// badge and the unwatched flag are pearl-white shapes that carry their
    /// own contrast; the library mark is a bare glyph and the scrim is the entire
    /// reason it stays legible over pale artwork.
    private var hasTopChrome: Bool {
        libraryMark != nil
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // A title that isn't in the library takes this slot INSTEAD of watch
        // state, not alongside it. Watch state cannot apply to something you
        // don't have — you have neither watched it nor left it unwatched — so
        // the unwatched flag on an external credit was never information, and
        // the two never compete for the corner.
        if let libraryMark {
            MediaLibraryMarkView(mark: libraryMark, size: metrics.watchedBadgeSize)
                .padding(floatingBadgeInset)
        } else if let count = MediaPlaybackIndicatorPresentation.episodeCount(
            for: playback, enabled: showsUnwatchedEpisodeCount, hidesStatus: hidesStatus
        ) {
            episodeCountBadge(count)
        } else if PosterCardPresentation.showsWatchStatus(for: playback.kind) {
            switch watchStatusIndicator {
            case .watched:
                watchedBadge
            case .unwatched:
                unwatchedCorner
            }
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

    /// The absent, requestable, or requested mark for this card, if it needs one.
    /// Suppressed while the artwork is spoiler-hidden, for the same reason watch
    /// state is: chrome on a masked poster gives away what the mask is hiding.
    private var libraryMark: MediaLibraryMark? {
        guard !hidesStatus else { return nil }
        return playback.libraryMark(seerConnected: seerConnected)
    }

    @ViewBuilder
    private var watchedBadge: some View {
        if MediaPlaybackIndicatorPresentation.showsWatchedBadge(
            for: playback,
            hidesStatus: hidesStatus
        ) {
            MediaWatchedBadge(size: metrics.watchedBadgeSize)
                .padding(floatingBadgeInset)
        }
    }

    @ViewBuilder
    private var unwatchedCorner: some View {
        if MediaPlaybackIndicatorPresentation.showsUnwatchedFlag(
            for: playback,
            hidesStatus: hidesStatus
        ) {
            MediaUnwatchedCorner(size: metrics.unwatchedFlagSize)
        }
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

enum MediaWatchIndicatorStyle {
    static let fill = Color.white.opacity(0.88)
    static let foreground = Color(white: 0.13)

    static func floatingInset(for size: CGFloat) -> CGFloat {
        16 * size / PlozzTheme.Metrics.watchedBadgeSize
    }
}

struct MediaWatchedBadge: View {
    let size: CGFloat
    private var scale: CGFloat { size / PlozzTheme.Metrics.watchedBadgeSize }

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.53, weight: .bold))
            .foregroundStyle(MediaWatchIndicatorStyle.foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(MediaWatchIndicatorStyle.fill))
            .overlay(Circle().stroke(.white.opacity(0.32), lineWidth: scale))
            .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: scale)
    }
}

struct MediaUnwatchedCorner: View {
    let size: CGFloat
    private var scale: CGFloat { size / PlozzTheme.Metrics.unwatchedFlagSize }

    var body: some View {
        TopTrailingCornerFlag()
            .fill(MediaWatchIndicatorStyle.fill)
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
    private var scale: CGFloat { size / PlozzTheme.Metrics.watchedBadgeSize }

    private var digits: some View {
        Text(count, format: .number.grouping(.never))
            .font(.system(size: 24 * scale, weight: .bold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(MediaWatchIndicatorStyle.foreground)
    }

    @ViewBuilder var body: some View {
        switch indicator {
        case .watched:
            digits
                .padding(.horizontal, 12 * scale)
                .frame(minWidth: size, minHeight: size)
                .background(RoundedRectangle(cornerRadius: 11 * scale).fill(MediaWatchIndicatorStyle.fill))
                .overlay {
                    RoundedRectangle(cornerRadius: 11 * scale)
                        .stroke(.white.opacity(0.32), lineWidth: scale)
                }
                .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: scale)
        case .unwatched:
            let height = 56 * scale
            let width = max(48, 24 + CGFloat(String(count).count) * 16) * scale
            let radius = min(cornerRadius, height / 2)
            digits
                .padding(.horizontal, 12 * scale)
                .frame(maxWidth: width, minHeight: height, maxHeight: height)
                // The artwork owns clipping; a tile-sized clip cuts this shadow into a square.
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: radius,
                        bottomTrailingRadius: 0, topTrailingRadius: radius, style: .circular
                    )
                    .fill(MediaWatchIndicatorStyle.fill)
                    .shadow(color: .black.opacity(0.28), radius: 8 * scale)
                    .overlay {
                        TopTrailingCurvedCornerEdge(radius: radius)
                            .stroke(.black.opacity(0.3), lineWidth: scale)
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
        playedPercentage = item.playedPercentage
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
        !item.isPlayed && !hasStartedPlayback(item) && !hidesStatus
    }
}
#endif
