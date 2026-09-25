import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

enum PrototypeLayout {
    static let gap = PlozzTheme.Spacing.medium
    static let smallGap = PlozzTheme.Spacing.xSmall
    static let radius = PlozzTheme.Metrics.cornerRadius
    static let sectionGap = PlozzTheme.Spacing.large
    static let cellGap = PlozzTheme.Spacing.xSmall
    // On touch the grid is one even mesh: rows, the logo column and programmes
    // all sit a programme-gap apart. The TV keeps wider row and column gaps.
    #if os(iOS)
    static let rowGap = cellGap
    static let columnGap = cellGap
    #else
    static let rowGap = PlozzTheme.Spacing.medium
    static let columnGap = PlozzTheme.Spacing.small
    #endif
    static let rowInset = PlozzTheme.Spacing.medium
    static let logoRadius = PlozzTheme.Metrics.Radius.content
    /// Concentric with the logo plate on a TV and a tablet. A phone's short
    /// rows (`compactRowHeight`) turned that radius into a full capsule, so
    /// its cells get the TV's proportion instead: squarer, like the tvOS grid.
    static var rowRadius: CGFloat {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 14 : logoRadius + rowInset
        #else
        logoRadius + rowInset
        #endif
    }
    static let programInset: CGFloat = 0
    static var programRadius: CGFloat { rowRadius - programInset }
    static let horizontalFade = PlozzTheme.Spacing.large
    static let verticalFade = PlozzTheme.Spacing.xLarge
    static let minimumGuideOpacity = 0.05
    static let guideInset = PlozzTheme.Metrics.Radius.inset
    static let stationArtworkInset = guideInset + 8
    static var guideTrailingInset: CGFloat {
        #if os(tvOS)
        0
        #else
        guideInset
        #endif
    }
    static var guideRadius: CGFloat { rowRadius + guideInset }
    static let controlRadius = PlozzTheme.Metrics.Radius.control
    static let controlInset = PlozzTheme.Spacing.xSmall
    static let controlGroupRadius = controlRadius + controlInset
    #if os(tvOS)
    static let inset = PlozzTheme.Spacing.xLarge
    static let stationSize: CGFloat = 96
    static let controlHeight: CGFloat = 56
    static let guideFontSize: CGFloat = 26
    static let sectionFontSize: CGFloat = 22
    #else
    static let inset = PlozzTheme.Spacing.medium
    static let stationSize: CGFloat = 80
    static let controlHeight: CGFloat = 44
    static let guideFontSize: CGFloat = 16
    static let sectionFontSize: CGFloat = 14
    #endif
    static let rowHeight = stationSize + rowInset * 2
    static let stationColumnWidth = stationSize * 1.75 + rowInset * 2
    static var guideShape: UnevenRoundedRectangle {
        #if os(tvOS)
        let bottom: CGFloat = 0
        let trailing: CGFloat = 0
        #else
        // Square along the bottom: the list fades out toward the tab bar
        // (see the guide's scroll fade) rather than being cut by a curve.
        let bottom: CGFloat = 0
        let trailing = guideRadius
        #endif
        return UnevenRoundedRectangle(
            topLeadingRadius: guideRadius, bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom, topTrailingRadius: trailing
        )
    }

    /// Below this the guide is a phone's: a narrow channel column, shorter rows
    /// and one hour of programmes across the screen.
    static let compactWidth: CGFloat = 650

    // The guide's own vertical rhythm on touch is a step tighter than the
    // TV's: section labels and the time ruler read at arm's length, and every
    // point they give back is guide.
    #if os(iOS)
    static let sectionLabelHeight: CGFloat = 22
    static let rulerHeight: CGFloat = 28
    static let sectionLabelGap: CGFloat = 2
    static let toolbarGuideGap: CGFloat = 4
    static let rulerGap: CGFloat = 4
    #else
    static let sectionLabelHeight: CGFloat = 44
    static let rulerHeight: CGFloat = 44
    static let sectionLabelGap: CGFloat = rowGap
    static let toolbarGuideGap: CGFloat = sectionGap
    static let rulerGap: CGFloat = gap
    #endif
    static let compactStationWidth: CGFloat = 88
    static let compactRowHeight: CGFloat = 64

    static func isCompact(_ width: CGFloat) -> Bool { width < compactWidth }

    /// A phone keeps its short rows and narrow channel column on its side too:
    /// landscape has no more height than portrait has width, so full-size rows
    /// left room for barely one. The extra width goes to programme time
    /// instead (`viewportSeconds` stays width-based).
    static func usesCompactRows(_ width: CGFloat) -> Bool {
        #if os(iOS)
        isCompact(width) || UIDevice.current.userInterfaceIdiom == .phone
        #else
        isCompact(width)
        #endif
    }

    static func stationWidth(for width: CGFloat) -> CGFloat {
        usesCompactRows(width) ? compactStationWidth : stationColumnWidth
    }

    static func timelineWidth(for width: CGFloat) -> CGFloat {
        max(1, width - stationWidth(for: width) - columnGap)
    }

    /// How much programme time the visible timeline spans: two half-hour slots
    /// on a phone, four elsewhere.
    static func viewportSeconds(for width: CGFloat) -> TimeInterval {
        isCompact(width) ? 3_600 : 7_200
    }

    /// The scrollable guide holds six hours whatever the viewport.
    static let timelineSpanSeconds: TimeInterval = 21_600

    /// Horizontal distance for a stretch of programme time.
    static func timelineX(_ seconds: TimeInterval, for width: CGFloat) -> CGFloat {
        timelineWidth(for: width) * seconds / viewportSeconds(for: width)
    }

    static func timelineContentWidth(for width: CGFloat) -> CGFloat {
        timelineX(timelineSpanSeconds, for: width)
    }

    static func maximumTimelineOffset(for width: CGFloat) -> CGFloat {
        max(0, timelineContentWidth(for: width) - timelineWidth(for: width))
    }

    static func programHeight(in rowHeight: CGFloat) -> CGFloat {
        max(1, rowHeight - programInset * 2)
    }
}

extension LiveTVGuideSection {
    var title: LocalizedStringResource {
        switch self {
        case .recent: "Recently watched"
        case .favorites: "Favorites"
        case .channels: "Channels"
        }
    }
}

struct PrototypeScrollFade: Equatable {
    let leading: CGFloat
    let trailing: CGFloat

    init(before: CGFloat = 0, after: CGFloat = 0, distance: CGFloat = PrototypeLayout.verticalFade) {
        leading = min(1, max(0, before) / max(1, distance))
        trailing = min(1, max(0, after) / max(1, distance))
    }
}

extension LiveTVPrototypeSource {
    var title: Text {
        switch self {
        case .iptv: Text(verbatim: "IPTV")
        case .jellyfin: Text(verbatim: "Jellyfin")
        case .plex: Text(verbatim: "Plex")
        case .emby: Text(verbatim: "Emby")
        case .plozz: Text("Plozz channels")
        }
    }
}

extension LiveTVPrototypeScenario {
    var title: LocalizedStringResource {
        switch self {
        case .noGuide: "No guide"
        case .mixedGuide: "Partial guide"
        case .fullGuide: "Full guide"
        case .staleGuide: "Stale guide"
        case .failedGuide: "Guide unavailable"
        }
    }
}

extension LiveTVPrototypeSort {
    var title: LocalizedStringResource {
        switch self {
        case .channelNumber: "Channel number"
        case .name: "Name"
        }
    }
}

struct PrototypeStationMark: View {
    let channel: LiveTVPrototypeChannel
    var size: CGFloat = PrototypeLayout.stationSize
    var plateSize: CGSize? = nil
    var cornerRadius: CGFloat = PrototypeLayout.logoRadius

    private var dimensions: CGSize {
        plateSize ?? CGSize(width: size * 1.75, height: size)
    }

    private var artworkInset: CGFloat {
        plateSize == nil ? 6 : PrototypeLayout.stationArtworkInset
    }

    var body: some View {
        ChannelLogoArtwork(
            name: channel.name, logoURL: channel.logoURL, size: dimensions,
            cornerRadius: cornerRadius, artworkInset: artworkInset,
            plozzChannelID: channel.source == .plozz ? channel.id : nil
        )
    }
}

struct PrototypeFocusOutline: View {
    let cornerRadius: CGFloat
    var color: Color = .white
    var lineWidth: CGFloat = 3.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A dark inner keyline keeps the white focus edge visible on pale logos.
        shape.strokeBorder(.black.opacity(0.9), lineWidth: lineWidth * 2)
            .overlay { shape.strokeBorder(color, lineWidth: lineWidth) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct PrototypeButtonStyle: ButtonStyle {
    var selected = false
    var padded = true
    var surface: PrototypeButtonSurface = .standard
    var focusChanged: ((Bool) -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        PrototypeButtonBody(
            configuration: configuration, selected: selected, padded: padded,
            surface: surface, focusChanged: focusChanged
        )
    }
}

enum PrototypeButtonSurface: Equatable {
    case standard, guide, station, program, control
}

private struct PrototypeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let padded: Bool
    let surface: PrototypeButtonSurface
    let focusChanged: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var solidFocus: Bool {
        focused && surface != .station
            && ((surface != .guide && surface != .program) || reduceTransparency || contrast == .increased)
    }

    private var cornerRadius: CGFloat {
        switch surface {
        case .standard: PrototypeLayout.radius
        case .guide, .station: PrototypeLayout.rowRadius
        case .program: PrototypeLayout.programRadius
        case .control: PrototypeLayout.controlRadius
        }
    }

    private var fill: Color {
        if solidFocus { return palette.accent }
        if focused || selected { return palette.fill }
        switch surface {
        case .standard: return palette.cardSurface
        case .guide, .station: return .clear
        case .program:
            return palette.fillSubtle.opacity(reduceTransparency || contrast == .increased ? 1 : 0.45)
        case .control: return .clear
        }
    }

    /// A tapped guide cell wears the focus outline, since touch has no focus
    /// of its own to show which programme the info bar is describing.
    private var showsTouchSelection: Bool {
        #if os(iOS)
        selected && (surface == .program || surface == .guide)
        #else
        false
        #endif
    }

    var body: some View {
        configuration.label
            .foregroundStyle(solidFocus ? palette.onAccent : palette.primaryText)
            .padding(padded ? PrototypeLayout.gap : 0)
            .background(
                fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if (focused || showsTouchSelection) && !solidFocus {
                    PrototypeFocusOutline(
                        cornerRadius: cornerRadius,
                        color: surface == .station ? .white : palette.primaryText,
                        lineWidth: contrast == .increased ? 4 : 3.5
                    )
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(selected && !focused ? palette.accent.opacity(0.35) : .clear, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            // Directional entry gates remove candidates without dimming the rail.
            .transaction { $0.animation = nil }
            .onChange(of: focused, initial: true) { _, value in
                #if os(iOS)
                // Touch has no focus to lose: a tapped selection stands until
                // another tap replaces it, even as its row scrolls away and back.
                if value { focusChanged?(value) }
                #else
                focusChanged?(value)
                #endif
            }
    }
}

struct PrototypeGuideSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.themePalette) private var palette

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                Color.clear.plozzSurface(.raised, cornerRadius: 0)
                    .clipShape(PrototypeLayout.guideShape)
            } else {
                PrototypeLayout.guideShape
                    .fill(LinearGradient(
                        stops: [
                            .init(color: palette.backgroundBase.opacity(PrototypeLayout.minimumGuideOpacity), location: 0),
                            .init(color: palette.backgroundBase.opacity(0.12), location: 0.2),
                            .init(color: palette.backgroundBase.opacity(0.4), location: 0.55),
                            .init(color: palette.backgroundBase.opacity(0.75), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One glass underlay, not a glass layer per programme or a focus-dependent style.
struct PrototypeControlSurface: View {
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzReducePanelGlass) private var reduceGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrototypeLayout.controlGroupRadius, style: .continuous)
        Group {
            if reduceTransparency {
                Color.clear.plozzSurface(.raised, cornerRadius: PrototypeLayout.controlGroupRadius)
            } else if reduceGlass {
                Color.clear.plozzFrostedBackground(shape).plozzFrostedBorder(shape)
            } else {
                Color.clear.plozzGlassPanel(cornerRadius: PrototypeLayout.controlGroupRadius)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum PrototypeSheet: Identifiable {
    case filters, sources, guideTime, addPlaylist, serverSetup, multiviewFavorites
    case program(LiveTVPrototypeProgram)

    var id: String {
        switch self {
        case .filters: "filters"
        case .sources: "sources"
        case .addPlaylist: "add-playlist"
        case .serverSetup: "server-setup"
        case .guideTime: "guide-time"
        case .multiviewFavorites: "multiview-favorites"
        case .program(let program): program.id
        }
    }
}
