import CoreGraphics
import CoreModels
@testable import CoreUI
import XCTest

final class SeeAllPopupPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let card = CGSize(width: 560, height: 400)

    func testPrefersTrailingSideWhenItFits() {
        let anchor = CGRect(x: 200, y: 300, width: 300, height: 450)
        let frame = SeeAllPopupPlacement.frame(card: card, anchor: anchor, bounds: bounds, isRightToLeft: false)
        XCTAssertEqual(frame.minX, anchor.maxX + SeeAllPopupPlacement.gap)
    }

    func testFallsBackToLeadingSideWhenTrailingOverflows() {
        let anchor = CGRect(x: 1500, y: 300, width: 300, height: 450)
        let frame = SeeAllPopupPlacement.frame(card: card, anchor: anchor, bounds: bounds, isRightToLeft: false)
        XCTAssertEqual(frame.maxX, anchor.minX - SeeAllPopupPlacement.gap)
    }

    func testRightToLeftTrailingSideIsTheLeft() {
        let anchor = CGRect(x: 1000, y: 300, width: 300, height: 450)
        let frame = SeeAllPopupPlacement.frame(card: card, anchor: anchor, bounds: bounds, isRightToLeft: true)
        XCTAssertEqual(frame.maxX, anchor.minX - SeeAllPopupPlacement.gap)
    }

    func testStaysOnScreenVerticallyAndWhenNeitherSideFits() {
        let narrow = CGRect(x: 0, y: 0, width: 700, height: 600)
        let anchor = CGRect(x: 200, y: 520, width: 300, height: 450)
        let frame = SeeAllPopupPlacement.frame(card: card, anchor: anchor, bounds: narrow, isRightToLeft: false)
        XCTAssertTrue(narrow.contains(frame))
    }

    func testSpoilerRulesHideEpisodeTextAndRatings() {
        var episode = MediaItem(id: "e", title: "The Twist", kind: .episode)
        episode.overview = "Everyone dies."
        episode.episodeNumber = 5
        episode.ratings = [ExternalRating(source: .imdb, value: 9, scale: .outOfTen)]
        let spoilers = SpoilerSettings(isEnabled: true, hideRatingsUntilWatched: true)
        let hidden = SeeAllPopupContent(item: episode, spoilers: spoilers)
        XCTAssertNil(hidden.overview)
        XCTAssertNotNil(hidden.titleResource)
        XCTAssertTrue(hidden.ratings.isEmpty)

        episode.isPlayed = true
        let shown = SeeAllPopupContent(item: episode, spoilers: spoilers)
        XCTAssertEqual(shown.overview, "Everyone dies.")
        XCTAssertNil(shown.titleResource)
        XCTAssertEqual(shown.ratings.count, 1)
    }
}
