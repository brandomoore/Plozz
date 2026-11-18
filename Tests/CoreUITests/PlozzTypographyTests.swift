import CoreModels
@testable import CoreUI
import XCTest

final class PlozzTypographyTests: XCTestCase {
    func testSharedDescriptionDefaultsAndPlatformAdjustmentRange() {
        XCTAssertEqual(PlozzTypography.heroDescription.pointSize, 24)
        XCTAssertEqual(PlozzTypography.heroDescription.lineSpacing, 3)
        XCTAssertEqual(PlozzTypography.detailDescriptionLines, 4)
        #if os(tvOS)
        XCTAssertEqual(PlozzTypography.heroDescription.scaled(by: HeroTextSize(rawValue: -5).scale).pointSize, 18)
        XCTAssertEqual(PlozzTypography.heroDescription.scaled(by: HeroTextSize(rawValue: 5).scale).pointSize, 36)
        #endif
    }

    func testAppAndLocalAdjustmentsComposeOnceForEverySemanticStyle() {
        let scale = PlozzTypography.scale(local: 1.5, app: 1.2)
        XCTAssertEqual(scale, 1.8, accuracy: 0.0001)
        for style in [PlozzTypography.heroDescription, PlozzTypography.heroMetadata, PlozzTypography.heroFallbackTitle,
                      PlozzTypography.heroCredit, PlozzTypography.heroSchedule,
                      PlozzTypography.episodeTitle, PlozzTypography.episodeDescription] {
            let resolved = style.scaled(by: scale)
            XCTAssertEqual(resolved.pointSize, style.pointSize * 1.8, accuracy: 0.0001)
            XCTAssertEqual(resolved.lineSpacing, style.lineSpacing * 1.8, accuracy: 0.0001)
        }
    }

    func testEpisodeDescriptionsMatchHeroTextAtEveryTVAdjustment() {
        #if os(tvOS)
        for step in -5...5 {
            for appScale in [CGFloat(1), CGFloat(1.2)] {
                let scale = PlozzTypography.scale(local: HeroTextSize(rawValue: step).scale, app: appScale)
                let description = PlozzTypography.episodeDescription.scaled(by: scale)
                XCTAssertEqual(description, PlozzTypography.heroDescription.scaled(by: scale))
                XCTAssertGreaterThan(PlozzTypography.episodeTitle.scaled(by: scale).pointSize,
                                     description.pointSize)
            }
        }
        #else
        XCTAssertEqual(PlozzTypography.episodeDescription.pointSize, 20)
        XCTAssertEqual(PlozzTypography.episodeDescription.lineSpacing, 2)
        #endif
    }

    func testHeightIncludesEveryInterlineGapAndScrimCoversTheLargerBlock() {
        let style = PlozzTypography.heroDescription.scaled(by: 1.5)
        XCTAssertEqual(style.height(lineHeight: 43, lines: 4), 185.5)
        let baseline = PlozzTypography.heroScrimScale(textScale: 1, logoSize: .default, lines: 4)
        let maximum = PlozzTypography.heroScrimScale(textScale: 1.5, logoSize: .default, lines: 4)
        XCTAssertGreaterThan(baseline, 1)
        XCTAssertEqual(maximum / baseline, 1.5, accuracy: 0.0001)
    }
}
