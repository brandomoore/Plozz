#if os(tvOS)
import XCTest
import CoreModels
import FeatureHomeCore
@testable import FeatureHome

@MainActor
final class FocusHeroMetadataTests: XCTestCase {
    func testSeriesSynopsisWinsOverNonemptyEpisodeTextWithoutReplacingPlaybackState() async {
        let metadata = FocusHeroMetadata()
        var episode = MediaItem(
            id: "episode", title: "Episode title", kind: .episode,
            overview: "Episode spoiler", taglines: ["Episode tagline"],
            seriesID: "series", resumePosition: 90, sourceAccountID: "account"
        )
        let series = MediaItem(
            id: "series", title: "La serie", kind: .series,
            overview: "Le synopsis du serveur.", sourceAccountID: "account"
        )
        await metadata.load(episode) { items in
            items.map {
                var full = $0
                full.seriesSynopsis = MediaSeriesSynopsis(series: series)
                full.isPlayed = true
                full.resumePosition = 300
                return full
            }
        }
        let presented = metadata.item(for: episode)
        XCTAssertEqual(presented.overview, episode.overview)
        XCTAssertEqual(presented.taglines, episode.taglines)
        XCTAssertEqual(presented.resumePosition, 90)
        XCTAssertFalse(presented.isPlayed)
        XCTAssertEqual(presented.id, episode.id)
        XCTAssertEqual(HeroContentPolicy.homeDescription(
            for: HeroPresentation(item: presented, artworkStyle: .landscape, surface: .home)
        ), series.overview)
        episode.seriesID = "another-series"
        XCTAssertNil(metadata.item(for: episode).seriesSynopsis)
        episode.seriesID = series.id
        episode.sourceAccountID = "another-account"
        XCTAssertNil(metadata.item(for: episode).seriesSynopsis)
    }

    func testCurrentWatchStateAndRoutingWinOverCachedDetails() async {
        let metadata = FocusHeroMetadata()
        var cached = MediaItem(id: "episode", title: "Episode", kind: .episode)
        cached.isPlayed = true
        cached.hasBeenPlayed = true
        cached.resumePosition = 120
        cached.playedPercentage = 0.5
        await metadata.load(cached) {
            $0.map { var item = $0; item.genres = ["Drama"]; return item }
        }
        var current = cached
        current.isPlayed = false
        current.hasBeenPlayed = false
        current.resumePosition = nil
        current.playedPercentage = nil
        current.title = "Current server title"
        let presented = metadata.item(for: current)
        XCTAssertFalse(presented.isPlayed)
        XCTAssertFalse(presented.hasBeenPlayed)
        XCTAssertNil(presented.resumePosition)
        XCTAssertNil(presented.playedPercentage)
        XCTAssertEqual(presented.title, current.title)
        XCTAssertEqual(presented.genres, ["Drama"])
        var spoilers = SpoilerSettings.default
        spoilers.isEnabled = true
        XCTAssertTrue(spoilers.shouldHideText(for: presented))
    }

    func testResolvedEpisodeEnrichesWithoutReplacingSeriesIdentity() async {
        let metadata = FocusHeroMetadata()
        let series = MediaItem(id: "series", title: "Series", kind: .series)
        await metadata.load(series) { _ in
            var episode = MediaItem(id: "next", title: "Next episode", kind: .episode)
            episode.genres = ["Drama"]
            episode.runtime = 1800
            episode.productionYear = 2026
            return [episode]
        }
        let presented = metadata.item(for: series)
        XCTAssertEqual(presented.id, series.id)
        XCTAssertEqual(presented.kind, .series)
        XCTAssertEqual(presented.genres, ["Drama"])
        XCTAssertNil(presented.runtime, "An episode's runtime is not its series' runtime.")
        XCTAssertNil(presented.productionYear)
        XCTAssertTrue(metadata.hasDetails(for: presented))
    }

    func testLiveCuratedMetadataWinsAndSourceChangesDoNotReuseAliasCache() async {
        let metadata = FocusHeroMetadata()
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        item.watchlistAliasID = MediaAliasID()
        item.sourceAccountID = "first"
        await metadata.load(item) {
            $0.map { var full = $0; full.overview = "Old overview"; full.genres = ["Drama"]; return full }
        }
        var current = item
        current.overview = "Curated overview"
        current.genres = ["Comedy"]
        XCTAssertEqual(metadata.item(for: current).overview, current.overview)
        XCTAssertEqual(metadata.item(for: current).genres, current.genres)
        current.sourceAccountID = "second"
        XCTAssertFalse(metadata.hasDetails(for: current))
        XCTAssertNotEqual(FocusHeroMetadata.Key(current), FocusHeroMetadata.Key(item),
                          "A stable alias must restart enrichment after its source changes.")
        current = item
        current.id = "replacement"
        XCTAssertFalse(metadata.hasDetails(for: current))
        XCTAssertNotEqual(FocusHeroMetadata.Key(current), FocusHeroMetadata.Key(item))
    }

    func testHomeInstancesDoNotShareMetadataOrPendingRequests() async {
        let oldHome = FocusHeroMetadata()
        let newHome = FocusHeroMetadata()
        let item = MediaItem(id: "same", title: "Same", kind: .movie)
        let started = expectation(description: "Old profile request started")
        let gate = AsyncStream<Void>.makeStream()
        let pending = Task {
            await oldHome.load(item) { items in
                started.fulfill()
                for await _ in gate.stream { break }
                return items.map { var full = $0; full.genres = ["Old profile"]; return full }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await newHome.load(item) {
            $0.map { var full = $0; full.genres = ["New profile"]; return full }
        }
        pending.cancel()
        gate.continuation.finish()
        await pending.value
        XCTAssertEqual(newHome.item(for: item).genres, ["New profile"])
        XCTAssertFalse(oldHome.hasDetails(for: item))
    }

    func testPrefetchBoundsBatchesAndDeduplicatesAcrossRows() async {
        let metadata = FocusHeroMetadata()
        let recorder = BatchRecorder()
        let items = (0..<20).map { MediaItem(id: "\($0)", title: "\($0)", kind: .movie) }
        await metadata.prefetch([items, items]) { batch in
            await recorder.begin(batch.count)
            await Task.yield()
            await recorder.end()
            return batch
        }
        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.maximumSize, 4)
        XCTAssertEqual(snapshot.itemCount, items.count)
        XCTAssertTrue(items.allSatisfy(metadata.hasDetails(for:)))
    }

    func testIncompleteBatchCanBeRetried() async {
        let metadata = FocusHeroMetadata()
        let item = MediaItem(id: "retry", title: "Retry", kind: .movie)
        await metadata.load(item) { _ in [] }
        XCTAssertFalse(metadata.hasDetails(for: item))
        await metadata.load(item) { $0 }
        XCTAssertTrue(metadata.hasDetails(for: item))
    }
}

private actor BatchRecorder {
    var active = 0
    var maximumActive = 0
    var maximumSize = 0
    var itemCount = 0

    func begin(_ count: Int) {
        active += 1
        maximumActive = max(maximumActive, active)
        maximumSize = max(maximumSize, count)
        itemCount += count
    }

    func end() { active -= 1 }

    func snapshot() -> (maximumActive: Int, maximumSize: Int, itemCount: Int) {
        (maximumActive, maximumSize, itemCount)
    }
}
#endif
