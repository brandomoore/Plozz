#if canImport(SwiftUI)
import CoreModels
import MetadataKit
import SwiftUI

public enum FeaturedCardLayout {
    static let scrimStops: [(location: CGFloat, opacity: Double)] = [(0.35, 0), (0.65, 0.42), (1, 0.88)]

    static func scrimOpacity(at position: CGFloat) -> Double {
        for (start, end) in zip(scrimStops, scrimStops.dropFirst()) where position <= end.location {
            let progress = min(1, max(0, (position - start.location) / (end.location - start.location)))
            return start.opacity + Double(progress) * (end.opacity - start.opacity)
        }
        return scrimStops.last!.opacity
    }

    public static func size(viewportWidth: CGFloat, television: Bool) -> CGSize {
        let width = television
            ? min(560, max(280, (viewportWidth - 96) / 3.15))
            : min(440, max(220, viewportWidth - 48))
        guard television else { return CGSize(width: width, height: width * 1.125) }
        // Preserve the 4:5 ratio without fractional native clip bounds, even on 2x displays.
        let alignedWidth = (width / 4).rounded(.up) * 4
        return CGSize(width: alignedWidth, height: alignedWidth * 1.25)
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
            asyncFallbackURL: { [item, spoilerSettings] in
                guard !spoilerSettings.shouldHideThumbnail(for: item) else { return nil }
                return await ArtworkSession.resolveArtwork(background: false) {
                    await ArtworkRouter.shared.portraitHeroArtworkURL(for: item)
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
        artwork.resolvedBitmap { image in
            NativeTVPoster(
                image: image, treatment: .original, aspectRatio: size.width / size.height,
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
                    Text(verbatim: metadata)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
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
            title.font(.title2.bold()).lineLimit(3).foregroundStyle(.white)
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
