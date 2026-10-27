#if canImport(UIKit)
import CoreModels
import XCTest
@testable import CoreUI

@MainActor
final class YouTubeTrailerOpeningTests: XCTestCase {
    private let trailer = MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "Trailer")

    func testSuccessfulAppHandoffDoesNotOpenBrowser() async {
        var requests: [URL] = []
        let opener = YouTubeTrailerOpening { requests.append($0); return true }
        await opener.open(trailer)
        XCTAssertEqual(requests, [trailer.youTubeTrailerAppURL!])
        XCTAssertFalse(opener.failed)
    }

    func testUnavailableAppUsesBrowserOnlyOnMobile() async {
        var requests: [URL] = []
        let opener = YouTubeTrailerOpening { url in
            requests.append(url)
            return url.scheme == "https"
        }
        await opener.open(trailer)
        #if os(tvOS)
        XCTAssertEqual(requests, [trailer.youTubeTrailerAppURL!])
        XCTAssertTrue(opener.failed)
        #else
        XCTAssertEqual(requests, [trailer.youTubeTrailerAppURL!, trailer.youTubeTrailerWatchURL!])
        XCTAssertFalse(opener.failed)
        #endif
    }

    func testFailedHandoffIsVisibleAndRetryCanSucceed() async {
        var succeeds = false
        let opener = YouTubeTrailerOpening { _ in succeeds }
        await opener.open(trailer)
        XCTAssertTrue(opener.failed)
        succeeds = true
        await opener.open(trailer)
        XCTAssertFalse(opener.failed)
    }

    func testInvalidTrailerCannotBecomeAnInternalPlaybackOrArbitraryURL() async {
        let opener = YouTubeTrailerOpening { _ in XCTFail("Invalid link must not open"); return true }
        await opener.open(MediaItem.youTubeTrailer(videoID: "bad&v=other", title: "Trailer"))
        XCTAssertTrue(opener.failed)
    }

    func testCancelledHandoffDoesNotOpenAnything() async {
        let opener = YouTubeTrailerOpening { _ in XCTFail("Cancelled link must not open"); return true }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await opener.open(trailer)
        }
        await task.value
        XCTAssertFalse(opener.failed)
    }
}
#endif
