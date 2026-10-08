#if canImport(SwiftUI)
import XCTest
import SwiftUI
import CoreModels
@testable import CoreUI

final class PlozzMetricsTests: XCTestCase {
    func testTouchCardsUseProportionateBadgesAndCaptionSpacing() {
        let touch = PlozzMetrics.touch(density: .standard)
        let tv = PlozzMetrics.standard
        XCTAssertEqual(touch.watchedBadgeSize, 21)
        XCTAssertEqual(touch.folderNavigationBadgeSize, 36)
        XCTAssertEqual(tv.watchedBadgeSize, PlozzTheme.Metrics.watchedBadgeSize)
        XCTAssertEqual(tv.posterArtworkCornerRadius, PlozzTheme.Metrics.posterArtCornerRadius)
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics.touch(density: density)
            XCTAssertGreaterThanOrEqual(metrics.watchedBadgeSize, 20)
            XCTAssertEqual(metrics.posterCaptionTopSpacing, 4)
            for focus in CardFocusStyle.allCases {
                XCTAssertEqual(metrics.focusCaptionPush(for: focus), 0)
            }
            let small = metrics.scalingPosters(by: 0.6)
            XCTAssertEqual(small.posterCardCornerRadius, small.posterArtworkCornerRadius + small.cardInset)
        }
    }

    func testTouchPosterAndContinueWatchingCornersMatchAtEveryDensityAndWidth() {
        for density in UIDensity.allCases {
            let base = PlozzMetrics.touch(density: density)
            for factor in [CGFloat(0.5), 0.8, 1, 1.4, 2] {
                let metrics = base.scalingPosters(by: factor)
                XCTAssertEqual(metrics.posterArtworkCornerRadius, 12)
                XCTAssertEqual(metrics.landscapeArtworkCornerRadius, 12)
                XCTAssertEqual(metrics.borderlessPosterCornerRadius, 12)
                XCTAssertEqual(metrics.borderlessLandscapeCornerRadius, 12)
                XCTAssertEqual(metrics.posterCardCornerRadius, 12 + metrics.cardInset)
                XCTAssertEqual(metrics.landscapeCardCornerRadius, 12 + metrics.cardInset)
            }
        }
    }

    func testTelevisionArtworkAndBorderlessCornersRemainUnchanged() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics(density: density)
            XCTAssertEqual(metrics.posterArtworkCornerRadius, 16)
            XCTAssertEqual(metrics.landscapeArtworkCornerRadius, 18)
            XCTAssertEqual(metrics.borderlessPosterCornerRadius, 16 + metrics.cardInset)
            XCTAssertEqual(metrics.borderlessLandscapeCornerRadius, 18 + metrics.cardInset)
        }
    }

    func testCaptionHorizontalClearanceDoesNotChangeBottomSpacingOrTelevision() {
        for density in UIDensity.allCases {
            for factor in [CGFloat(0.5), 1, 2] {
                let touch = PlozzMetrics.touch(density: density).scalingPosters(by: factor)
                let tv = PlozzMetrics(density: density).scalingPosters(by: factor)
                XCTAssertEqual(touch.posterCaptionHorizontalInset, 4)
                XCTAssertEqual(touch.landscapeCaptionHorizontalInset, 4)
                XCTAssertEqual(touch.posterCaptionInset, (12 + touch.cardInset) * 0.8 - touch.cardInset)
                XCTAssertEqual(touch.landscapeCaptionInset, touch.posterCaptionInset)
                XCTAssertLessThan(touch.posterCaptionHorizontalInset, touch.posterCaptionInset)
                XCTAssertEqual(tv.posterCaptionHorizontalInset, tv.posterCaptionInset)
                XCTAssertEqual(tv.landscapeCaptionHorizontalInset, tv.landscapeCaptionInset)
                XCTAssertEqual(tv.posterCaptionInset, (16 + tv.cardInset) * 0.8 - tv.cardInset)
                XCTAssertEqual(tv.landscapeCaptionInset, (18 + tv.cardInset) * 0.8 - tv.cardInset)
            }
        }
    }

    func testCaptionEnvironmentResolvesDefaultOverridesAndDestinationScopes() {
        var environment = EnvironmentValues()
        environment.plozzCardCaptionSettings = CardCaptionSettings(
            showsLabels: false, overrides: [.browse: true, .home: false, .extras: true, .episodes: false]
        )
        for view in CardCaptionView.allCases {
            environment.plozzCardCaptionView = view
            XCTAssertEqual(environment.plozzCardCaptionsHidden, view != .browse && view != .extras && view != .episodes)
        }
        environment.plozzCardCaptionsHidden = true
        environment.plozzCardCaptionView = .browse
        XCTAssertFalse(environment.plozzCardCaptionsHidden, "A destination must not inherit its source's forced visibility.")
        environment.plozzCardCaptionsHidden = true
        environment.plozzCardCaptionView = .episodes
        XCTAssertFalse(environment.plozzCardCaptionsHidden, "Episode identity must survive source preferences and old hide overrides.")
    }
    func testStandardMatchesPlozzThemeConstants() {
        let m = PlozzMetrics(density: .standard)
        XCTAssertEqual(m.scale, 1.0)
        XCTAssertEqual(m.posterWidth, PlozzTheme.Metrics.posterWidth)
        XCTAssertEqual(m.landscapeWidth, PlozzTheme.Metrics.landscapeWidth)
        XCTAssertEqual(m.cardSpacing, PlozzTheme.Metrics.cardSpacing)
        XCTAssertEqual(m.gridSpacing, PlozzTheme.Metrics.gridSpacing)
        XCTAssertEqual(m.posterGridColumns, UIDensity.standard.posterGridColumns)
    }

    func testCompactShrinksAndExtraLargeGrows() {
        let compact = PlozzMetrics(density: .compact)
        let standard = PlozzMetrics(density: .standard)
        let extraLarge = PlozzMetrics(density: .extraLarge)

        XCTAssertLessThan(compact.posterWidth, standard.posterWidth)
        XCTAssertGreaterThan(extraLarge.posterWidth, standard.posterWidth)

        XCTAssertLessThan(compact.cardSpacing, standard.cardSpacing)
        XCTAssertGreaterThan(extraLarge.cardSpacing, standard.cardSpacing)

        // Fewer columns at higher density (bigger tiles); more at lower density.
        XCTAssertGreaterThan(compact.posterGridColumns, standard.posterGridColumns)
        XCTAssertLessThan(extraLarge.posterGridColumns, standard.posterGridColumns)
    }

    /// The caption only moves to stay clear of a growing card, so it has to move
    /// further in the style that grows further — and the outlined style must not
    /// budge from what it has always done.
    func testCaptionPushFollowsTheFocusStyle() {
        for density in UIDensity.allCases {
            let m = PlozzMetrics(density: density)
            XCTAssertEqual(m.focusCaptionPush(for: .outlined), m.focusCaptionPush)
            XCTAssertEqual(m.focusCaptionPush(for: .system), m.focusCaptionPush)
            XCTAssertGreaterThan(
                m.focusCaptionPush(for: .highlight),
                m.focusCaptionPush(for: .outlined),
                "highlight grows further, so its caption has to clear further (\(density))"
            )
        }
    }

    func testPosterColumnsCountMatchesDensity() {
        for density in UIDensity.allCases {
            let m = PlozzMetrics(density: density)
            XCTAssertEqual(m.posterColumns.count, density.posterGridColumns)
        }
    }

    func testLibraryDefaultUsesSixColumnsWithoutChangingOtherDensityPresets() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics(density: density)
            XCTAssertEqual(metrics.libraryPosterColumns.count, density == .standard ? 6 : density.posterGridColumns)
            XCTAssertEqual(metrics.posterColumns.count, density.posterGridColumns)
        }
    }

    func testNativeCaptionsShareLibraryRestingAndFocusedClearance() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics(density: density)
            XCTAssertEqual(metrics.nativePosterCaptionSpacing, metrics.landscapeCaptionTopSpacing)
            XCTAssertGreaterThanOrEqual(
                metrics.nativePosterCaptionSpacing, PlozzTheme.Metrics.cardCaptionSpacing
            )
            XCTAssertEqual(
                metrics.nativePosterCaptionFocusTravel,
                max(
                    (PlozzTheme.Metrics.focusCaptionPush * metrics.scale).rounded(),
                    PlozzTheme.Metrics.nativeFocusCaptionMinimumPush
                )
            )
            XCTAssertEqual(
                metrics.focusCaptionPush(for: .system),
                (PlozzTheme.Metrics.focusCaptionPush * metrics.scale).rounded()
            )
        }
    }

    func testLandscapeSlotIncludesBothInsets() {
        let m = PlozzMetrics(density: .standard)
        XCTAssertEqual(m.landscapeCardSlotWidth, m.landscapeWidth + m.cardInset * 2)
    }

    func testCardSlotsExactlyMatchRenderedSurfaceWidths() {
        let metrics = PlozzMetrics.touch(density: .standard)

        XCTAssertEqual(
            metrics.cardSlotWidth(for: .poster, cardStyle: .framed),
            metrics.posterWidth + metrics.cardInset * 2
        )
        XCTAssertEqual(
            metrics.cardSlotWidth(for: .poster, cardStyle: .borderless),
            metrics.posterWidth + metrics.borderlessCardSideMargin * 2
        )
        XCTAssertEqual(
            metrics.cardSlotWidth(for: .landscape, cardStyle: .framed),
            metrics.landscapeWidth + metrics.cardInset * 2
        )
    }

    func testCardStatusCueScalesWithoutBecomingTooSmall() {
        let micro = PlozzMetrics(density: .micro)
        let standard = PlozzMetrics(density: .standard)
        let extraLarge = PlozzMetrics(density: .extraLarge)

        #if os(iOS)
        let minimumFontSize = PlozzTheme.Metrics.cardStatusCueTouchMinFontSize
        let minimumHorizontalPadding =
            PlozzTheme.Metrics.cardStatusCueTouchMinHorizontalPadding
        let minimumVerticalPadding =
            PlozzTheme.Metrics.cardStatusCueTouchMinVerticalPadding
        #else
        let minimumFontSize = PlozzTheme.Metrics.cardStatusCueMinFontSize
        let minimumHorizontalPadding = PlozzTheme.Metrics.cardStatusCueMinHorizontalPadding
        let minimumVerticalPadding = PlozzTheme.Metrics.cardStatusCueMinVerticalPadding
        #endif

        XCTAssertEqual(micro.cardStatusCueFontSize, minimumFontSize)
        XCTAssertGreaterThan(extraLarge.cardStatusCueFontSize, standard.cardStatusCueFontSize)
        XCTAssertGreaterThanOrEqual(
            micro.cardStatusCueHorizontalPadding,
            minimumHorizontalPadding
        )
        XCTAssertGreaterThanOrEqual(
            micro.cardStatusCueVerticalPadding,
            minimumVerticalPadding
        )
    }

    #if os(iOS)
    func testTouchStatusCueUsesCaptionTypographyAndAdaptsToDynamicType() {
        let standard = PlozzMetrics.touch(density: .standard, dynamicTypeSize: .large)
        let accessibility = PlozzMetrics.touch(
            density: .standard,
            dynamicTypeSize: .accessibility1
        )

        XCTAssertLessThan(
            standard.cardStatusCueFontSize,
            PlozzTheme.Metrics.cardStatusCueFontSize
        )
        XCTAssertGreaterThan(
            accessibility.cardStatusCueFontSize,
            standard.cardStatusCueFontSize
        )
    }
    #endif
}
#endif
