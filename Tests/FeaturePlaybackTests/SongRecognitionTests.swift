import XCTest

@testable import FeaturePlayback

/// Refs #351: what the background song watch is willing to show.
final class SongRecognitionTests: XCTestCase {
    private let start: TimeInterval = 1_000

    func testSecondSightingThatTracksTheClockConfirms() {
        var confirmation = SongConfirmation()
        XCTAssertFalse(confirmation.confirms(key: "song", offset: 40, at: start))
        XCTAssertTrue(confirmation.confirms(key: "song", offset: 50, at: start + 10))
    }

    func testSightingThatJumpsAroundDoesNotConfirm() {
        var confirmation = SongConfirmation()
        _ = confirmation.confirms(key: "remix", offset: 200, at: start)
        XCTAssertFalse(confirmation.confirms(key: "remix", offset: 13, at: start + 10))
    }

    func testOtherMatchesInBetweenDoNotResetASong() {
        var confirmation = SongConfirmation()
        _ = confirmation.confirms(key: "score", offset: 90, at: start)
        _ = confirmation.confirms(key: "remix", offset: 5, at: start + 4)
        XCTAssertTrue(confirmation.confirms(key: "score", offset: 98, at: start + 8))
    }

    func testStaleSightingDoesNotConfirm() {
        var confirmation = SongConfirmation()
        _ = confirmation.confirms(key: "song", offset: 0, at: start)
        XCTAssertFalse(confirmation.confirms(key: "song", offset: 60, at: start + 60))
    }

    func testConfirmedSongNeedsTwoNewSightingsAgain() {
        var confirmation = SongConfirmation()
        _ = confirmation.confirms(key: "song", offset: 0, at: start)
        XCTAssertTrue(confirmation.confirms(key: "song", offset: 10, at: start + 10))
        XCTAssertFalse(confirmation.confirms(key: "other", offset: 0, at: start + 12))
    }

    func testSoundEffectsAndUntaggedUploadsAreNotSongs() {
        XCTAssertTrue(SongRecognizer.isSong(title: "Something In The Way", genres: ["Alternative", "Music"]))
        XCTAssertFalse(SongRecognizer.isSong(title: "Vengeance", genres: []))
        XCTAssertFalse(SongRecognizer.isSong(title: "Sounds of the Movie Theater", genres: ["Electronic"]))
        XCTAssertFalse(SongRecognizer.isSong(title: "Thunder", genres: ["Sound Effects"]))
    }
}
