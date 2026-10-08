#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ViewCustomizationHelp {
    let detail: LocalizedStringResource
    let illustration: Illustration
    var continueWatchingShowsSeriesArtwork = true

    enum Illustration: Hashable {
        case artwork(ArtworkArea)
        case captions(style: CardStyle, showsCaptions: Bool, showsMixedCaptions: Bool)
    }
}

struct ViewCustomizationHelpCard: View {
    let help: ViewCustomizationHelp
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(HeroSettingsModel.self) private var hero: HeroSettingsModel?
    @ScaledMetric(relativeTo: .body) private var contentHeight: CGFloat = 176

    var body: some View {
        HStack(spacing: 28) {
            illustration
                .accessibilityHidden(true)
            Text(help.detail)
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(help.illustration)
        .transition(.opacity)
        .frame(height: contentHeight)
        .padding(24)
        .settingsGroupSurface(cornerRadius: PlozzTheme.Metrics.Radius.content)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: help.illustration)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(help.detail))
        .accessibilityIdentifier("view-customization-help")
    }

    @ViewBuilder
    private var illustration: some View {
        switch help.illustration {
        case .artwork(.details):
            HStack(spacing: 16) {
                detailPreview(.movie, title: "Movies")
                detailPreview(.series, title: "TV shows")
            }
        case .artwork(let area):
            ArtworkScopeDiagram(
                area: area, heroSettings: hero?.settings ?? .default,
                continueWatchingShowsSeriesArtwork: help.continueWatchingShowsSeriesArtwork
            )
                .frame(width: 256, height: 144)
        case .captions(let style, let showsCaptions, let showsMixedCaptions):
            CardStyleSwatch(
                style: style, cornerRadius: 10,
                showsCaptions: showsCaptions, showsMixedCaptions: showsMixedCaptions
            )
            .frame(width: 256, height: 144)
        }
    }

    private func detailPreview(
        _ kind: ArtworkScopeDiagram.DetailKind, title: LocalizedStringResource
    ) -> some View {
        VStack(spacing: 8) {
            ArtworkScopeDiagram(area: .details, detailKind: kind)
                .frame(width: 256, height: 144)
            Text(title).font(.caption2).foregroundStyle(palette.secondaryText)
        }
    }
}

/// A location map, not a sample of the artwork a provider might return.
struct ArtworkScopeDiagram: View {
    let area: ArtworkArea
    var detailKind: DetailKind = .movie
    var heroSettings: HeroSettings = .default
    var continueWatchingShowsSeriesArtwork = true
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzNavigationStyle) private var navigationStyle
    @Environment(\.layoutDirection) private var layoutDirection

    enum DetailKind: CaseIterable {
        case movie, series
    }

    enum ArtworkKind: Hashable {
        case none, navigation, backdrop, logo, poster, thumbnail, seriesCard, episode, cover
    }

    static let screen = CGSize(width: 320, height: 180)

    struct Region: Equatable {
        let frame: CGRect
        var highlighted = false
        var kind: ArtworkKind = .none
        var artwork: Bool { kind != .none && kind != .navigation }

        init(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
             highlighted: Bool = false, kind: ArtworkKind = .none) {
            frame = CGRect(x: x, y: y, width: width, height: height)
            self.highlighted = highlighted
            self.kind = kind
        }
    }

    var body: some View {
        let regions = Self.regions(
            for: area, navigationStyle: navigationStyle, detailKind: detailKind,
            heroSettings: heroSettings, continueWatchingShowsSeriesArtwork: continueWatchingShowsSeriesArtwork
        )
        let screenBounds = CGRect(origin: .zero, size: Self.screen)
        Canvas { context, size in
            context.scaleBy(x: size.width / Self.screen.width, y: size.height / Self.screen.height)
            if layoutDirection == .rightToLeft {
                context.translateBy(x: Self.screen.width, y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            context.fill(Path(CGRect(origin: .zero, size: Self.screen)),
                         with: .color(palette.settingsBackground))
            for region in regions {
                let shape = Path(roundedRect: region.frame, cornerRadius: 3)
                context.fill(shape, with: .color(region.highlighted ? palette.accent.opacity(0.2) : palette.fill))
                if region.highlighted, region.frame != screenBounds {
                    context.stroke(shape, with: .color(palette.accent), lineWidth: 1.5)
                }
                if region.artwork, region.kind != .logo {
                    var image = context.resolve(Image(systemName: "photo"))
                    image.shading = .color(region.highlighted ? palette.accent : palette.tertiaryText)
                    let width = min(region.frame.width * 0.5, 32)
                    let height = min(region.frame.height * 0.5, width * 0.7)
                    let center = region.kind == .backdrop
                        ? CGPoint(x: region.frame.maxX - 28, y: region.frame.minY + 28)
                        : CGPoint(x: region.frame.midX, y: region.frame.midY)
                    context.draw(image, in: CGRect(
                        x: center.x - width / 2, y: center.y - height / 2,
                        width: width, height: height
                    ))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if regions.contains(where: { $0.highlighted && $0.frame == screenBounds }) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 1.5)
                    .padding(1)
            }
        }
    }

    static func regions(
        for area: ArtworkArea,
        navigationStyle: NavigationStyle = .default,
        detailKind: DetailKind = .movie,
        heroSettings: HeroSettings = .default,
        continueWatchingShowsSeriesArtwork: Bool = true
    ) -> [Region] {
        let libraryAreas: [ArtworkArea] = [.recommendedHero, .recommended, .browse, .collections, .playlists]
        let library = libraryAreas.contains(area)
        let leading: CGFloat = navigationStyle == .rail && area != .search ? 38 : 16
        let chrome: [Region]
        switch navigationStyle {
        case .rail where area == .search:
            chrome = [Region(12, 10, 14, 14, kind: .navigation)]
        case .rail:
            chrome = [Region(8, 14, 14, 14, kind: .navigation), Region(10, 44, 10, 5, kind: .navigation),
                      Region(10, 63, 10, 5, kind: .navigation), Region(10, 82, 10, 5, kind: .navigation),
                      Region(10, 158, 10, 8, kind: .navigation)]
        case .sidebar:
            chrome = [Region(12, 10, 14, 14, kind: .navigation)]
        case .tabBar where library:
            chrome = []
        case .tabBar:
            chrome = [Region(94, 8, 132, 12, kind: .navigation)]
        }

        func posters(y: CGFloat, highlighted: Bool) -> [Region] {
            (0..<6).map { column in
                Region(leading + CGFloat(column) * 44, y, 28, 42, highlighted: highlighted, kind: .poster)
            }
        }

        func thumbnails(y: CGFloat, highlighted: Bool, kind: ArtworkKind) -> [Region] {
            (0..<3).map { column in
                Region(leading + CGFloat(column) * 90, y, 80, 45, highlighted: highlighted, kind: kind)
            }
        }

        switch area {
        case .home, .recommendedHero, .homeRows, .recommended, .continueWatching:
            let highlightsHero = area == .home || area == .recommendedHero
            let showcase = library || heroSettings.followsFocus
            var result: [Region]
            if showcase {
                let top: CGFloat = navigationStyle == .tabBar && !library ? 38 : 30
                result = [
                    Region(112, top, 192, 108, highlighted: highlightsHero, kind: .backdrop),
                    Region(leading, top + 14, 80, 14, highlighted: highlightsHero, kind: .logo),
                    Region(leading, top + 42, 65, 5), Region(leading, top + 55, 80, 4)
                ] + chrome
            } else if heroSettings.isActive {
                let y: CGFloat = area == .home ? 108 : 50
                result = [
                    Region(0, 0, 320, 180, highlighted: highlightsHero, kind: .backdrop)
                ] + chrome + [
                    Region(leading, y, 124, 18, highlighted: highlightsHero, kind: .logo),
                    Region(leading, y + 28, 92, 5), Region(leading, y + 42, 42, 12)
                ]
                if area == .home { return result }
            } else {
                result = chrome + posters(y: 50, highlighted: area == .homeRows)
                if area != .continueWatching {
                    return result + posters(y: 120, highlighted: area == .homeRows)
                }
            }
            if area == .continueWatching {
                if continueWatchingShowsSeriesArtwork {
                    result += (0..<3).map {
                        Region(leading + CGFloat($0) * 90, 116, 80, 80 / ContinueWatchingCardShape.aspectRatio,
                               highlighted: true, kind: .seriesCard)
                    }
                } else {
                    result += thumbnails(y: 126, highlighted: true, kind: .thumbnail)
                }
                result += (0..<3).map { Region(leading + 5 + CGFloat($0) * 90, 164, 47, 3) }
            } else {
                result += posters(y: 126, highlighted: !highlightsHero)
            }
            return result
        case .browse, .collections, .playlists, .search, .watchlist:
            return chrome + [Region(leading, 36, area == .search ? 220 : 100, 8)]
                + posters(y: 60, highlighted: true) + posters(y: 120, highlighted: true)
        case .details, .episodes:
            let details = area == .details
            let background = Region(0, 0, 320, 180, highlighted: details, kind: .backdrop)
            if details && detailKind == .movie {
                return [
                    background, Region(16, 96, 132, 18, highlighted: true, kind: .logo),
                    Region(16, 122, 94, 5), Region(16, 136, 160, 4),
                    Region(16, 148, 146, 4), Region(16, 161, 40, 12), Region(64, 161, 40, 12)
                ]
            }
            return [
                background, Region(110, 12, 100, 30, highlighted: details, kind: .logo),
                Region(104, 48, 32, 8), Region(144, 48, 32, 8), Region(184, 48, 32, 8)
            ] + (0..<3).flatMap { column -> [Region] in
                let x = 16 + CGFloat(column) * 98
                return [
                    Region(x, 70, 88, 49.5, highlighted: !details, kind: .episode),
                    Region(x, 128, 62, 5), Region(x, 141, 82, 4), Region(x, 153, 73, 4)
                ]
            }
        case .playback:
            return [
                Region(0, 0, 320, 180), Region(16, 88, 100, 6)
            ] + (0..<3).flatMap { column -> [Region] in
                let x = 16 + CGFloat(column) * 98
                return [
                    Region(x, 105, 88, 49.5, highlighted: true, kind: .thumbnail),
                    Region(x, 162, 65, 4)
                ]
            }
        case .music:
            return [
                Region(20, 24, 112, 112, highlighted: true, kind: .cover),
                Region(158, 48, 126, 6), Region(158, 67, 84, 5),
                Region(158, 106, 12, 12), Region(187, 106, 12, 12), Region(216, 106, 12, 12),
                Region(20, 160, 264, 3)
            ]
        case .topShelf:
            return [Region(12, 18, 90, 5), Region(162, 18, 90, 5)]
                + (0..<6).map {
                    Region(12 + CGFloat($0) * 50, 32, 40, 60, highlighted: true, kind: .poster)
                }
                + (0..<4).map { Region(12 + CGFloat($0) * 76, 136, 68, 38.25) }
        case .downloads:
            return (0..<4).flatMap { index -> [Region] in
                let x = 20 + CGFloat(index % 2) * 160
                let y = 12 + CGFloat(index / 2) * 86
                return [Region(x, y, 112, 63, highlighted: true, kind: .thumbnail),
                        Region(x, y + 69, 94, 5)]
            }
        }
    }
}
#endif
