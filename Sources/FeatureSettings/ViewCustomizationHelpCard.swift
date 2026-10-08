#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ViewCustomizationHelp {
    let detail: LocalizedStringResource
    let illustration: Illustration

    enum Illustration: Hashable {
        case artwork(ArtworkArea)
        case captions(style: CardStyle, showsCaptions: Bool, showsMixedCaptions: Bool)
    }
}

struct ViewCustomizationHelpCard: View {
    let help: ViewCustomizationHelp
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var contentHeight: CGFloat = 112

    var body: some View {
        HStack(spacing: 28) {
            illustration
                .frame(width: 180, height: 112)
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
        case .artwork(let area):
            ArtworkScopeDiagram(area: area)
        case .captions(let style, let showsCaptions, let showsMixedCaptions):
            CardStyleSwatch(
                style: style, cornerRadius: 10,
                showsCaptions: showsCaptions, showsMixedCaptions: showsMixedCaptions
            )
        }
    }
}

/// A location map, not a sample of the artwork a provider might return.
struct ArtworkScopeDiagram: View {
    let area: ArtworkArea
    @Environment(\.themePalette) private var palette

    struct Region: Equatable {
        let frame: CGRect
        var highlighted = false
        var artwork = false

        init(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
             highlighted: Bool = false, artwork: Bool = false) {
            frame = CGRect(x: x, y: y, width: width, height: height)
            self.highlighted = highlighted
            self.artwork = artwork
        }
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 180, y: size.height / 112)
            context.fill(Path(CGRect(x: 0, y: 0, width: 180, height: 112)),
                         with: .color(palette.settingsBackground))
            for region in Self.regions(for: area) {
                let shape = Path(roundedRect: region.frame, cornerRadius: 3)
                context.fill(shape, with: .color(region.highlighted ? palette.accent.opacity(0.2) : palette.fill))
                if region.highlighted {
                    context.stroke(shape, with: .color(palette.accent), lineWidth: 1.5)
                }
                if region.artwork {
                    var image = context.resolve(Image(systemName: "photo"))
                    image.shading = .color(region.highlighted ? palette.accent : palette.tertiaryText)
                    let width = min(region.frame.width * 0.5, 22)
                    let height = min(region.frame.height * 0.5, width * 0.7)
                    context.draw(image, in: CGRect(
                        x: region.frame.midX - width / 2, y: region.frame.midY - height / 2,
                        width: width, height: height
                    ))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func regions(for area: ArtworkArea) -> [Region] {
        let sidebar = [Region(10, 14, 12, 12), Region(12, 38, 8, 5),
                       Region(12, 52, 8, 5), Region(12, 66, 8, 5)]
        let hero = Region(34, 10, 134, 54, artwork: true)
        let row = (0..<3).map {
            Region(34 + CGFloat($0) * 46, 78, 40, 24, highlighted: true, artwork: true)
        }
        switch area {
        case .home, .recommendedHero, .homeRows, .recommended, .continueWatching:
            let highlightsHero = area == .home || area == .recommendedHero
            var background = hero
            background.highlighted = highlightsHero
            var cards = row
            for index in cards.indices { cards[index].highlighted = !highlightsHero }
            var result = sidebar + [background, Region(44, 48, 48, 6, highlighted: highlightsHero)] + cards
            if area == .continueWatching {
                result += (0..<3).map { Region(38 + CGFloat($0) * 46, 96, 23, 2) }
            }
            return result
        case .browse, .collections, .playlists, .search, .watchlist:
            var result = sidebar + [Region(34, 12, area == .search ? 134 : 72, 8)]
            for y in [CGFloat(32), 72] {
                for column in 0..<4 {
                    result.append(Region(34 + CGFloat(column) * 35, y, 28, 32,
                                         highlighted: true, artwork: true))
                }
            }
            return result
        case .details, .episodes:
            var background = hero
            background.highlighted = area == .details
            return sidebar + [background, Region(44, 48, 48, 6, highlighted: area == .details)] + row
        case .playback:
            return [
                Region(10, 10, 160, 54), Region(14, 44, 66, 4),
                Region(14, 68, 40, 25, highlighted: true, artwork: true),
                Region(62, 71, 54, 5), Region(62, 83, 36, 4),
                Region(128, 68, 40, 25, highlighted: true, artwork: true),
                Region(14, 102, 154, 2)
            ]
        case .music:
            return [
                Region(14, 18, 62, 62, highlighted: true, artwork: true),
                Region(92, 32, 65, 5), Region(92, 45, 45, 4),
                Region(92, 66, 8, 8), Region(110, 66, 8, 8), Region(128, 66, 8, 8),
                Region(14, 96, 144, 2)
            ]
        case .topShelf:
            return [Region(10, 10, 160, 54, highlighted: true, artwork: true)]
                + (0..<3).map { Region(10 + CGFloat($0) * 55, 80, 50, 22) }
        case .downloads:
            return sidebar + (0..<3).flatMap { index -> [Region] in
                let y = 12 + CGFloat(index) * 32
                return [Region(34, y, 18, 26, highlighted: true, artwork: true),
                        Region(62, y + 4, 88, 5), Region(62, y + 16, 56, 3)]
            }
        }
    }
}
#endif
