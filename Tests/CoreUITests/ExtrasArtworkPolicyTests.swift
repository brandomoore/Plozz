#if canImport(SwiftUI)
import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ExtrasArtworkPolicyTests: XCTestCase {
    private let policy = CardArtworkPolicy.extra

    func testDistinctExtrasKeepTheirOwnThumbnailsBeforeSharedParentArt() {
        let parent = url("parent.jpg")
        let first = MediaItem(
            id: "extra-one", title: "Making Of", kind: .video,
            posterURL: url("one.jpg"), backdropURL: parent
        )
        let second = MediaItem(
            id: "extra-two", title: "Deleted Scene", kind: .movie,
            posterURL: url("two.jpg"), backdropURL: parent
        )
        XCTAssertEqual(references(first), [.remote(url("one.jpg")), .remote(parent)])
        XCTAssertEqual(references(second), [.remote(url("two.jpg")), .remote(parent)])
        XCTAssertEqual(first.id, "extra-one")
        XCTAssertEqual(second.kind, .movie)
    }

    func testExplicitParentBackdropCannotPreemptPrimaryArtwork() {
        var item = MediaItem(
            id: "extra", title: "Making Of", kind: .video,
            posterURL: url("thumbnail.jpg"), backdropURL: url("parent.jpg"),
            heroBackdropURL: url("hero.jpg"), fallbackArtworkURL: url("fallback.jpg")
        )
        item.artworkSelections = [
            ArtworkSelection(placement: .detailBackdrop, references: [.remote(url("selected-parent.jpg"))])
        ]
        XCTAssertEqual(references(item), [
            .remote(url("thumbnail.jpg")), .remote(url("selected-parent.jpg")),
            .remote(url("parent.jpg")), .remote(url("fallback.jpg"))
        ])
        item.artworkSelections.append(
            ArtworkSelection(placement: .poster, references: [.remote(url("selected-primary.jpg"))])
        )
        XCTAssertEqual(Array(references(item).prefix(2)), [
            .remote(url("selected-primary.jpg")), .remote(url("thumbnail.jpg"))
        ])
        XCTAssertFalse(references(item).contains(.remote(url("hero.jpg"))))
    }

    func testMissingThumbnailsRetainNativeFallbacksAndMissingAllArtHasNoCandidates() {
        var item = MediaItem(
            id: "extra", title: "Making Of", kind: .video,
            backdropURL: url("parent.jpg"), fallbackArtworkURL: url("fallback.jpg")
        )
        XCTAssertEqual(references(item), [.remote(url("parent.jpg")), .remote(url("fallback.jpg"))])
        item.backdropURL = nil
        XCTAssertEqual(references(item), [.remote(url("fallback.jpg"))])
        item.fallbackArtworkURL = nil
        XCTAssertTrue(references(item).isEmpty)
        XCTAssertNil(card(item).asyncArtworkFallback)
    }

    func testCandidatesDeduplicateWithoutChangingPriorityOrAuthenticatedURLs() {
        let primary = url("thumb.jpg?X-Plex-Token=fixture-token&tag=thumb")
        let parent = url("parent.jpg?api_key=fixture-token")
        var item = MediaItem(
            id: "extra", title: "Making Of", kind: .video,
            posterURL: primary, backdropURL: parent, fallbackArtworkURL: parent
        )
        item.artworkSelections = [
            ArtworkSelection(placement: .poster, references: [.remote(primary)]),
            ArtworkSelection(placement: .detailBackdrop, references: [.remote(parent), .remote(primary)])
        ]
        XCTAssertTrue(references(item) == [.remote(primary), .remote(parent)])
        let warmed = prefetch(item)
        XCTAssertTrue(warmed == [primary, parent])
        XCTAssertTrue(
            warmed.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value == "fixture-token"
        )
    }

    func testPrefetchUsesRenderOrderIncludingExplicitRemoteReferences() {
        var item = MediaItem(
            id: "extra", title: "Making Of", kind: .video,
            posterURL: url("primary.jpg"), backdropURL: url("backdrop.jpg"),
            fallbackArtworkURL: url("fallback.jpg")
        )
        item.artworkSelections = [
            ArtworkSelection(placement: .poster, references: [.remote(url("explicit-primary.jpg"))]),
            ArtworkSelection(placement: .detailBackdrop, references: [.remote(url("explicit-backdrop.jpg"))])
        ]
        for style in [PosterCardView.Style.poster, .landscape] {
            let rendered = policy.references(for: item, style: style)
            let warmed = MediaArtworkPrefetchPolicy.candidates(
                for: item, style: style, spoilerSettings: .default, artworkPolicy: .extra
            )
            XCTAssertEqual(warmed.map(ArtworkReference.remote), rendered)
            XCTAssertEqual(item.artworkCandidates(for: style, artworkPolicy: .extra), warmed)
        }
    }

    func testExtrasDisableOnlineFallbackForBothCardStyles() {
        let item = MediaItem(id: "extra", title: "Making Of", kind: .video)
        XCTAssertFalse(policy.allowsOnlineFallback)
        XCTAssertTrue(CardArtworkPolicy.standard.allowsOnlineFallback)
        for style in [PosterCardView.Style.poster, .landscape] {
            let extra = PosterCardView(item: item, style: style, artworkPolicy: .extra) {}
            let standard = PosterCardView(item: item, style: style) {}
            let disabled = PosterCardView(
                item: item, style: style, enablesAsyncArtworkFallback: false
            ) {}
            XCTAssertNil(extra.asyncArtworkFallback)
            XCTAssertNotNil(standard.asyncArtworkFallback)
            XCTAssertNil(disabled.asyncArtworkFallback)
        }
    }

    func testExtraResolutionIdentityIsolatedFromGenericCardAndOtherAccounts() {
        let item = MediaItem(
            id: "same-id", title: "Making Of", kind: .video,
            posterURL: url("only-image.jpg")
        )
        XCTAssertEqual(references(item), CardArtworkPolicy.standard.references(for: item, style: .landscape))
        XCTAssertNotEqual(policy.pinIdentity(for: item), CardArtworkPolicy.standard.pinIdentity(for: item))
        XCTAssertNotEqual(
            policy.pinIdentity(for: item.taggingSource("one")),
            policy.pinIdentity(for: item.taggingSource("two"))
        )
        let empty = MediaItem(id: "same-id", title: "Making Of", kind: .video)
        XCTAssertNotEqual(policy.pinIdentity(for: empty), CardArtworkPolicy.standard.pinIdentity(for: empty))
    }

    func testOrdinaryMovieCardsKeepBackdropFirstAndPosterCardsKeepPosterFirst() {
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie,
            posterURL: url("poster.jpg"), backdropURL: url("backdrop.jpg"),
            fallbackArtworkURL: url("fallback.jpg")
        )
        XCTAssertEqual(CardArtworkPolicy.standard.references(for: item, style: .landscape), [
            .remote(url("backdrop.jpg")), .remote(url("poster.jpg")), .remote(url("fallback.jpg"))
        ])
        XCTAssertEqual(CardArtworkPolicy.standard.references(for: item, style: .poster), [
            .remote(url("poster.jpg")), .remote(url("fallback.jpg"))
        ])
        for style in [PosterCardView.Style.poster, .landscape] {
            XCTAssertEqual(
                MediaArtworkPrefetchPolicy.candidates(for: item, style: style, spoilerSettings: .default),
                item.artworkCandidates(for: style)
            )
        }
        XCTAssertEqual(CardArtworkPolicy.standard.pinIdentity(for: item), item.stablePresentationID)
    }

    func testEpisodeAndSpoilerSafePrefetchBehaviorUnchanged() {
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            posterURL: url("still.jpg"), seriesPosterURL: url("show-poster.jpg"),
            backdropURL: url("episode-backdrop.jpg"), fallbackArtworkURL: url("show-backdrop.jpg")
        )
        XCTAssertEqual(
            CardArtworkPolicy.standard.references(for: episode, style: .landscape),
            episode.artworkReferences(for: .episodeThumbnail)
        )
        XCTAssertEqual(
            CardArtworkPolicy.standard.references(for: episode, style: .poster),
            episode.artworkReferences(for: .seriesPoster)
        )
        for artworkPolicy in [CardArtworkPolicy.standard, .extra] {
            for mode in [SpoilerSettings.Mode.blur, .placeholder] {
                let hidden = SpoilerSettings(isEnabled: true, mode: mode)
                let poster = MediaArtworkPrefetchPolicy.candidates(
                    for: episode, style: .poster, spoilerSettings: hidden, artworkPolicy: artworkPolicy
                )
                XCTAssertEqual(poster, [url("show-poster.jpg"), url("show-backdrop.jpg")])
                if mode == .placeholder {
                    XCTAssertEqual(MediaArtworkPrefetchPolicy.candidates(
                        for: episode, style: .landscape, spoilerSettings: hidden, artworkPolicy: artworkPolicy
                    ), [url("show-backdrop.jpg"), url("show-poster.jpg")])
                }
            }
        }
        XCTAssertEqual(MediaArtworkPrefetchPolicy.candidates(
            for: episode, style: .landscape, spoilerSettings: .default, showsSeriesArtwork: true
        ), [url("show-backdrop.jpg"), url("show-poster.jpg")])
    }

    #if canImport(UIKit)
    func testNetworkPrimaryRemainsRenderableWhilePrefetchProjectsOnlyRemoteURLs() throws {
        let primary = try networkReference()
        var item = MediaItem(
            id: "extra", title: "Making Of", kind: .video,
            posterURL: url("primary.jpg"), backdropURL: url("parent.jpg")
        )
        item.artworkSelections = [
            ArtworkSelection(placement: .poster, references: [.networkFile(primary)])
        ]
        XCTAssertEqual(references(item), [.networkFile(primary), .remote(url("primary.jpg")), .remote(url("parent.jpg"))])
        XCTAssertEqual(prefetch(item), [url("primary.jpg"), url("parent.jpg")])
    }

    func testResolverUsesThumbnailBeforeParentForEitherOnlinePreference() async throws {
        let primary = try networkReference()
        let parent = try networkReference()
        let loader = FixtureArtworkLoader(data: [
            primary.catalogArtworkID: try XCTUnwrap(image(.green).pngData()),
            parent.catalogArtworkID: try XCTUnwrap(image(.red).pngData())
        ])
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let item = networkItem(primary: primary, parent: parent)
        for prefersOnline in [false, true] {
            let resolved = await resolve(item, prefersOnline: prefersOnline)
            XCTAssertEqual(resolved?.reference, .networkFile(primary))
        }
        let requests = await loader.requests
        XCTAssertEqual(requests, [primary.catalogArtworkID])
    }

    func testResolverFallsThroughFailedThumbnailAndExhaustedArtBecomesPlaceholder() async throws {
        let primary = try networkReference()
        let parent = try networkReference()
        let loader = FixtureArtworkLoader(data: [
            parent.catalogArtworkID: try XCTUnwrap(image(.green).pngData())
        ])
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let item = networkItem(primary: primary, parent: parent)
        for prefersOnline in [false, true] {
            let resolved = await resolve(item, prefersOnline: prefersOnline)
            XCTAssertEqual(resolved?.reference, .networkFile(parent))
        }
        let missing = networkItem(primary: try networkReference(), parent: try networkReference())
        let exhausted = await resolve(missing, prefersOnline: true)
        XCTAssertNil(exhausted)
    }

    func testActualCardPaintsThumbnailInsteadOfGenericOnlineMemoForEitherPreference() async throws {
        let settingsStore = MetadataProviderSettingsStore()
        let originalSettings = settingsStore.load()
        defer { settingsStore.save(originalSettings) }
        let primary = try networkReference()
        let loader = FixtureArtworkLoader(data: [
            primary.catalogArtworkID: try XCTUnwrap(image(.green).pngData())
        ])
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let item = networkItem(primary: primary, parent: primary)
        let standardReferences = CardArtworkPolicy.standard.references(for: item, style: .landscape)
        XCTAssertEqual(standardReferences, references(item))
        let decoded = await ArtworkImageCache.shared.image(for: .networkFile(primary), variant: .landscapeCard)
        XCTAssertNotNil(decoded)
        for prefersOnline in [false, true] {
            var settings = originalSettings
            settings.preferOnlineArtwork = prefersOnline
            settingsStore.save(settings)
            let genericKey = ArtworkResolveKey.make(
                references: standardReferences, variant: .landscapeCard, maxAspectRatio: nil,
                pinIdentity: CardArtworkPolicy.standard.pinIdentity(for: item),
                providerPolicyIdentity: ArtworkResolveKey.policyIdentity(settings)
            )
            ArtworkSeedMemo.store(
                FirstPaintArtwork(image: image(.red), reference: .remote(url("wrong-online.jpg")), variant: .landscapeCard),
                for: genericKey
            )
            let renderer = ImageRenderer(content: card(item).realArtwork.frame(width: 16, height: 9))
            renderer.scale = 1
            let rendered = try XCTUnwrap(renderer.uiImage)
            let pixel = try centerPixel(rendered)
            XCTAssertLessThan(pixel[0], 10)
            XCTAssertGreaterThan(pixel[1], 240)
            XCTAssertLessThan(pixel[2], 10)
        }
    }

    private actor FixtureArtworkLoader: ArtworkNetworkFileLoading {
        let data: [String: Data]
        private(set) var requests: [String] = []

        init(data: [String: Data]) { self.data = data }

        func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
            requests.append(reference.catalogArtworkID)
            guard let image = data[reference.catalogArtworkID] else {
                throw ArtworkNetworkFileLoadError(.unavailable)
            }
            return image
        }
    }

    private func networkReference() throws -> NetworkArtworkReference {
        try NetworkArtworkReference(
            accountID: UUID().uuidString, credentialRevision: CredentialRevision(),
            catalogArtworkID: UUID().uuidString,
            representation: RemoteFileRepresentation(
                size: 1_024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: UUID().uuidString,
            dimensions: ArtworkDimensions(width: 16, height: 9)
        )
    }

    private func networkItem(primary: NetworkArtworkReference, parent: NetworkArtworkReference) -> MediaItem {
        var item = MediaItem(id: UUID().uuidString, title: "Making Of", kind: .video)
        item.artworkSelections = [
            ArtworkSelection(placement: .poster, references: [.networkFile(primary)]),
            ArtworkSelection(placement: .detailBackdrop, references: [.networkFile(parent)])
        ]
        return item
    }

    private func resolve(_ item: MediaItem, prefersOnline: Bool) async -> FirstPaintArtwork? {
        await ArtworkFirstPaintResolver.resolve(
            references: references(item), variant: .landscapeCard,
            asyncOnlineURL: card(item).asyncArtworkFallback, maximumOnlineWait: 0,
            prefersOnlineArtwork: prefersOnline
        )
    }

    private func image(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
    #endif

    private func url(_ path: String) -> URL { URL(string: "https://art.example.test/\(path)")! }

    private func references(_ item: MediaItem) -> [ArtworkReference] {
        policy.references(for: item, style: .landscape)
    }

    private func prefetch(_ item: MediaItem) -> [URL] {
        MediaArtworkPrefetchPolicy.candidates(
            for: item, style: .landscape, spoilerSettings: .default, artworkPolicy: .extra
        )
    }

    private func card(_ item: MediaItem) -> PosterCardView {
        PosterCardView(item: item, style: .landscape, artworkPolicy: .extra) {}
    }
}
#endif
