import XCTest
import CoreModels
@testable import FeatureHomeCore

@MainActor
final class HeroDirectTrailerSourceTests: XCTestCase {
    private let direct = MediaItem.directTrailer(fromURL: "https://cdn.trailer.example/dune.mp4", title: "T")!

    func testDirectTrailerBecomesHeroSourceWithMeasuredDuration() async {
        let source = await FastHeroTrailerResolver.directSource(
            from: [MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "YT"), direct],
            ownerItemID: "m1", duration: { _ in 158 }
        )
        XCTAssertEqual(source?.ownerItemID, "m1")
        XCTAssertEqual(source?.trailerItemID, direct.id)
        XCTAssertEqual(source?.url.absoluteString, "https://cdn.trailer.example/dune.mp4")
        XCTAssertEqual(source?.duration, 158)
    }

    func testNoSourceWhenNoDirectTrailerOrYouTubeOnly() async {
        var probed = false
        let none = await FastHeroTrailerResolver.directSource(
            from: [MediaItem.youTubeTrailer(videoID: "dQw4w9WgXcQ", title: "YT")],
            ownerItemID: "m1", duration: { _ in probed = true; return 10 }
        )
        XCTAssertNil(none)
        XCTAssertFalse(probed, "YouTube must never be probed")
        let empty = await FastHeroTrailerResolver.directSource(from: [], ownerItemID: "m1", duration: { _ in 10 })
        XCTAssertNil(empty)
    }

    func testNoSourceWhenStreamDurationCannotBeRead() async {
        let source = await FastHeroTrailerResolver.directSource(
            from: [direct], ownerItemID: "m1", duration: { _ in nil }
        )
        XCTAssertNil(source, "A dead or expired link must fall through, not autoplay")
    }
}
