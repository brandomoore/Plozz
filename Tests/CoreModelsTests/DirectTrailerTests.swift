import XCTest
import CoreModels

final class DirectTrailerTests: XCTestCase {
    func testMP4HLSAndExtensionlessSignedURLsAreDirectTrailers() {
        for url in [
            "https://cdn.trailer.example/movie.mp4",
            "http://192.168.1.2/media/trailer.m3u8?token=abc",
            "https://cdn.trailer.example/videoplayback?expire=1893456000&sig=xyz",
        ] {
            let trailer = MediaItem.directTrailer(fromURL: url, title: "Trailer")
            XCTAssertEqual(trailer?.directTrailerURL?.absoluteString, url, url)
            XCTAssertEqual(trailer?.isDirectTrailer, true)
            XCTAssertEqual(trailer?.isTrailer, true)
            XCTAssertEqual(trailer?.isYouTubeTrailer, false)
            XCTAssertEqual(trailer?.isServerItemTrailer, false)
            XCTAssertEqual(trailer?.kind, .video)
        }
    }

    func testYouTubeWebPagesAndNonHTTPLinksAreRejected() {
        for url in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/channel/abc",
            "https://example.test/trailer.html",
            "https://example.test/watch.php?id=1",
            "ftp://example.test/trailer.mp4",
            "file:///tmp/trailer.mp4",
            "javascript:alert(1)",
            "/relative/trailer.mp4",
            "not a url",
            "",
        ] {
            XCTAssertNil(MediaItem.directTrailer(fromURL: url, title: "Trailer"), url)
        }
    }

    func testUnmarkedAndTamperedItemsAreNeverDirect() {
        XCTAssertFalse(MediaItem(id: "m", title: "Dune", kind: .movie).isDirectTrailer)
        var tampered = MediaItem(id: "x", title: "T", kind: .video)
        tampered.providerIDs[MediaItem.directTrailerProviderKey] = "https://example.test/page.html"
        XCTAssertNil(tampered.directTrailerURL)
        XCTAssertTrue(tampered.isServerItemTrailer)
    }

    func testLocalAndYouTubeTrailersAreNotDirect() {
        XCTAssertTrue(MediaItem(id: "t1", title: "Trailer", kind: .video).isServerItemTrailer)
        XCTAssertFalse(MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "T").isServerItemTrailer)
    }

    func testPolicyTreatsDirectTrailersAsServerSourced() {
        let direct = MediaItem.directTrailer(fromURL: "https://cdn.example/t.mp4", title: "T")!
        XCTAssertTrue(TrailerSourcePolicy.serverOnly.allows(direct))
        XCTAssertTrue(TrailerSourcePolicy.serverAndYouTube.allows(direct))
        XCTAssertFalse(TrailerSourcePolicy.off.allows(direct))
    }
}
