import CoreModels
import XCTest

@testable import FeaturePlayback

/// #388: the caption on a Continue Watching card in the player.
final class ContinueWatchingCaptionTests: XCTestCase {
    func testEpisodeShowsSeasonEpisodeAndTimeLeft() {
        var item = MediaItem(id: "e", title: "Episode", kind: .episode)
        item.seasonNumber = 1
        item.episodeNumber = 2
        item.runtime = 51 * 60
        item.resumePosition = 22 * 60
        XCTAssertEqual(PlayerSequencePanel.continueWatchingCaption(item), "S1, E2 · 29m left")
    }

    func testFilmShowsWholeHoursWithoutZeroMinutes() {
        var item = MediaItem(id: "m", title: "Film", kind: .movie)
        item.runtime = 2 * 3600 + 30
        item.resumePosition = 30
        XCTAssertEqual(PlayerSequencePanel.continueWatchingCaption(item), "2h left")
    }

    func testUnstartedTitleShowsItsLengthAndNoProgressWord() {
        var item = MediaItem(id: "m", title: "Film", kind: .movie)
        item.runtime = 90 * 60
        XCTAssertEqual(PlayerSequencePanel.continueWatchingCaption(item), "1h 30m")
        XCTAssertNil(PlayerSequencePanel.continueWatchingCaption(MediaItem(id: "x", title: "X", kind: .movie)))
    }
}
