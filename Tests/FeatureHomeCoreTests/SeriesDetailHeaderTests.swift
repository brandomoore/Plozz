import CoreModels
import XCTest
@testable import FeatureHomeCore

final class SeriesDetailHeaderTests: XCTestCase {
    func testSeriesSubjectDoesNotFollowEpisodeSeasonOrResumeSelection() {
        let show = series()
        for kind in [MediaItemKind.episode, .season, .series] {
            for watched in [false, true] {
                var selection = child(kind: kind)
                selection.isPlayed = watched
                selection.resumePosition = watched ? nil : 120
                let original = selection
                let subject = HeroContentPolicy.detailSubject(focused: selection, root: show)
                XCTAssertEqual(subject, show)
                XCTAssertEqual(selection, original, "Header selection must not mutate playback or episode metadata.")
                let header = HeroPresentation(item: subject, artworkStyle: .landscape, surface: .detail)
                XCTAssertEqual(HeroContentPolicy.detailDescription(focused: header, root: header), show.overview)
                XCTAssertEqual(HeroContentPolicy.ratings(focused: header, root: header), show.ratings)
                XCTAssertFalse(SpoilerSettings(isEnabled: true).shouldHideText(for: subject))
            }
        }
    }

    func testMissingSeriesMetadataNeverBorrowsEpisodeMetadata() {
        let show = MediaItem(id: "show", title: "Show", kind: .series)
        let subject = HeroContentPolicy.detailSubject(focused: child(), root: show)
        XCTAssertNil(subject.overview)
        XCTAssertTrue(subject.ratings.isEmpty)
        XCTAssertNil(subject.officialRating)
    }

    func testEpisodeAndMoviePagesKeepTheirOwnSubjects() {
        for kind in [MediaItemKind.episode, .movie] {
            let item = child(kind: kind)
            XCTAssertEqual(HeroContentPolicy.detailSubject(focused: item, root: item), item)
        }
    }

    func testSwitchingServersUsesOnlyTheActiveSeriesMetadata() {
        var alternate = series()
        alternate.sourceAccountID = "another-account"
        alternate.overview = "The alternate server's synopsis."
        alternate.ratings = []
        let subject = HeroContentPolicy.detailSubject(focused: child(), root: alternate)
        XCTAssertEqual(subject.sourceAccountID, alternate.sourceAccountID)
        XCTAssertEqual(subject.overview, alternate.overview)
        XCTAssertTrue(subject.ratings.isEmpty)
    }

    func testParentSeedUsesScopedSeriesTextAndNeverChildScoresOrStill() throws {
        for kind in [MediaItemKind.episode, .season] {
            var item = child(kind: kind)
            item.seriesSynopsis = MediaSeriesSynopsis(series: series())
            item.posterURL = try XCTUnwrap(URL(string: "https://fixture.invalid/episode-still"))
            item.seriesPosterURL = try XCTUnwrap(URL(string: "https://fixture.invalid/series-poster"))
            item.fallbackArtworkURL = try XCTUnwrap(URL(string: "https://fixture.invalid/series-backdrop"))
            let seed = SeriesEpisodeEntry.seriesSeed(
                from: item, seriesID: "show", sourceAccountID: "account"
            )
            XCTAssertEqual(seed.id, "show")
            XCTAssertEqual(seed.kind, .series)
            XCTAssertEqual(seed.title, "Village stories")
            XCTAssertEqual(seed.overview, series().overview)
            XCTAssertTrue(seed.ratings.isEmpty)
            XCTAssertNil(seed.officialRating)
            XCTAssertNil(seed.resumePosition)
            XCTAssertNil(seed.episodeNumber)
            XCTAssertEqual(seed.posterURL, item.seriesPosterURL)
            XCTAssertEqual(seed.backdropURL, item.fallbackArtworkURL)
            XCTAssertFalse(seed.artworkReferences(for: .detailBackdrop).contains(.remote(try XCTUnwrap(item.posterURL))))
        }
    }

    func testMissingOrMismatchedParentSynopsisIsNotReused() {
        var item = child()
        for (parentID, account) in [("show", "account"), ("other", "account"), ("show", "other")] {
            item.seriesSynopsis = nil
            XCTAssertNil(SeriesEpisodeEntry.seriesSeed(
                from: item, seriesID: parentID, sourceAccountID: account
            ).overview)
            item.seriesSynopsis = MediaSeriesSynopsis(series: series())
            let seed = SeriesEpisodeEntry.seriesSeed(from: item, seriesID: parentID, sourceAccountID: account)
            XCTAssertEqual(seed.overview, parentID == "show" && account == "account" ? series().overview : nil)
        }
        item.parentTitle = nil
        XCTAssertEqual(SeriesEpisodeEntry.seriesSeed(from: item, seriesID: "show", sourceAccountID: "account").title, "")
    }

    private func series() -> MediaItem {
        MediaItem(
            id: "show", title: "Village stories", kind: .series,
            overview: "A quiet village beside the ocean.",
            ratings: [.init(source: .imdb, value: 8.7, scale: .outOfTen)],
            sourceAccountID: "account"
        )
    }

    private func child(kind: MediaItemKind = .episode) -> MediaItem {
        MediaItem(
            id: "child", title: "The secret", kind: kind, overview: "The murderer is revealed.",
            parentTitle: "Village stories", episodeNumber: 2, officialRating: "TV-MA",
            seriesID: "show", ratings: [.init(source: .imdb, value: 2.3, scale: .outOfTen)],
            sourceAccountID: "account"
        )
    }
}
