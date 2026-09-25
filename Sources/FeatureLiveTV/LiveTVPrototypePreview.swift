import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypePreviewLayout {
    let bounds: CGRect
    let contentFrame: CGRect
    let heroHeight: CGFloat
    let videoFrame: CGRect
    let fadeEnd: CGFloat
    let metadataWidth: CGFloat
    let compact: Bool
    /// A phone on its side: wide enough for the TV's side-by-side info bar,
    /// but with so little height that the bar has to be one short strip and
    /// the gaps tighten, or the guide below it shows barely a row.
    let short: Bool
    /// How far the phone's guide reaches past the content margins on each
    /// side, halving the dead space beside the logos and the trailing fade.
    /// Nothing where the edge is a notch or rounded-corner inset.
    let guideSideBleed: CGFloat

    /// The gap between the info bar, the toolbar and the guide.
    var sectionGap: CGFloat { short ? PrototypeLayout.smallGap : PrototypeLayout.sectionGap }

    var heroArtworkSize: CGSize {
        let height = min(heroHeight - PrototypeLayout.smallGap, compact ? 92 : 220)
        return CGSize(width: (height * 16 / 9).rounded(), height: height.rounded())
    }

    var sidebarWidth: CGFloat {
        guard contentFrame.width >= 960,
              contentFrame.height - heroHeight - PrototypeLayout.sectionGap >= 420 else { return 0 }
        return contentFrame.width >= 1_400 ? 272 : 224
    }

    var guideWidth: CGFloat {
        contentFrame.width - (sidebarWidth > 0 ? sidebarWidth + PrototypeLayout.sectionGap : 0)
    }

    var guideBottomExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxY - contentFrame.maxY)
        #else
        0
        #endif
    }

    var guideTrailingExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxX - contentFrame.maxX)
        #else
        guideSideBleed
        #endif
    }

    var guideLeadingExtension: CGFloat {
        #if os(tvOS)
        0
        #else
        guideSideBleed
        #endif
    }

    init(
        size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets(),
        navigationInset: CGFloat = 0, largeText: Bool = false, isSearching: Bool = false
    ) {
        bounds = CGRect(
            x: -safeAreaInsets.leading, y: -safeAreaInsets.top,
            width: size.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: size.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        compact = bounds.width < 650
        #if os(tvOS)
        let side: CGFloat = 32
        // The rail and guide share physical-screen coordinates. Title-safe insets
        // can change during mounting and must not move or resize the pinned guide.
        let leading = side + (navigationInset > 0 ? PrototypeLayout.inset : 0)
        let top = max(32, safeAreaInsets.top)
        let bottom: CGFloat = 20
        guideSideBleed = 0
        #else
        let side = max(16, max(safeAreaInsets.leading, safeAreaInsets.trailing))
        guideSideBleed = side == 16 && navigationInset == 0 ? 14 : 0
        let leading = side
        let top = max(12, safeAreaInsets.top)
        let bottom = max(12, safeAreaInsets.bottom)
        #endif
        contentFrame = CGRect(
            x: bounds.minX + leading + navigationInset, y: bounds.minY + top,
            width: max(1, bounds.width - leading - side - navigationInset),
            height: max(1, bounds.height - top - bottom)
        )
        #if os(tvOS)
        short = false
        #else
        short = !compact && !largeText && contentFrame.height < 500
        #endif
        let browsingHeroHeight = short ? 100 : min(
            contentFrame.height * (largeText ? 0.48 : 0.30),
            // Just the info bar: the art and its gap on a TV (no dead band above
            // it), and on a phone the art row plus three lines of text.
            // (184 on a phone is its bar's content exactly: art row, title,
            // timing and two lines of summary, with no dead band above.)
            largeText ? 440 : (compact ? 184 : 236)
        )
        heroHeight = isSearching
            ? min(browsingHeroHeight, largeText ? 230 : (compact ? 140 : 180))
            : browsingHeroHeight
        metadataWidth = compact || largeText ? contentFrame.width : contentFrame.width * 0.56
        let videoWidth = bounds.width
        let videoHeight = videoWidth * 9 / 16
        videoFrame = CGRect(
            x: bounds.maxX - videoWidth,
            y: bounds.minY,
            width: videoWidth, height: videoHeight
        )
        fadeEnd = min(bounds.height * 0.82, videoHeight * 0.88)
    }
}

struct PrototypeGuidePlacement<Content: View>: View {
    let frame: CGRect
    let canvasWidth: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(
                x: layoutDirection == .rightToLeft ? canvasWidth - frame.midX : frame.midX,
                y: frame.midY
            )
    }
}

/// The player stays mounted beneath this scrim; watching only removes the guide.
struct PrototypePreviewScrim: View {
    let layout: PrototypePreviewLayout
    let reduceTransparency: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            HeroLegibilityScrim(
                tone: palette.backgroundBase, edgePeak: 0.96, wash: 0.08,
                edges: [.leading], bottomFadeTop: 0.3
            )
            VStack(spacing: 0) {
                LinearGradient(
                    stops: (0 ... 24).map { step in
                        let t = Double(step) / 24
                        return .init(color: palette.backgroundBase.opacity(t * t * (3 - 2 * t)), location: t)
                    },
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: layout.fadeEnd)
                palette.backgroundBase
            }
            if reduceTransparency {
                palette.backgroundBase
                    .frame(width: layout.metadataWidth + 48, height: layout.heroHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, layout.contentFrame.minY - layout.bounds.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The guide's info bar: the programme's art (the channel's logo when the guide
/// has none) with the channel, title, a progress bar between the start and end
/// times, and "subtitle – description" beside it.
struct PrototypePreviewHero: View {
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let layout: PrototypePreviewLayout
    let watch: () -> Void
    var watchTitle: LocalizedStringResource?
    var isLoading = false
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if isLoading {
                PrototypePreviewHeroSkeleton(layout: layout)
            } else if let channel {
                if layout.compact {
                    compactBar(channel)
                } else if layout.short {
                    shortBar(channel)
                } else {
                    // Top-aligned in a box the art's height, so the art and the
                    // first line of text sit in the same place whatever the text
                    // or the image's own proportions turn out to be.
                    VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                        HStack(alignment: .top, spacing: PrototypeLayout.sectionGap) {
                            artwork(channel)
                            details(channel)
                                .frame(maxWidth: .infinity, maxHeight: artSize.height, alignment: .topLeading)
                                .clipped()
                        }
                        .frame(height: artSize.height, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(iOS)
                        watchButton
                        #endif
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: PrototypeLayout.rowGap) {
                    Text("Find your next channel")
                        .font(.title.weight(.semibold))
                    Text("Browse by channel, genre or what's on.")
                        .font(.subheadline).foregroundStyle(palette.secondaryText)
                }
                .frame(width: layout.metadataWidth, alignment: .leading)
            }
        }
        .frame(width: layout.contentFrame.width, height: layout.heroHeight, alignment: .bottomLeading)
        .clipped()
        #if DEBUG
        .anchorPreference(key: PrototypeHeroBoundsKey.self, value: .bounds) { [isLoading ? "loading" : "content": $0] }
        #endif
    }

    /// The TV's info bar squeezed into a phone's landscape strip: art, then
    /// the details, then Watch, all on one line so none of it needs a row of
    /// its own.
    private func shortBar(_ channel: LiveTVPrototypeChannel) -> some View {
        HStack(alignment: .center, spacing: PrototypeLayout.gap) {
            artwork(channel)
            details(channel)
                .frame(maxWidth: layout.metadataWidth, maxHeight: artSize.height, alignment: .leading)
                .clipped()
            #if os(iOS)
            watchButton
                .fixedSize()
            #endif
            Spacer(minLength: 0)
        }
        .frame(height: layout.heroHeight, alignment: .center)
    }

    private var artSize: CGSize {
        layout.heroArtworkSize
    }

    private var watchButton: some View {
        Button(action: watch) {
            Label {
                Text(watchTitle ?? "Watch channel")
            } icon: {
                Image(systemName: watchTitle == nil ? "play.fill" : "rectangle.split.2x2")
            }
        }
        .font(.subheadline.weight(.semibold))
        .plozzGlassPillButton()
        .accessibilityIdentifier("live-tv-info-watch")
    }

    /// The phone's info bar, top to bottom: the art beside its channel and the
    /// Watch button, then the title, the progress bar between its times, and
    /// "subtitle – description". Every line keeps its place whether or not the
    /// guide has it, so tapping from programme to programme never reflows.
    private func compactBar(_ channel: LiveTVPrototypeChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: PrototypeLayout.gap) {
                artwork(channel)
                VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                    Text(channel.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                    watchButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(program?.title ?? channel.name)
                .font(.headline)
                .lineLimit(1)
            Group {
                if let program {
                    timing(program)
                } else {
                    Text(channel.category).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            Text(program?.playerInfo.summary ?? " ")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A fixed 16:9 plate with the art fitted inside it, never cropped or
    /// resized to the image: a poster and a wide still occupy the same box.
    private func artwork(_ channel: LiveTVPrototypeChannel) -> some View {
        let size = artSize
        return ZStack {
            palette.primaryText.opacity(0.06)
            if let url = program?.details?.artworkURL {
                FallbackAsyncImage(references: [.remote(url)]) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    logo(channel, size: size)
                }
            } else {
                logo(channel, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PrototypeLayout.logoRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func logo(_ channel: LiveTVPrototypeChannel, size: CGSize) -> some View {
        PrototypeStationMark(channel: channel, plateSize: size)
    }

    private func details(_ channel: LiveTVPrototypeChannel) -> some View {
        VStack(alignment: .leading, spacing: layout.compact ? 2 : PrototypeLayout.smallGap) {
            Text(program == nil ? channel.category : channel.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            Text(program?.title ?? channel.name)
                .font((layout.compact ? Font.headline : Font.title3).weight(.semibold))
                .lineLimit(1)
            if let program {
                timing(program)
                if let summary = program.playerInfo.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(layout.compact || layout.short ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Start time, how far through the programme we are, end time.
    private func timing(_ program: LiveTVPrototypeProgram) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: PrototypeLayout.gap) {
                Text(verbatim: program.start.formatted(.dateTime.hour().minute().locale(locale)))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.secondaryText.opacity(0.35))
                        Capsule().fill(palette.primaryText)
                            .frame(width: geometry.size.width * program.progress(at: context.date))
                    }
                }
                .frame(maxWidth: layout.compact ? .infinity : 220)
                .frame(height: 6)
                Text(verbatim: program.end.formatted(.dateTime.hour().minute().locale(locale)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(program.start.formatted(.dateTime.hour().minute().locale(locale))) – \(program.end.formatted(.dateTime.hour().minute().locale(locale)))"))
        }
    }
}

struct PrototypeSearchSummary: View {
    let channelCount: Int
    let category: String?
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: PrototypeLayout.smallGap) {
            Text("\(channelCount) channels")
            if let category {
                Text("in \(category)", comment: "Search summary: channels in the named category or genre. %@ is a category, not a time duration.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
}
