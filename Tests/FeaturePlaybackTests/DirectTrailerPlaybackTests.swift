#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// A direct remote trailer (AIOMetadata / Trailer.io) plays from its own URL:
/// no provider lookup, no server credentials, and a normal engine route.
final class DirectTrailerPlaybackTests: XCTestCase {
    private func prefetch(_ item: MediaItem?, itemID: String? = nil) -> PlayerViewModel.PrefetchedPlayback? {
        PlayerViewModel.directTrailerPrefetch(
            item: item, itemID: itemID ?? item?.id ?? "",
            kind: { EngineSelection.route(request: $0, plozzigenAvailable: true) }
        )
    }

    func testMP4TrailerBuildsDirectPlayRequestFromItsURL() throws {
        let item = try XCTUnwrap(MediaItem.directTrailer(fromURL: "https://cdn.trailer.example/dune.mp4?expire=1", title: "T"))
        let playback = try XCTUnwrap(prefetch(item))
        XCTAssertEqual(playback.request.streamURL?.absoluteString, "https://cdn.trailer.example/dune.mp4?expire=1")
        XCTAssertFalse(playback.request.isTranscoding)
        XCTAssertFalse(playback.request.isManifestStream)
        XCTAssertEqual(playback.request.deliveryMode, .directPlay)
        XCTAssertEqual(playback.request.startPosition, 0)
        XCTAssertNil(playback.request.sourceProvider, "No Jellyfin/Plex session may be attached")
        XCTAssertNil(playback.request.playSessionID)
        XCTAssertEqual(playback.itemID, item.id)
    }

    func testHLSTrailerIsTreatedAsManifestStream() throws {
        let item = try XCTUnwrap(MediaItem.directTrailer(fromURL: "https://cdn.trailer.example/t/master.m3u8", title: "T"))
        let playback = try XCTUnwrap(prefetch(item))
        XCTAssertTrue(playback.request.isManifestStream)
    }

    func testNativeEngineIsUsedWhenAlternateEngineIsUnavailable() throws {
        let item = try XCTUnwrap(MediaItem.directTrailer(fromURL: "https://cdn.trailer.example/dune.mp4", title: "T"))
        let playback = PlayerViewModel.directTrailerPrefetch(
            item: item, itemID: item.id,
            kind: { EngineSelection.route(request: $0, plozzigenAvailable: false) }
        )
        XCTAssertEqual(playback?.engineKind, .native)
    }

    func testOrdinaryLocalYouTubeMissingAndMismatchedItemsAreNotIntercepted() {
        XCTAssertNil(prefetch(MediaItem(id: "t1", title: "Local trailer", kind: .video).markingAsTrailer()))
        XCTAssertNil(prefetch(MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "YT")))
        XCTAssertNil(prefetch(nil, itemID: "x"))
        let direct = MediaItem.directTrailer(fromURL: "https://cdn.trailer.example/dune.mp4", title: "T")
        XCTAssertNil(prefetch(direct, itemID: "some-other-item"))
    }
}
#endif
