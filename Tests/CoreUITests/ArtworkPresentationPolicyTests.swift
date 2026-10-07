import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ArtworkPresentationPolicyTests: XCTestCase {
    func testAreaOverrideChangesSelectionWithoutChangingProviderPermissions() {
        var settings = ArtworkSettings()
        settings.setOverride(.library, for: .continueWatching)
        let providers = MetadataProviderSettings(
            orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]
        )
        let home = ArtworkPresentationPolicy(area: .home, settings: settings, providers: providers)
        let resume = home.forArea(.continueWatching)
        XCTAssertTrue(home.prefersOnlineArtwork)
        XCTAssertFalse(resume.prefersOnlineArtwork)
        XCTAssertFalse(resume.prefersTextlessArtwork)
        XCTAssertEqual(resume.providers, providers)
        XCTAssertEqual(resume.metadataSettings.disabledOrder, ["tmdb"])
        XCTAssertNotEqual(home.identity, resume.identity)
        XCTAssertEqual(home.identity, home.forArea(.search).identity)
    }

    func testCaptionContextAndExplicitAreaSelectTheCorrectOverride() {
        var environment = EnvironmentValues()
        var settings = ArtworkSettings(preference: .library)
        settings.setOverride(.online, for: .search)
        environment.plozzArtworkSettings = settings
        environment.plozzCardCaptionView = .search
        XCTAssertEqual(environment.plozzArtworkPolicy.area, .search)
        XCTAssertTrue(environment.plozzArtworkPolicy.prefersOnlineArtwork)
        environment.plozzArtworkArea = .details
        XCTAssertFalse(environment.plozzArtworkPolicy.prefersOnlineArtwork)
        environment.plozzArtworkArea = nil
        XCTAssertTrue(environment.plozzArtworkPolicy.prefersOnlineArtwork)
    }

    func testEpisodePreparationDoesNotReuseAnOppositeProfileChoice() {
        let item = MediaItem(id: "episode", title: "Episode", kind: .episode)
        let online = EpisodeArtworkSource(item: item, spoilerSettings: .default)
        let library = EpisodeArtworkSource(
            item: item, spoilerSettings: .default,
            policy: .init(area: .episodes, settings: .init(preference: .library))
        )
        XCTAssertNotEqual(online.requestIdentity, library.requestIdentity)
        var providers = MetadataProviderSettings.default
        providers.orderMode = .custom
        providers.disabledOrder = ["tmdb"]
        let disabled = EpisodeArtworkSource(
            item: item, spoilerSettings: .default,
            policy: .init(area: .episodes, providers: providers)
        )
        XCTAssertNotEqual(online.requestIdentity, disabled.requestIdentity)
    }

    func testBrowseIncludesAnOnlineLookupEvenWhenTheLibraryHasArtwork() {
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie,
            posterURL: URL(string: "https://library.example.test/poster.jpg")
        )
        XCTAssertNotNil(CardArtworkPolicy.standard.posterFallback(for: item))
        XCTAssertNil(CardArtworkPolicy.extra.posterFallback(for: item))
        XCTAssertNil(CardArtworkPolicy.standard.posterFallback(
            for: MediaItem(id: "folder", title: "Folder", kind: .folder)
        ))
        let source = MediaArtworkSource(item: item, placement: .poster, policy: .init(area: .browse))
        XCTAssertEqual(source.references, item.artworkReferences(for: .poster))
        XCTAssertNotNil(source.fallbackURL)
        XCTAssertTrue(source.policy.prefersOnlineArtwork)
    }

    func testBackdropSourcesRespectPerAreaLibraryOverrides() throws {
        let selected = try XCTUnwrap(URL(string: "https://library.example.test/selected.jpg"))
        let alternate = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://library.example.test/alternate.jpg")))
        let item = MediaItem(
            id: "series", title: "Series", kind: .series, heroBackdropURL: selected,
            artworkSelections: [.init(placement: .detailBackdrop, references: [alternate, .remote(selected)])]
        )
        var settings = ArtworkSettings()
        settings.setOverride(.library, for: .details)
        let policy = ArtworkPresentationPolicy(area: .home, settings: settings)
        XCTAssertEqual(
            MediaArtworkSource(item: item, placement: .detailBackdrop, policy: policy.forArea(.details)).references.first,
            .remote(selected)
        )
        XCTAssertEqual(
            MediaArtworkSource(item: item, placement: .detailBackdrop, policy: policy.forArea(.playback)).references.first,
            alternate
        )
        #if os(tvOS)
        let detail = DetailBackdropArtworkSource(item: item, policy: policy)
        let recommended = DetailBackdropArtworkSource(item: item, policy: .init())
        XCTAssertEqual(detail.references.first, .remote(selected))
        XCTAssertEqual(recommended.references.first, alternate)
        XCTAssertNotEqual(detail.key, recommended.key)
        XCTAssertNotEqual(detail.previewKey, recommended.previewKey)
        #endif
    }

    #if canImport(UIKit)
    func testLibraryFirstUsesSuppliedNetworkFileWithoutAnOnlineLookup() async throws {
        let reference = try NetworkArtworkReference(
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
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let loader = PolicyArtworkLoader(data: try XCTUnwrap(image.pngData()))
        ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { ArtworkImageCache.shared.configure(networkFileService: nil) }
        let online = PolicyOnlineProbe()
        for preference in [ArtworkPreference.library, .online] {
            let policy = ArtworkPresentationPolicy(
                area: .continueWatching, settings: .init(preference: preference)
            )
            let result = await ArtworkFirstPaintResolver.resolve(
                references: [.networkFile(reference)], variant: .landscapeCard,
                asyncOnlineURL: { await online.lookup() }, maximumOnlineWait: 2,
                prefersOnlineArtwork: policy.prefersOnlineArtwork
            )
            XCTAssertEqual(result?.reference, .networkFile(reference))
            let count = await online.requests
            XCTAssertEqual(count, preference == .library ? 0 : 1)
        }
    }
    #endif
}

#if canImport(UIKit)
private struct PolicyArtworkLoader: ArtworkNetworkFileLoading {
    let data: Data
    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data { data }
}
#endif

private actor PolicyOnlineProbe {
    private(set) var requests = 0
    func lookup() -> URL? {
        requests += 1
        return nil
    }
}
