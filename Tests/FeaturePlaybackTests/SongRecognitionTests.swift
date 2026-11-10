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
        XCTAssertEqual(links.map(\.service), [.spotify, .appleMusic, .youtubeMusic, .amazonMusic, .deezer, .tidal])
        XCTAssertEqual(links.first { $0.service == .appleMusic }?.url, song.appleMusicURL)
        let paths: [(SongServiceLink.Service, String)] = [
            (.spotify, "open.spotify.com"), (.amazonMusic, "music.amazon.com"),
            (.deezer, "www.deezer.com"), (.tidal, "listen.tidal.com")
        ]
        for (service, host) in paths {
            let url = try XCTUnwrap(links.first { $0.service == service }?.url)
            XCTAssertEqual(url.host, host)
            XCTAssertEqual(url.deletingLastPathComponent().path, "/search")
            XCTAssertEqual(url.lastPathComponent, "A/B? & #夏 Artist + guest")
            XCTAssertNil(url.query)
        }
        let youtube = try XCTUnwrap(URLComponents(
            url: XCTUnwrap(links.first { $0.service == .youtubeMusic }?.url), resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(youtube.host, "music.youtube.com")
        XCTAssertEqual(youtube.path, "/search")
        XCTAssertEqual(youtube.queryItems, [URLQueryItem(name: "q", value: "A/B? & #夏 Artist + guest")])
        let encodedSearch = try XCTUnwrap(youtube.percentEncodedQueryItems?.first?.value)
        XCTAssertEqual(encodedSearch.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                       "A/B? & #夏 Artist + guest", "Form-style query decoding must preserve a literal plus.")
        XCTAssertTrue(links.allSatisfy { $0.url.scheme == "https" && $0.url.fragment == nil })
        let withoutApple = SongMatch(title: "Song", artist: nil, artworkURL: nil, appleMusicURL: nil)
        let searches = SongServiceLink.links(for: withoutApple)
        XCTAssertEqual(searches.map(\.service), [.spotify, .youtubeMusic, .amazonMusic, .deezer, .tidal])
        XCTAssertTrue(searches.filter { $0.service != .youtubeMusic }.allSatisfy { $0.url.lastPathComponent == "Song" })
        let titleOnly = try XCTUnwrap(searches.first { $0.service == .youtubeMusic }?.url)
        XCTAssertEqual(URLComponents(url: titleOnly, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "q", value: "Song")])
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
