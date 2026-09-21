import CoreModels
import XCTest
@testable import MetadataKit

final class HeroRequestIdentityTests: XCTestCase {
    func testHeroResolvesOnlyTheRequestIDUsingTheDetailPipeline() async {
        let provider = FakeEnrichmentProvider(
            id: .tvdb,
            capabilities: [.externalIDs, .canonicalText, .poster, .backdrop],
            output: MetadataEnrichment(externalIDs: [
                "Tmdb": SourcedValue(value: "42", source: .tvdb)
            ])
        )
        let resolver = ExternalTitleMetadataResolver(
            pipeline: MetadataEnrichmentPipeline(providers: [provider])
        )
        let item = MediaItem(
            id: "tvmaze:series:9", title: "A show", kind: .series,
            providerIDs: ["Tvdb": "17"], discoverySources: [.tvmaze],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let id = await resolver.tmdbID(for: item)
        XCTAssertEqual(id, "42")
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls.first?.missing, [.providerID("Tmdb")])
        XCTAssertEqual(provider.calls.first?.query.providerIDs["Tvdb"], "17")
        XCTAssertEqual(provider.calls.first?.query.kind, .series)
    }

    func testKnownAliasesPersonalMediaAndUnsupportedKindsDoNotStartLookups() async {
        let provider = FakeEnrichmentProvider(
            id: .tvdb, capabilities: [.externalIDs], output: MetadataEnrichment()
        )
        let resolver = ExternalTitleMetadataResolver(
            pipeline: MetadataEnrichmentPipeline(providers: [provider])
        )
        for key in ["Tmdb", "tmdb", "TMDB"] {
            let item = MediaItem(id: "known", title: "Known", kind: .movie, providerIDs: [key: "42"])
            let id = await resolver.tmdbID(for: item)
            XCTAssertEqual(id, "42")
        }
        var personal = MediaItem(id: "personal", title: "Personal", kind: .movie)
        personal.allowsTitleBasedMetadataMatching = false
        let episode = MediaItem(id: "episode", title: "Episode", kind: .episode)
        for item in [personal, episode] {
            let id = await resolver.tmdbID(for: item)
            XCTAssertNil(id)
        }
        XCTAssertEqual(provider.callCount, 0)
    }

    func testInvalidOrAbsentResolvedIDsCannotEnableRequests() async {
        for value in ["0", "-1", "not-an-id", ""] {
            let provider = FakeEnrichmentProvider(
                id: .tvdb, capabilities: [.externalIDs],
                output: MetadataEnrichment(externalIDs: [
                    "Tmdb": SourcedValue(value: value, source: .tvdb)
                ])
            )
            let resolver = ExternalTitleMetadataResolver(
                pipeline: MetadataEnrichmentPipeline(providers: [provider])
            )
            let id = await resolver.tmdbID(for: MediaItem(
                id: "external", title: "Movie", kind: .movie
            ))
            XCTAssertNil(id, value)
        }
    }
}
