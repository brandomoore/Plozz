#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct HeroLogoSizePreview: View {
    @Environment(\.plozzHeroBaseTextScale) private var appTextScale
    let size: HeroLogoSize
    let surface: HeroLogoSizing.Surface
    let layout: HeroLogoSizing.Layout
    let textSize: HeroTextSize
    let cornerRadius: CGFloat

    public init(
        size: HeroLogoSize, surface: HeroLogoSizing.Surface, layout: HeroLogoSizing.Layout,
        textSize: HeroTextSize = .default,
        cornerRadius: CGFloat = PlozzTheme.Metrics.Radius.content
    ) {
        self.size = size
        self.surface = surface
        self.layout = layout
        self.textSize = textSize
        self.cornerRadius = cornerRadius
    }

    private var mobile: Bool { layout == .compact || layout == .regular }
    private var screen: CGSize {
        mobile ? CGSize(width: layout == .compact ? 390 : 820, height: 360)
            : CGSize(width: 1920, height: surface == .detail ? 1440 : 1080)
    }

    public var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / screen.width
            scene
                .frame(width: screen.width, height: screen.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var scene: some View {
        if surface == .detail && !mobile {
            detailScene
        } else {
            standardScene
        }
    }

    private var detailScene: some View {
        let scale = PlozzTypography.scale(local: textSize.scale, app: appTextScale)
        let metadataScale = PlozzTypography.heroMetadataScale(local: textSize.scale, app: appTextScale)
        let description = PlozzTypography.heroDescription.scaled(by: scale)
        let episodeDescription = PlozzTypography.episodeDescription.scaled(by: scale)
        let episodeTitle = PlozzTypography.episodeTitle.scaled(by: scale)
        let descriptionWidth = HeroDescriptionFactsLayout.minimumWidth
        return ZStack(alignment: .topLeading) {
            Color.black
            HomePreviewBackdrop(style: .carousel, size: CGSize(width: 1920, height: 1080))
            VStack(alignment: .leading, spacing: 24) {
                HeroLogoPreviewWordmark(size: size, layout: layout)
                Capsule().fill(.white.opacity(0.5))
                    .frame(width: 300, height: PlozzTypography.heroMetadata.scaled(by: metadataScale).pointSize * 0.7)
                VStack(alignment: .leading, spacing: description.pointSize * 0.4 + description.lineSpacing) {
                    ForEach(0..<PlozzTypography.detailDescriptionLines, id: \.self) { line in
                        Capsule().fill(.white.opacity(0.35))
                            .frame(width: descriptionWidth * (line == 3 ? 0.775 : 1), height: description.pointSize * 0.6)
                    }
                }
                HStack(spacing: 24) {
                    Capsule().fill(.white.opacity(0.85)).frame(width: 168, height: 64)
                    Circle().fill(.white.opacity(0.25)).frame(width: 64, height: 64)
                }
            }
            .frame(width: descriptionWidth, height: 900, alignment: .bottomLeading)
            .offset(x: 80)
            VStack(alignment: .leading, spacing: 16 * metadataScale) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 400, height: 18 * metadataScale)
                Capsule().fill(.white.opacity(0.4)).frame(width: 320, height: 18 * metadataScale)
            }
            .frame(height: 900, alignment: .bottomLeading)
            .offset(x: 1400)
            HStack(alignment: .top, spacing: EpisodeColumnCard.trailingSpacing) {
                ForEach(0..<4) { index in
                    VStack(alignment: .leading, spacing: 12) {
                        HomePreviewArtwork()
                            .frame(width: EpisodeColumnCard.artworkSize.width, height: EpisodeColumnCard.artworkSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Capsule().fill(.white.opacity(0.7))
                            .frame(width: 360, height: episodeTitle.pointSize * 0.7)
                        VStack(alignment: .leading, spacing: episodeDescription.pointSize * 0.4 + episodeDescription.lineSpacing) {
                            ForEach(0..<3) { line in
                                Capsule().fill(.white.opacity(index == 0 ? 0.4 : 0.2))
                                    .frame(width: line == 2 ? 350 : 460, height: episodeDescription.pointSize * 0.6)
                            }
                        }
                    }
                    .frame(width: EpisodeColumnCard.artworkSize.width, alignment: .leading)
                }
            }
            .offset(x: 80, y: 1000)
        }
    }

    private var standardScene: some View {
        let textScale = PlozzTypography.scale(local: textSize.scale, app: appTextScale)
        let metadataScale = PlozzTypography.heroMetadataScale(local: textSize.scale, app: appTextScale)
        let leading: CGFloat = mobile ? 22 : 144
        let availableWidth = screen.width - leading * 2
        let minimumWidth: CGFloat = layout == .compact ? 500 : 0
        let descriptionScale = surface == .home
            ? HeroLogoSizing.homeTextWidth(
                for: layout, logoSize: size, minimumWidth: minimumWidth, availableWidth: availableWidth
            ) / HeroLogoSizing.homeTextWidth(
                for: layout, minimumWidth: minimumWidth, availableWidth: availableWidth
            )
            : textScale
        let wordmark = HeroLogoPreviewWordmark(
            size: size, layout: layout, availableWidth: mobile ? screen.width - leading * 2 : .infinity
        )
        let fitted = wordmark.fittedSize
        let showsActions = surface != .showcase
        let railTop: CGFloat = showsActions ? 980 : 640
        let detailsHeight: CGFloat = 18 * metadataScale + (2 * 18 + (showsActions ? 3 : 2) * 22) * textScale
            + (showsActions ? 76 : 0)
        let baseline: CGFloat = mobile ? 205 : min(showsActions ? 640 : 300, railTop - 32 - detailsHeight - 28)
        let x = layout == .compact ? (screen.width - fitted.width) / 2 : leading
        return ZStack(alignment: .topLeading) {
            if mobile {
                Color(white: 0.06)
                HomePreviewArtwork()
                    .frame(width: screen.width * 0.75, height: screen.height)
                    .offset(x: screen.width * 0.25)
                LinearGradient(
                    colors: [.black.opacity(0.8), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                HomePreviewBackdrop(style: surface == .showcase ? .followsFocus : .carousel, size: screen)
            }
            wordmark
                .offset(x: x, y: baseline - fitted.height)
            VStack(alignment: .leading, spacing: (mobile ? 10 : 22) * textScale) {
                Capsule().fill(.white.opacity(0.5))
                    .frame(width: (mobile ? 160 : 300) * metadataScale, height: (mobile ? 5 : 18) * metadataScale)
                Capsule().fill(.white.opacity(0.3))
                    .frame(width: (mobile ? 250 : 480) * descriptionScale, height: (mobile ? 5 : 18) * textScale)
                Capsule().fill(.white.opacity(0.3))
                    .frame(width: (mobile ? 210 : 400) * descriptionScale, height: (mobile ? 5 : 18) * textScale)
                if surface != .showcase {
                    HStack(spacing: mobile ? 12 : 24) {
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: mobile ? 92 : 168, height: mobile ? 32 : 64)
                        Circle().fill(.white.opacity(0.25))
                            .frame(width: mobile ? 32 : 64, height: mobile ? 32 : 64)
                    }
                    .padding(.top, mobile ? 4 : 12)
                }
            }
            .offset(x: layout == .compact ? (screen.width - 250 * descriptionScale) / 2 : leading,
                    y: baseline + (mobile ? 16 : 28))
            if !mobile {
                HStack(spacing: 32) {
                    ForEach(0..<5) { _ in
                        RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.14))
                            .frame(width: 360, height: 210)
                    }
                }
                .offset(x: leading, y: railTop)
            }
        }
    }
}

struct HeroLogoPreviewWordmark: View {
    let size: HeroLogoSize
    let layout: HeroLogoSizing.Layout
    var availableWidth: CGFloat = .infinity

    var fittedSize: CGSize {
        let box = HeroLogoSizing.box(for: layout, size: size, availableWidth: availableWidth)
        return HeroLogoFit.fittedSize(
            for: CGSize(width: 600, height: 110), maxWidth: box.width, maxHeight: box.height,
            coverage: 0.32, constrainsToBounds: layout.constrainsToBounds
        )
    }

    var body: some View {
        Text(verbatim: "NORTHSTAR")
            .font(.system(size: 82, weight: .black, design: .serif))
            .tracking(4)
            .foregroundStyle(.white)
            .fixedSize()
            .frame(width: 600, height: 110)
            .scaleEffect(fittedSize.width / 600, anchor: .topLeading)
            .frame(width: fittedSize.width, height: fittedSize.height, alignment: .topLeading)
    }
}
#endif
