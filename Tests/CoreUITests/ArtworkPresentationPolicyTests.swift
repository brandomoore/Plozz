import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ArtworkPresentationPolicyTests: XCTestCase {
    func testSharedRowLayoutsResolveIndependentPageScopes() {
        for (view, area) in [
            (CardCaptionView.home, ArtworkArea.homeRows),
            (.recommended, .recommended), (.browse, .browse),
            (.collections, .collections), (.playlists, .playlists), (.watchlist, .watchlist),
            (.episodes, .episodes), (.search, .search)
        ] {
            var environment = EnvironmentValues()
            environment.plozzCardCaptionView = view
            environment.plozzArtworkSettings = .init(overrides: [area: .online])
            XCTAssertEqual(environment.plozzArtworkPolicy.area, area)
            XCTAssertTrue(environment.plozzArtworkPolicy.prefersOnlineArtwork)
        }
    }

    func testHomeAndLibraryHeroesDoNotUseTheirRowsOrEachOthersChoice() {
        let settings = ArtworkSettings(overrides: [.home: .online, .recommended: .online])
        let home = ArtworkPresentationPolicy(area: .homeRows, settings: settings)
        let library = home.forArea(.recommended)
        XCTAssertFalse(home.prefersOnlineArtwork)
        XCTAssertEqual(home.heroPolicy.area, .home)
        XCTAssertTrue(home.heroPolicy.prefersOnlineArtwork)
        XCTAssertTrue(library.prefersOnlineArtwork)
        XCTAssertEqual(library.heroPolicy.area, .recommendedHero)
        XCTAssertFalse(library.heroPolicy.prefersOnlineArtwork)
        XCTAssertEqual(library.heroPolicy.heroPolicy, library.heroPolicy)
    }

    func testContinueWatchingRowScopeDoesNotDependOnItsParentPage() {
        for view in [CardCaptionView.home, .recommended] {
            var environment = EnvironmentValues()
            environment.plozzCardCaptionView = view
            environment.plozzArtworkSettings = .init(overrides: [.continueWatching: .library])
            environment.plozzArtworkArea = .continueWatching
            let policy = environment.plozzArtworkPolicy
            XCTAssertEqual(policy.area, .continueWatching)
            XCTAssertFalse(policy.prefersOnlineArtwork)
            XCTAssertFalse(policy.prefersTextlessArtwork)
            let episode = EpisodeArtworkSource(
                item: .init(id: "episode", title: "Episode", kind: .episode),
                spoilerSettings: .default, policy: policy
            )
            XCTAssertEqual(episode.policy.area, .continueWatching)
        }
    }

    #if canImport(UIKit)
    func testCancellingPendingProviderLookupReturnsWithoutWaitingForItsAnswer() async throws {
        let lookup = PolicyOnlineGate()
        let returned = expectation(description: "Cancelled artwork returns promptly")
        let task = Task {
            let result = await ArtworkFirstPaintResolver.resolve(
                references: [], variant: .posterCard,
                asyncOnlineURL: { await lookup.lookup() }, prefersOnlineArtwork: true
            )
            returned.fulfill()
            return result
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await lookup.requests == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await lookup.requests
        XCTAssertEqual(requests, 1)
        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        await lookup.finish()
        let result = await task.value
        XCTAssertNil(result)
    }
    #endif

    func testAreaOverrideChangesSelectionWithoutChangingProviderPermissions() {
        var settings = ArtworkSettings(preference: .online)
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
        let online = EpisodeArtworkSource(
            item: item, spoilerSettings: .default,
            policy: .init(area: .episodes, settings: .init(preference: .online))
        )
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
        XCTAssertFalse(source.policy.prefersOnlineArtwork)
        let providerFirst = MediaArtworkSource(
            item: item, placement: .poster,
            policy: .init(area: .browse, settings: .init(preference: .online))
        )
        XCTAssertTrue(providerFirst.policy.prefersOnlineArtwork)
        XCTAssertNotEqual(source.policy.identity, providerFirst.policy.identity)
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
            .remote(selected)
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
        for preference in [ArtworkPreference.recommended, .library, .online] {
            let policy = ArtworkPresentationPolicy(
                area: .browse, settings: .init(preference: preference)
            )
            let result = await ArtworkFirstPaintResolver.resolve(
                references: [.networkFile(reference)], variant: .landscapeCard,
                asyncOnlineURL: { await online.lookup() },
                prefersOnlineArtwork: policy.prefersOnlineArtwork
            )
            XCTAssertEqual(result?.reference, .networkFile(reference))
            let count = await online.requests
            XCTAssertEqual(count, preference == .online ? 1 : 0)
        }
    }

    func testLibraryFirstStillLooksUpMissingArtwork() async {
        let online = PolicyOnlineProbe()
        let result = await ArtworkFirstPaintResolver.resolve(
            references: [], variant: .posterCard,
            asyncOnlineURL: { await online.lookup() },
            prefersOnlineArtwork: false
        )
        XCTAssertNil(result)
        let count = await online.requests
        XCTAssertEqual(count, 1)
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

private actor PolicyOnlineGate {
    private(set) var requests = 0
    private var continuation: CheckedContinuation<URL?, Never>?

    func lookup() async -> URL? {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
