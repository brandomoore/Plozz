#if canImport(UIKit)
import CoreModels
import Observation
import UIKit
import XCTest
@testable import CoreUI
@testable import FeatureHome

@MainActor
final class HeroForegroundRatingsStateTests: XCTestCase {
    func testHomeCopyUsesTheWideLogoBudgetAtEveryTextSizeWithoutResizingActions() throws {
        let foreground = HeroForegroundUIView(frame: CGRect(x: 0, y: 0, width: 1500, height: 850))
        defer { foreground.stopContinuousUpdates() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 100))
        }
        foreground.apply(HeroForegroundModel(
            itemID: "wide-logo", title: "Wide logo", logoURL: nil, metadataText: "Drama", ratingBadgeText: nil,
            scheduleLine: nil, overview: String(repeating: "Across the stars. ", count: 40),
            ratings: [], familyGuidanceAge: nil,
            pills: [.init(kind: .play, text: "Play", systemImage: "play.fill", progress: nil)],
            selectedIndex: 0, heroFocused: false, dots: nil
        ), logo: HeroUIKitLogo(image: image, isMonochrome: false, needsHalo: false, isDark: false, coverage: 0.32),
           metadataVisible: true, slideChanged: false)
        foreground.layoutIfNeeded()
        let overview = try XCTUnwrap(foreground.subviews.compactMap { $0 as? UILabel }.first {
            $0.text?.hasPrefix("Across the stars.") == true
        })
        let logo = try XCTUnwrap(foreground.subviews.compactMap { $0 as? UIImageView }.first)
        let pills = try XCTUnwrap(foreground.subviews.first { $0.subviews.contains { $0 is HeroForegroundPillView } })
        let buttonsFrame = pills.frame
        for size in HeroLogoSize.allSizes {
            for text in HeroTextSize.allSizes {
                foreground.logoSize = size
                foreground.textSize = text
                foreground.layoutIfNeeded()
                XCTAssertEqual(overview.frame.width, 496 * max(1, size.scale), accuracy: 1)
                if size.scale >= 1 {
                    XCTAssertEqual(overview.frame.maxX, logo.frame.maxX, accuracy: 1)
                }
                XCTAssertEqual(overview.frame.minX, logo.frame.minX)
                XCTAssertEqual(pills.frame, buttonsFrame)
            }
        }
        foreground.frame.size.width = 600
        foreground.layoutIfNeeded()
        XCTAssertEqual(overview.frame.width, 540)
        XCTAssertEqual(logo.frame.maxX, overview.frame.maxX, accuracy: 1)
    }

    func testPersistentForegroundScalesTextAndBordersWithoutMovingOrResizingButtons() throws {
        let foreground = HeroForegroundUIView(frame: CGRect(x: 0, y: 0, width: 1500, height: 850))
        defer { foreground.stopContinuousUpdates() }
        foreground.apply(HeroForegroundModel(
            itemID: "size-fixture", title: "NORTHSTAR", logoURL: nil,
            metadataText: "Drama", ratingBadgeText: "PG", scheduleLine: "Upcoming",
            overview: String(repeating: "An expedition beyond the stars. ", count: 20), ratings: [], familyGuidanceAge: nil,
            pills: [.init(kind: .play, text: "Play", systemImage: "play.fill", progress: nil)],
            selectedIndex: 0, heroFocused: false, dots: nil
        ), logo: nil, metadataVisible: true, slideChanged: false)
        foreground.layoutIfNeeded()
        let labels = foreground.subviews.compactMap { $0 as? UILabel }
        let certificate = try XCTUnwrap(labels.first { $0.text == "PG" })
        let description = try XCTUnwrap(labels.first { $0.text?.hasPrefix("An expedition beyond the stars.") == true })
        let metadata = try XCTUnwrap(labels.first { $0.text == "Drama" })
        let schedule = try XCTUnwrap(labels.first { $0.text == "Upcoming" })
        let title = try XCTUnwrap(labels.first { $0.text == "NORTHSTAR" })
        let pills = try XCTUnwrap(foreground.subviews.first { $0.subviews.contains { $0 is HeroForegroundPillView } })
        let buttonsFrame = pills.frame
        for rawValue in [-5, 5, 0] {
            foreground.textSize = HeroTextSize(rawValue: rawValue)
            foreground.layoutIfNeeded()
            let scale = CGFloat(foreground.textSize.scale)
            let metadataScale = PlozzTypography.heroMetadataScale(local: foreground.textSize.scale)
            XCTAssertEqual(description.font.pointSize, 24 * scale)
            let paragraph = try XCTUnwrap(
                description.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            )
            XCTAssertEqual(paragraph.lineSpacing, 3 * scale)
            XCTAssertEqual(description.numberOfLines, rawValue > 0 ? 4 : 3)
            XCTAssertEqual(description.frame.height,
                           description.font.lineHeight * CGFloat(description.numberOfLines)
                           + paragraph.lineSpacing * CGFloat(description.numberOfLines - 1), accuracy: 1)
            XCTAssertEqual(metadata.font.pointSize, 23 * metadataScale)
            XCTAssertEqual(title.font.pointSize, 64 * scale)
            XCTAssertEqual(certificate.font.pointSize, 18 * metadataScale)
            XCTAssertEqual(certificate.layer.borderWidth, 3 * metadataScale)
            XCTAssertEqual(certificate.frame.height, 36 * metadataScale)
            XCTAssertEqual(schedule.font.pointSize, 24 * metadataScale)
            XCTAssertEqual(schedule.frame.height, 52 * metadataScale)
            XCTAssertEqual(pills.frame, buttonsFrame)
            XCTAssertGreaterThanOrEqual(schedule.frame.minY, 0)
            XCTAssertLessThanOrEqual(metadata.frame.maxY, description.frame.minY)
        }
        foreground.appTextScale = 1.25
        foreground.layoutIfNeeded()
        XCTAssertEqual(description.font.pointSize, 30)
        XCTAssertEqual(pills.frame, buttonsFrame)
    }

    func testEnlargedCertificateDoesNotCrowdTheGenresOutOfTheFeaturedHero() throws {
        let foreground = HeroForegroundUIView(frame: CGRect(x: 0, y: 0, width: 1500, height: 850))
        defer { foreground.stopContinuousUpdates() }
        let facts = "2000  ·  Comedy  ·  Family  ·  Mystery"
        foreground.apply(HeroForegroundModel(
            itemID: "genre-fit", title: "Series", logoURL: nil,
            metadataText: facts, ratingBadgeText: "TV-G", scheduleLine: nil,
            overview: nil, ratings: [], familyGuidanceAge: nil, pills: [],
            selectedIndex: 0, heroFocused: false, dots: nil
        ), logo: nil, metadataVisible: true, slideChanged: false)
        foreground.textSize = HeroTextSize(rawValue: 5)
        foreground.appTextScale = MetadataBadgeSpacing.textScale(for: .accessibility5)
        foreground.layoutIfNeeded()
        let labels = foreground.subviews.compactMap { $0 as? UILabel }
        let genres = try XCTUnwrap(labels.first { $0.text == facts })
        let certificate = try XCTUnwrap(labels.first { $0.text == "TV-G" })
        let untruncated = UILabel()
        untruncated.text = facts
        untruncated.font = genres.font
        untruncated.numberOfLines = 0
        let required = untruncated.sizeThatFits(CGSize(width: genres.bounds.width, height: .greatestFiniteMagnitude))
        XCTAssertGreaterThan(genres.frame.minX, certificate.frame.maxX)
        XCTAssertLessThanOrEqual(genres.frame.maxX, foreground.bounds.width)
        XCTAssertLessThanOrEqual(required.height, genres.bounds.height + 1)
    }

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
