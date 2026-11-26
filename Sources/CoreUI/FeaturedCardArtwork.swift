#if canImport(SwiftUI)
import CoreModels
import MetadataKit
import SwiftUI
#if os(tvOS)
import UIKit
#endif

public enum FeaturedCardLayout {
    static let scrimStops: [(location: CGFloat, opacity: Double)] = [(0.35, 0), (0.65, 0.42), (1, 0.88)]

    static func scrimOpacity(at position: CGFloat) -> Double {
        for (start, end) in zip(scrimStops, scrimStops.dropFirst()) where position <= end.location {
            let progress = min(1, max(0, (position - start.location) / (end.location - start.location)))
            return start.opacity + Double(progress) * (end.opacity - start.opacity)
        }
        return scrimStops.last!.opacity
    }

    public static func rail(
        viewportWidth: CGFloat, television: Bool, textWidthScale: CGFloat = 1, maximumArtworkWidth: CGFloat? = nil
    ) -> (size: CGSize, spacing: CGFloat) {
        let available = max(1, viewportWidth - (television ? PlozzTheme.Metrics.screenPadding : 20))
        let spacing: CGFloat = television ? 32 : 16
        let preferred = MediaRailLayout.wholeCards(
            available: available, preferredSlot: television ? 540 * textWidthScale : 360, spacing: spacing
        )
        let count = MediaRailLayout.fittingCount(
            preferred, available: available, spacing: spacing, maximumArtworkWidth: maximumArtworkWidth
        )
        let width = MediaRailLayout.slotWidth(available: available, count: count, spacing: spacing)
        guard television else { return (CGSize(width: width, height: width * 1.125), spacing) }
        // Native 4:5 clips need integral bounds. Absorb their rounding in the
        // gutters instead of rounding away some of the quarter-card reveal.
        let aligned = max(4, (width / 4).rounded(.down) * 4)
        let gap = (available - aligned * (CGFloat(count) + MediaRailLayout.peekFraction)) / CGFloat(count)
        return (CGSize(width: aligned, height: aligned * 1.25), max(0, gap))
    }

    public static func size(viewportWidth: CGFloat, television: Bool) -> CGSize {
        rail(viewportWidth: viewportWidth, television: television).size
    }
}

/// The editor and the live rail share the same artwork, title and metadata.
public struct FeaturedCardArtwork<Video: View>: View {
    private let item: MediaItem
    private let size: CGSize
    private let spoilerSettings: SpoilerSettings
    private let usesNativeClipping: Bool
    private let video: Video
    @State private var resolvedArtwork: ArtworkReference?
    @Environment(\.plozzArtworkPolicy) private var artworkPolicy
    @Environment(\.plozzNativeFocusSurface) private var nativeFocusSurface
    @Environment(\.plozzShowsContentRatings) private var showsContentRatings
    #if os(tvOS)
    private struct NativeControl {
        let focus: PlozzCardFocus.Binding
        let action: () -> Void
    }
    private var nativeControl: NativeControl?

    public func nativeButton(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) -> Self {
        var copy = self
        copy.nativeControl = NativeControl(focus: focus, action: action)
        return copy
    }
    #endif

    public init(
        item: MediaItem, size: CGSize, spoilerSettings: SpoilerSettings = .default,
        usesNativeClipping: Bool = false,
        @ViewBuilder video: () -> Video
    ) {
        self.item = item
        self.size = size
        self.spoilerSettings = spoilerSettings
        self.usesNativeClipping = usesNativeClipping
        self.video = video()
    }

    private var title: Text {
        spoilerSettings.shouldHideText(for: item)
            ? Text(spoilerSettings.maskedTitle(for: item)) : Text(verbatim: item.title)
    }

    private var metadata: String {
        metadata(rating: item.ratingBadge.map { ContentRatingPresentation($0.label).text })
    }

    private var accessibilityMetadata: String {
        metadata(rating: item.officialRating)
    }

    private func metadata(rating: String?) -> String {
        [item.genres.first, item.productionYear.map(String.init), showsContentRatings ? rating : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var body: some View {
        #if os(tvOS)
        if let nativeControl {
            nativeButton(control: nativeControl)
        } else {
            standaloneArtwork
        }
        #else
        standaloneArtwork
        #endif
    }

    private var standaloneArtwork: some View {
        Group {
            if usesNativeClipping || nativeFocusSurface {
                layers { artwork }
            } else {
                layers { artwork }.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: accessibilityMetadata))
    }

    private var artwork: FallbackAsyncImage<ArtworkFillImage, MediaArtworkPlaceholder> {
        FallbackAsyncImage(
            references: spoilerSettings.shouldHideThumbnail(for: item)
                ? item.seriesArtworkReferences() : item.artworkReferences(for: .homeHero),
            variant: .posterCard,
            previewVariant: .posterPreview,
            artworkPolicy: artworkPolicy.forPlacement(.homeHero),
            asyncFallbackURL: { [item, spoilerSettings, language = artworkPolicy.artworkLanguage] in
                guard !spoilerSettings.shouldHideThumbnail(for: item) else { return nil }
                return await ArtworkSession.resolveArtwork(background: false) {
                    await ArtworkRouter.shared.portraitHeroArtworkURL(for: item, language: language)
                }
            },
            onResolveReference: { resolvedArtwork = $0 },
            pinIdentity: "\(item.stablePresentationID)|featured",
            content: ArtworkFillImage.init
        ) {
            placeholder
        }
    }

    private var placeholder: MediaArtworkPlaceholder {
        MediaArtworkPlaceholder(tint: .white, glyphSize: size.width * 0.12)
    }

    #if os(tvOS)
    private func nativeButton(control: NativeControl) -> some View {
        artwork.resolvedBitmap { image, identity in
            NativeTVPoster(
                image: image, artworkIdentity: identity,
                treatment: .original, aspectRatio: size.width / size.height,
                fallbackWidth: size.width,
                title: spoilerSettings.shouldHideText(for: item)
                    ? .localized(spoilerSettings.maskedTitle(for: item)) : .content(item.title),
                subtitle: accessibilityMetadata,
                overlay: layers(scrimOutset: 40) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                },
                rasterizesOverlay: false,
                clipsOverlayToArtwork: false,
                focus: control.focus, action: control.action
            )
            .focused(control.focus.focusState)
            .frame(width: size.width, height: size.height)
        }
    }
    #endif

    private func layers<Artwork: View>(
        scrimOutset: CGFloat = 0, @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            artwork()
                .frame(width: size.width, height: size.height)
            video
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            scrim(outset: scrimOutset)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                FeaturedCardLogo(item: item, title: title, size: size, artwork: resolvedArtwork)
                if !metadata.isEmpty {
                    FeaturedCardCaptionText(text: Text(verbatim: metadata), role: .metadata)
                }
            }
            .padding(size.width * 0.065)
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "featured-card")
        .background(.black)
    }

    private func scrim(outset: CGFloat) -> some View {
        let height = size.height + 2 * outset
        // Extend the edge colors without moving the fade inside the artwork.
        return LinearGradient(stops: FeaturedCardLayout.scrimStops.map {
            .init(color: .black.opacity($0.opacity), location: ($0.location * size.height + outset) / height)
        }, startPoint: .top, endPoint: .bottom)
            .frame(width: size.width + 2 * outset, height: height)
            .frame(width: size.width, height: size.height)
    }
}

private struct FeaturedCardLogo: View {
    let item: MediaItem
    let title: Text
    let size: CGSize
    let artwork: ArtworkReference?
    @State private var logoTone: ResolvedLogoTone?
    @State private var artworkTone: HeroBackgroundSample?
    @State private var frame = CGRect.zero

    private struct SampleRequest: Equatable {
        let artwork: ArtworkReference?
        let frame: CGRect
        let size: CGSize
    }

    private var needsHelp: Double? {
        guard let logoTone, let artworkTone else { return nil }
        return 1 - ContinueWatchingCardShape.separation(logo: logoTone, background: artworkTone)
    }

    var body: some View {
        HeroLogoArtwork(
            references: item.artworkReferences(for: .logo),
            asyncFallbackURL: HeroLogoFallback(for: item, localizedResolve: { [item] language in
                await ArtworkSession.resolveArtwork(background: false) {
                    await ArtworkRouter.shared.artworkURL(.logo, for: item, language: language)
                }
            }),
            maxWidth: size.width * 0.72, maxHeight: size.height * 0.19,
            constrainsToBounds: true, haloStyle: .gentle, logoNeedsHelp: needsHelp,
            onResolve: { logoTone = $0 }
        ) {
            FeaturedCardCaptionText(text: title, role: .title)
        }
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("featured-card")) } action: { frame = $0 }
        .task(id: SampleRequest(artwork: artwork, frame: frame, size: size)) {
            artworkTone = nil
            #if canImport(UIKit)
            guard let artwork, !frame.isEmpty, size.width > 0, size.height > 0,
                  let image = await ArtworkImageCache.shared.image(for: artwork, variant: .posterCard),
                  image.size.width > 0, image.size.height > 0 else { return }
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            // Measure only the visible crop beneath the logo, not the wide image's discarded edges.
            let region = CGRect(
                x: (frame.minX + (width - size.width) / 2) / width,
                y: (frame.minY + (height - size.height) / 2) / height,
                width: frame.width / width, height: frame.height / height
            )
            let sample = await HeroBackgroundSampler.sample(
                artwork: FirstPaintArtwork(image: image, reference: artwork, variant: .posterCard), region: region
            )
            guard !Task.isCancelled else { return }
            if let sample {
                let remaining = 1 - FeaturedCardLayout.scrimOpacity(at: frame.midY / size.height)
                artworkTone = HeroBackgroundSample(
                    red: sample.red * remaining, green: sample.green * remaining,
                    blue: sample.blue * remaining, luminance: sample.luminance * remaining
                )
            }
            #endif
        }
    }
}

struct FeaturedCardCaptionText: View {
    enum Role { case title, metadata }
    let text: Text
    let role: Role
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(text: Text, role: Role) {
        self.text = text
        self.role = role
    }

    private var font: Font {
        #if os(tvOS)
        let traits = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.plozzContentSizeCategory)
        let pointSize = UIFont.preferredFont(
            forTextStyle: role == .title ? .title2 : .subheadline, compatibleWith: traits
        ).pointSize
        return .system(size: pointSize, weight: role == .title ? .bold : .medium)
        #else
        return role == .title ? .title2.bold() : .subheadline.weight(.medium)
        #endif
    }

    var body: some View {
        text
            .font(font)
            .foregroundStyle(.white.opacity(role == .title ? 1 : 0.9))
            .lineLimit(role == .title ? 3 : 2)
            #if os(tvOS)
            .minimumScaleFactor(1)
            .fixedSize(horizontal: false, vertical: true)
            #endif
    }
}

public extension FeaturedCardArtwork where Video == EmptyView {
    init(
        item: MediaItem, size: CGSize, spoilerSettings: SpoilerSettings = .default,
        usesNativeClipping: Bool = false
    ) {
        self.init(
            item: item, size: size, spoilerSettings: spoilerSettings, usesNativeClipping: usesNativeClipping
        ) { EmptyView() }
    }
}
#endif
