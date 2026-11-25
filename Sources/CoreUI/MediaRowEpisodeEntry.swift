import CoreModels
import SwiftUI

/// Opt-in episode-row entry. Ordinary Home and library rows keep native focus.
public struct MediaRowEpisodeEntry {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case empty
        case failed
    }

    public let phase: Phase
    public let isActive: Bool
    public let isEnabled: Bool
    public let onPlaceholderFocus: (@MainActor () -> Void)?
    public let onRetry: (@MainActor () -> Void)?

    public init(
        phase: Phase,
        isActive: Bool,
        isEnabled: Bool = true,
        onPlaceholderFocus: (@MainActor () -> Void)? = nil,
        onRetry: (@MainActor () -> Void)? = nil
    ) {
        self.phase = phase
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.onPlaceholderFocus = onPlaceholderFocus
        self.onRetry = onRetry
    }
}

struct MediaRowEntryLayout: Equatable {
    struct Target: Equatable {
        let id: String
        let frame: CGRect
    }
    var target: Target?
    var viewportWidth: CGFloat?
}

struct MediaRowEntryLayoutKey: PreferenceKey {
    static let defaultValue = MediaRowEntryLayout()
    static func reduce(value: inout MediaRowEntryLayout, nextValue: () -> MediaRowEntryLayout) {
        let next = nextValue()
        if let target = next.target { value.target = target }
        if let width = next.viewportWidth { value.viewportWidth = width }
    }
}

enum MediaRowEpisodeEntryPolicy {
    static func targetReady(_ targetID: String?, layout: MediaRowEntryLayout) -> Bool {
        guard let targetID, let target = layout.target, target.id == targetID,
              let width = layout.viewportWidth, width > 0,
              !target.frame.isEmpty, !target.frame.isNull, !target.frame.isInfinite else { return false }
        return target.frame.minX >= -1 && target.frame.maxX <= width + 1
    }

    static func showsPlaceholder(
        phase: MediaRowEpisodeEntry.Phase, targetReady: Bool, focusEngaged: Bool,
        hasBrowsedTarget: Bool = false
    ) -> Bool {
        phase != .ready || (!focusEngaged && !targetReady && !hasBrowsedTarget)
    }

    static func target(
        rememberedID: String?, defaultID: String?, itemIDs: Set<String>, firstID: String?
    ) -> String? {
        if let rememberedID, itemIDs.contains(rememberedID) { return rememberedID }
        if let defaultID { return itemIDs.contains(defaultID) ? defaultID : nil }
        return firstID
    }
}

extension EnvironmentValues {
    @Entry var episodeColumnArtworkSize: CGSize = EpisodeColumnCard.artworkSize
}

struct EpisodeRowEntryPlaceholder: View {
    var phase: MediaRowEpisodeEntry.Phase = .loading
    var showsStatus = false
    var isFocused = false
    var nativeFocus: PlozzCardFocus.Binding?
    var onSelect: () -> Void = {}
    @Environment(\.episodeColumnArtworkSize) private var artworkSize
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.plozzCardCaptionsHidden) private var captionsHidden
    @Environment(\.detailHeaderSettings) private var detailSettings
    @Environment(\.plozzAppTextScale) private var appTextScale
    private let metrics = PlozzMetrics.standard
    private var textScale: CGFloat {
        #if os(tvOS)
        PlozzTypography.scale(local: detailSettings?.settings.textSize.scale ?? 1, app: appTextScale)
        #else
        1
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artwork
            if showsStatus || !captionsHidden {
                VStack(alignment: .leading, spacing: 10 * textScale) {
                    Group {
                        if showsStatus {
                            switch phase {
                            case .loading, .ready:
                                Label("Loading episodes", systemImage: "hourglass")
                            case .empty:
                                Text("No episodes available")
                            case .failed:
                                Text("Unable to load episodes")
                            }
                        } else {
                            Capsule().fill(palette.fill).frame(width: 0.52 * artworkSize.width, height: 20 * textScale)
                        }
                    }
                    .font(.system(size: PlozzTypography.episodeTitle.scaled(by: textScale).pointSize, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .frame(height: PlozzTypography.episodeTitle.scaled(by: textScale).pointSize * 1.25, alignment: .leading)
                    Capsule().fill(palette.fill).frame(width: 0.92 * artworkSize.width, height: 15 * textScale)
                    Capsule().fill(palette.fill).frame(width: 0.81 * artworkSize.width, height: 15 * textScale)
                    Group {
                        if showsStatus && phase == .failed {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.system(size: PlozzTypography.episodeDescription.scaled(by: textScale).pointSize))
                                .foregroundStyle(palette.secondaryText)
                        } else {
                            Capsule().fill(palette.fill).frame(width: 0.65 * artworkSize.width, height: 15 * textScale)
                        }
                    }
                    .frame(height: 24 * textScale, alignment: .leading)
                }
                .padding(.top, metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush)
                .offset(y: reduceMotion || isFocused ? 0 : -metrics.focusCaptionPush)
                .animation(
                    reduceMotion ? nil : PlozzTheme.Metrics.cardFocusAnimation(
                        isFocused: isFocused, focusStyle: focusStyle, reduceMotion: reduceMotion
                    ),
                    value: isFocused
                )
            }
        }
        .frame(width: artworkSize.width, alignment: .leading)
        .padding(.trailing, EpisodeColumnCard.trailingSpacing)
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused, animates: !reduceMotion)
    }

    @ViewBuilder
    private var artwork: some View {
        #if os(tvOS)
        if focusStyle.usesSystemEffect, let nativeFocus {
            NativeTVPoster(
                image: nil, treatment: .original,
                aspectRatio: artworkSize.width / artworkSize.height,
                fallbackWidth: artworkSize.width,
                title: nil, subtitle: nil, overlay: EmptyView(), focus: nativeFocus, action: onSelect
            )
            .focused(nativeFocus.focusState)
            .frame(width: artworkSize.width, height: artworkSize.height)
        } else {
            customArtwork
        }
        #else
        customArtwork
        #endif
    }

    private var customArtwork: some View {
        RoundedRectangle(cornerRadius: metrics.landscapeCardCornerRadius)
            .fill(palette.cardOpaqueSurface)
            .frame(width: artworkSize.width, height: artworkSize.height)
            .plozzMediaEdge(cornerRadius: metrics.landscapeCardCornerRadius)
            .plozzFocusHalo(
                cornerRadius: metrics.landscapeCardCornerRadius,
                focusScale: reduceMotion ? 1 : PlozzTheme.Metrics.mediumFocusedCardScale,
                isFocused: isFocused
            )
    }
}
