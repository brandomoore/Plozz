#if canImport(UIKit)
import CoreModels
import Observation
import XCTest
@testable import FeatureHome

@MainActor
final class HeroForegroundRatingsStateTests: XCTestCase {
    func testAgeOnlyUpdatesPublishAndClearWithoutAReviewScoreChange() async {
        let state = HeroForegroundRatingsState()
        let update = expectation(description: "Age metadata publishes")
        withObservationTracking {
            _ = state.familyGuidanceAge
        } onChange: {
            update.fulfill()
        }
        state.update([], familyGuidanceAge: 14)
        await fulfillment(of: [update], timeout: 0.1)
        XCTAssertEqual(state.familyGuidanceAge, 14)
        state.update([])
        XCTAssertNil(state.familyGuidanceAge, "A different slide or hidden ratings clears the age.")
        state.update([], familyGuidanceAge: 14)
        let unchanged = expectation(description: "Unchanged age does not publish")
        unchanged.isInverted = true
        withObservationTracking {
            _ = state.familyGuidanceAge
        } onChange: {
            unchanged.fulfill()
        }
        for _ in 0..<100 { state.update([], familyGuidanceAge: 14) }
        await fulfillment(of: [unchanged], timeout: 0.05)
    }

    func testFocusAndDwellReapplicationsDoNotInvalidateRatings() async {
        let state = HeroForegroundRatingsState()
        let ratings = [ExternalRating(source: .imdb, value: 8, scale: .outOfTen)]
        state.update(ratings)
        let invalidation = expectation(description: "Unchanged ratings must not rebuild")
        invalidation.isInverted = true
        withObservationTracking {
            _ = state.ratings
        } onChange: {
            invalidation.fulfill()
        }

        for _ in 0..<100 { state.update(ratings) }

        await fulfillment(of: [invalidation], timeout: 0.05)
        XCTAssertEqual(state.ratings, ratings)
    }

    func testRatingUpdatesStillInvalidateAndPreserveOrder() async {
        let state = HeroForegroundRatingsState()
        let invalidation = expectation(description: "New ratings publish")
        withObservationTracking {
            _ = state.ratings
        } onChange: {
            invalidation.fulfill()
        }
        let ratings = [
            ExternalRating(source: .imdb, value: 8, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 92, scale: .percent)
        ]
        state.update(ratings)
        await fulfillment(of: [invalidation], timeout: 0.1)
        XCTAssertEqual(state.ratings, ratings)

        state.update([])
        XCTAssertTrue(state.ratings.isEmpty, "Spoiler or slide changes must clear old ratings")
    }
}
#endif
