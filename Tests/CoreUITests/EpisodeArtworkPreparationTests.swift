#if canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class EpisodeArtworkPreparationTests: XCTestCase {
    func testContinueWatchingPreparesNetworkShareArtworkWithoutURLConversion() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        let loader = EpisodeArtworkLoader(data: try XCTUnwrap(image.pngData()))
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let reference = ArtworkReference.networkFile(try NetworkArtworkReference(
            accountID: UUID().uuidString, credentialRevision: CredentialRevision(),
            catalogArtworkID: UUID().uuidString,
            representation: RemoteFileRepresentation(
                size: 1_024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: UUID().uuidString, dimensions: ArtworkDimensions(width: 160, height: 90)
        ))
        var item = MediaItem(id: UUID().uuidString, title: "Share movie", kind: .movie)
        item.artworkSelections = [.init(placement: .detailBackdrop, references: [reference])]
        let policy = ArtworkPresentationPolicy(area: .continueWatching, settings: .init(preference: .library))
        let source = ContinueWatchingArtworkSource(
            item: item, style: .landscape, policy: policy, enablesAsyncArtworkFallback: false
        )
        XCTAssertEqual(source.references(textlessBackdrop: nil).first, reference)
        await source.prepare()
        let key = ArtworkResolveKey.make(
            references: source.references(textlessBackdrop: nil), variant: .landscapeCard,
            maxAspectRatio: nil, pinIdentity: source.pinIdentity, providerPolicyIdentity: policy.identity
        )
        let prepared = try XCTUnwrap(ArtworkSeedMemo.prepared(for: key, variant: .landscapeCard))
        XCTAssertEqual(prepared.reference, reference)
        XCTAssertGreaterThan(try centerPixel(prepared.image)[1], 240)
    }

    func testContinueWatchingPreparationIdentityTracksSettingsAndSourceChanges() {
        let item = MediaItem(id: "same", title: "Movie", kind: .movie)
        func identity(_ item: MediaItem, _ preference: ArtworkPreference = .recommended) -> String {
            ContinueWatchingArtworkSource(
                item: item, style: .landscape,
                policy: .init(settings: .init(preference: preference))
            ).identity
        }
        XCTAssertNotEqual(identity(item), identity(item, .online))
        XCTAssertNotEqual(identity(item), identity(item, .library))
        XCTAssertNotEqual(identity(item.taggingSource("one")), identity(item.taggingSource("two")))
        var changed = item
        changed.logoURL = URL(string: "https://example.test/new-logo.png")
        XCTAssertNotEqual(identity(item), identity(changed))
        changed = item
        changed.title = "Corrected movie"
        XCTAssertNotEqual(identity(item), identity(changed))
    }

    func testEpisodeResolutionKeepsServerArtworkWhenOnlineSourcesAreUnavailable() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        defer {
            store.save(original)
            ArtworkImageCache.shared.configure(networkFileService: nil)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let loader = EpisodeArtworkLoader(data: try XCTUnwrap(image.pngData()))
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        for online in [false, true] {
            store.save(.init(
                orderMode: .custom, preferOnlineArtwork: online,
                disabledOrder: MetadataSourceAttribution.all.map(\.source.rawValue)
            ))
            let reference = try NetworkArtworkReference(
                accountID: UUID().uuidString, credentialRevision: CredentialRevision(),
                catalogArtworkID: UUID().uuidString,
                representation: RemoteFileRepresentation(
                    size: 1_024,
                    identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                    consistency: .changeDetecting
                ),
                sourceRevision: UUID().uuidString
            )
            var item = MediaItem(id: UUID().uuidString, title: "Episode", kind: .episode)
            item.artworkSelections = [
                ArtworkSelection(placement: .episodeThumbnail, references: [.networkFile(reference)])
            ]
            let source = EpisodeArtworkSource(
                item: item, spoilerSettings: .default,
                policy: .init(
                    area: .episodes, settings: .init(preference: online ? .online : .library),
                    providers: store.load()
                )
            )
            XCTAssertNil(source.preparedArtwork)
            let resolved = await source.resolve()
            XCTAssertEqual(resolved?.reference, .networkFile(reference))
            XCTAssertTrue(source.preparedArtwork?.image === resolved?.image)
            XCTAssertGreaterThan(try centerPixel(XCTUnwrap(resolved?.image))[1], 240)
        }
    }

    func testNativeResolutionReusesTheDetailWinnersWithoutConflatingSharedFallbacks() async throws {
        let shared = URL(string: "https://art.example.test/\(UUID())/shared.jpg")!
        let first = MediaItem(id: UUID().uuidString, title: "First", kind: .episode, posterURL: shared)
        var second = first
        second.id = UUID().uuidString
        let sources = [
            EpisodeArtworkSource(item: first.taggingSource("one"), spoilerSettings: .default),
            EpisodeArtworkSource(item: second.taggingSource("one"), spoilerSettings: .default),
            EpisodeArtworkSource(item: first.taggingSource("two"), spoilerSettings: .default)
        ]
        XCTAssertEqual(Set(sources.map(\.requestIdentity)).count, 3)
        let images = [UIColor.red, .green, .blue].map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
            }
        }
        for (index, source) in sources.enumerated() {
            XCTAssertEqual(source.requestIdentity, key(source))
            ArtworkSeedMemo.store(
                FirstPaintArtwork(
                    image: images[index],
                    reference: .remote(URL(string: "https://art.example.test/\(UUID())/still.jpg")!),
                    variant: .landscapeCard
                ),
                for: key(source)
            )
        }
        for (index, source) in sources.enumerated() {
            let resolved = await source.resolve()
            XCTAssertTrue(resolved?.image === images[index])
        }
    }

    func testPrewarmerUsesTheCardsExplicitReferenceBeforeLegacyURLs() {
        let explicit = URL(string: "https://art.example.test/selected.jpg")!
        let legacy = URL(string: "https://art.example.test/legacy.jpg")!
        var episode = MediaItem(id: "e1", title: "Episode", kind: .episode, posterURL: legacy)
        episode.artworkSelections = [
            ArtworkSelection(placement: .episodeThumbnail, references: [.remote(explicit)])
        ]
        let source = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        XCTAssertEqual(source.references, episode.artworkReferences(for: .episodeThumbnail))
        XCTAssertEqual(source.references.first, .remote(explicit))
    }

    func testSpoilerSafePreparationNeverUsesTheEpisodeFrame() {
        let still = URL(string: "https://art.example.test/episode.jpg")!
        let show = URL(string: "https://art.example.test/show.jpg")!
        let episode = MediaItem(
            id: "e1", title: "Episode", kind: .episode,
            posterURL: still, fallbackArtworkURL: show
        )
        let visible = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        let hidden = EpisodeArtworkSource(
            item: episode, spoilerSettings: .init(isEnabled: true, mode: .placeholder)
        )
        XCTAssertEqual(visible.references.first, .remote(still))
        XCTAssertEqual(hidden.references.first, .remote(show))
        XCTAssertFalse(hidden.references.contains(.remote(still)))
        XCTAssertNotEqual(visible.pinIdentity, hidden.pinIdentity)
    }

    func testPosterlessSpoilerModesCannotShareAPreparedImage() {
        let episode = MediaItem(id: "e1", title: "Episode", kind: .episode)
        let visible = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        let hidden = EpisodeArtworkSource(
            item: episode, spoilerSettings: .init(isEnabled: true, mode: .placeholder)
        )
        XCTAssertTrue(visible.references.isEmpty)
        XCTAssertTrue(hidden.references.isEmpty)
        XCTAssertNotEqual(key(visible), key(hidden))
    }

    func testPreparedOnlineWinnerPaintsSynchronouslyWithoutStartingItsResolver() throws {
        let policy = ArtworkPresentationPolicy(area: .episodes, settings: .init(preference: .online))
        let library = URL(string: "https://art.example.test/\(UUID()).jpg")!
        let online = URL(string: "https://art.example.test/\(UUID()).jpg")!
        let episode = MediaItem(id: UUID().uuidString, title: "Episode", kind: .episode, posterURL: library)
        let source = EpisodeArtworkSource(item: episode, spoilerSettings: .default, policy: policy)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let red = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        ArtworkSeedMemo.store(
            FirstPaintArtwork(image: red, reference: .remote(online), variant: .landscapeCard),
            for: key(source)
        )
        let renderer = ImageRenderer(content:
            FallbackAsyncImage(
                references: source.references, variant: .landscapeCard,
                artworkPolicy: policy, asyncFallbackURL: { nil }, pinIdentity: source.pinIdentity
            ) {
                Color.blue
            }
            .frame(width: 16, height: 9)
        )
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage)
        let color = try centerPixel(rendered)
        XCTAssertGreaterThan(color[0], 240)
        XCTAssertLessThan(color[1], 10)
        XCTAssertLessThan(color[2], 10)
        XCTAssertEqual(
            ArtworkSeedMemo.prepared(for: key(source), variant: .landscapeCard)?.reference,
            .remote(online)
        )
    }

    func testPreparedWinnerIsIsolatedByPolicyAndSourceAccount() {
        let episode = MediaItem(id: "same-id", title: "Episode", kind: .episode)
        let first = EpisodeArtworkSource(item: episode.taggingSource("one"), spoilerSettings: .default)
        let second = EpisodeArtworkSource(item: episode.taggingSource("two"), spoilerSettings: .default)
        XCTAssertNotEqual(key(first), key(second))
        var settings = MetadataProviderSettings.default
        let onlineKey = key(first, settings: settings)
        settings.preferOnlineArtwork = false
        XCTAssertNotEqual(onlineKey, key(first, settings: settings))
    }

    func testPreparedImagesStayWithinTheDecodedMemoryBudget() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
        let prefix = UUID().uuidString
        for index in 0..<30 {
            ArtworkSeedMemo.store(image, for: "\(prefix)-\(index)")
            XCTAssertLessThanOrEqual(ArtworkSeedMemo.residentCostBytes, ArtworkSeedMemo.maximumCostBytes)
        }
        XCTAssertNil(ArtworkSeedMemo.value(for: "\(prefix)-0"))
        XCTAssertNotNil(ArtworkSeedMemo.value(for: "\(prefix)-29"))
        ArtworkSeedMemo.removeAll()
        XCTAssertEqual(ArtworkSeedMemo.residentCostBytes, 0)
    }

    private func key(
        _ source: EpisodeArtworkSource,
        settings: MetadataProviderSettings? = nil
    ) -> String {
        ArtworkResolveKey.make(
            references: source.references, variant: .landscapeCard, maxAspectRatio: nil,
            pinIdentity: source.pinIdentity,
            providerPolicyIdentity: ArtworkResolveKey.policyIdentity(settings ?? source.policy.metadataSettings)
        )
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
}

private actor EpisodeArtworkLoader: ArtworkNetworkFileLoading {
    let data: Data
    init(data: Data) { self.data = data }
    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data { data }
}
#endif
