#if canImport(SwiftUI)
import CoreModels
import XCTest
@testable import CoreUI

@MainActor
final class DetailInformationConsolidationTests: XCTestCase {
    private let audience = ExternalRating(source: .rottenTomatoesAudience, value: 88, scale: .percent)
    private let critics = ExternalRating(source: .rottenTomatoes, value: 96, scale: .percent)
    private let imdb = ExternalRating(source: .imdb, value: 7.9, scale: .outOfTen)
    private let tmdb = ExternalRating(source: .tmdb, value: 8.1, scale: .outOfTen)

    func testGuidancePagesKeepQualitySeparateFromContentTopics() {
        let summary = FamilyGuidanceSummary(recommendedAge: 14, qualityRating: 5)
        let guidance = FamilyGuidance(
            summary: summary,
            topics: [.init(id: "language", label: "Language", rating: 0,
                           explanation: "No strong language.", isPositive: false)],
            talkingPoints: ["A family discussion."]
        )
        XCTAssertEqual(FamilyGuidancePage.pages(summary: summary, guidance: guidance),
                       [.overview, .topic("language"), .reviews, .discussion])
        XCTAssertEqual(FamilyGuidancePage.topic("language").topic(in: guidance)?.rating, 0)
        let ageOnly = FamilyGuidanceSummary(recommendedAge: 14, qualityRating: nil)
        XCTAssertEqual(FamilyGuidancePage.pages(summary: ageOnly, guidance: nil), [.overview])
        XCTAssertNil(FamilyGuidancePage.topic("missing").topic(in: guidance))
    }

    private func item(overview: String? = "The series synopsis.") -> MediaItem {
        var item = MediaItem(id: "show", title: "The show", kind: .series)
        item.overview = overview
        item.ratings = [imdb, audience]
        return item
    }

    func testDefaultKeepsTheExistingCompleteInformation() {
        let sections = DetailInformationSections(item: item(), horizontalInset: 22)
        XCTAssertTrue(sections.hasAbout)
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testRepeatedSummaryDoesNotRemoveAnyRatings() {
        let sections = DetailInformationSections(
            item: item(), horizontalInset: 22,
            overviewAlreadyShown: "  The series synopsis.\n"
        )
        XCTAssertFalse(sections.hasAbout)
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testDifferentSeriesSummaryAndScoresRemainAccessible() {
        let sections = DetailInformationSections(
            item: item(), horizontalInset: 22,
            overviewAlreadyShown: "A different episode synopsis."
        )
        XCTAssertTrue(sections.hasAbout)
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testTwoRatingHeaderLeavesAllFourScoresInFullInformation() {
        var title = item()
        title.ratings = [tmdb, imdb, critics, audience]
        let headerRatings = DetailPageSettings.default.headerRatings(
            from: title.ratings, isAnime: false, hidesRatings: false
        )
        XCTAssertEqual(headerRatings, [audience, critics])
        let sections = DetailInformationSections(item: title, horizontalInset: 22)
        XCTAssertEqual(sections.sortedRatings, [critics, audience, imdb, tmdb])
        XCTAssertTrue(headerRatings.allSatisfy(sections.sortedRatings.contains))
    }

    func testSpoilerSettingsStillControlTheFullRatingPresentation() {
        var title = item()
        title.isPlayed = false
        let spoilers = SpoilerSettings(hideRatingsUntilWatched: true)
        XCTAssertTrue(spoilers.shouldHideRatings(for: title))
        XCTAssertTrue(DetailPageSettings.default.headerRatings(
            from: title.ratings, isAnime: false, hidesRatings: spoilers.shouldHideRatings(for: title)
        ).isEmpty)
        let sections = DetailInformationSections(
            item: title, horizontalInset: 22, spoilerSettings: spoilers
        )
        // Scores remain available to the existing spoiler-protected tiles, not discarded.
        XCTAssertEqual(sections.sortedRatings, [audience, imdb])
    }

    func testMissingDescriptionsDoNotCreateAnAboutSection() {
        for overview in [nil, "", " \n "] as [String?] {
            let sections = DetailInformationSections(
                item: item(overview: overview), horizontalInset: 22,
                overviewAlreadyShown: nil
            )
            XCTAssertFalse(sections.hasAbout)
        }
    }

    func testFamilyGuidanceKeepsRatingsSectionVisibleWithoutOtherScores() {
        let summary = FamilyGuidanceSummary(recommendedAge: 14, qualityRating: 3)
        let title = MediaItem(id: "film", title: "Fixture", kind: .movie, familyGuidance: summary)
        let sections = DetailInformationSections(item: title, horizontalInset: 22)
        XCTAssertTrue(sections.hasRatings)
        XCTAssertTrue(sections.sortedRatings.isEmpty)
        XCTAssertEqual(sections.familyGuidanceSummary, summary)
    }

    func testFamilyGuidanceIsNotPresentedAsAnEpisodeSpecificRating() {
        let title = MediaItem(id: "episode", title: "Fixture", kind: .episode,
                              familyGuidance: .init(recommendedAge: 14, qualityRating: 3))
        let sections = DetailInformationSections(item: title, horizontalInset: 22)
        XCTAssertFalse(sections.hasRatings)
        XCTAssertNil(sections.familyGuidanceSummary)
    }
}
#endif
