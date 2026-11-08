import XCTest
import CoreModels

@testable import FeaturePlayback

/// Refs #351: what the background song watch is willing to show.
final class SongRecognitionTests: XCTestCase {
    private let start: TimeInterval = 1_000

    func testMusicServiceSearchesPreserveTitleAndArtistWithoutInventingTrackIDs() throws {
        let song = SongMatch(title: "A/B? & #夏", artist: "Artist + guest", artworkURL: nil,
                             appleMusicURL: URL(string: "https://music.apple.com/album/example?i=123"))
        let links = SongServiceLink.links(for: song)
        XCTAssertEqual(links.map(\.service), [.appleMusic, .spotify, .youtube])
        XCTAssertEqual(links[0].url, song.appleMusicURL)
        XCTAssertEqual(links[1].url.host, "open.spotify.com")
        XCTAssertEqual(links[1].url.lastPathComponent, "A/B? & #夏 Artist + guest")
        let youtube = try XCTUnwrap(URLComponents(url: links[2].url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(youtube.host, "www.youtube.com")
        XCTAssertEqual(youtube.queryItems, [URLQueryItem(name: "search_query", value: "A/B? & #夏 Artist + guest")])
        XCTAssertTrue(links.allSatisfy { $0.url.scheme == "https" && $0.url.fragment == nil })
        let withoutApple = SongMatch(title: "Song", artist: nil, artworkURL: nil, appleMusicURL: nil)
        XCTAssertEqual(SongServiceLink.links(for: withoutApple).map(\.service), [.spotify, .youtube])
    }

    func testOfflineModeDoesNotStartARecognitionSession() async {
        let previous = OfflineMode.shared.isEnabled
        OfflineMode.shared.setEnabled(true)
        defer { OfflineMode.shared.setEnabled(previous) }
        let reason = await SongRecognizer.watch(
            AsyncStream { $0.finish() },
            makeSession: {
                XCTFail("Offline playback must not contact song recognition.")
                return .init()
            },
            report: { _ in XCTFail("Offline recognition must not publish matches.") }
        )
        XCTAssertEqual(reason, .ended)
    }

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
