import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class OnlineTrailerSourceTests: XCTestCase {
    func testDefaultSelectionUsesValidMetadataLinkWithoutCheckingEmbedding() async {
        let selected = await ItemDetailViewModel.defaultPlayableVideoIDResolver([
            "invalid-id", "dQw4w9WgXcQ", "aqz-KE-bpKQ"
        ])
        XCTAssertEqual(selected, "dQw4w9WgXcQ")
    }

    func testDefaultSelectionRejectsMalformedLinks() async {
        let selected = await ItemDetailViewModel.defaultPlayableVideoIDResolver([
            "", "invalid-id", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        ])
        XCTAssertNil(selected)
    }

    func testUnsupportedAndPersonalItemsDoNotLookUpOnlineTrailers() async {
        let episode = await OnlineTrailerSource.trailers(for: MediaItem(
            id: "episode", title: "Episode", kind: .episode
        ))
        let personal = await OnlineTrailerSource.trailers(for: MediaItem(
            id: "personal", title: "Birthday", kind: .video,
            allowsTitleBasedMetadataMatching: false
        ))
        XCTAssertTrue(episode.isEmpty)
        XCTAssertTrue(personal.isEmpty)
    }
}
