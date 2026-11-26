#if canImport(SwiftUI)
import XCTest
import SwiftUI
import CoreModels
@testable import CoreUI

final class PlozzMetricsTests: XCTestCase {
    #if os(iOS)
    func testPosterGridFillsWholeColumnsAtWindowAndCalendarWidths() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics.touch(density: density)
            for style in CardStyle.allCases {
                for viewport: CGFloat in [320, 390, 482, 700, 834, 842, 1194] {
                    let pageInset: CGFloat = viewport < 600 ? 22 : 36
                    let inset = PlozziOSMediaRailLayout.artworkAlignedInset(pageInset, metrics: metrics, cardStyle: style)
                    let width = viewport - 2 * inset
                    let layout = PlozziOSPosterGridLayout(contentWidth: width, metrics: metrics, cardStyle: style)
                    let slot = layout.metrics.cardSlotWidth(for: .poster, cardStyle: style)
                    XCTAssertEqual(
                        CGFloat(layout.columns) * slot + CGFloat(layout.columns - 1) * layout.spacing,
                        width, accuracy: 0.001
                    )
                    XCTAssertEqual(
                        layout.metrics.posterHeight / layout.metrics.posterWidth,
                        metrics.posterHeight / metrics.posterWidth, accuracy: 0.001
                    )
                    XCTAssertGreaterThan(layout.metrics.posterWidth, 0)
                    let margin = (slot - layout.metrics.posterWidth) / 2
                    XCTAssertEqual(inset + margin, pageInset, accuracy: 0.001)
                }
            }
        }
    }
    #endif
    func testSettingsControlLabelsUseTheNavigationBodyFont() {
        XCTAssertEqual(SettingsRowMetrics.titleFont, Font.body)
        #if os(tvOS)
        XCTAssertEqual(SettingsRowMetrics.optionFont, SettingsRowMetrics.titleFont)
        XCTAssertEqual(SettingsRowMetrics.helperFont, SettingsRowMetrics.descriptionFont)
        XCTAssertEqual(SettingsRowMetrics.descriptionFont, Font.caption)
        #else
        XCTAssertEqual(SettingsRowMetrics.descriptionFont, Font.footnote)
        #endif
        XCTAssertGreaterThan(SettingsRowMetrics.segmentedTrackInset, 0)
        XCTAssertLessThan(SettingsRowMetrics.segmentedTrackInset, SettingsRowMetrics.verticalPadding(.primary))
    }

    func testContainedSettingsFocusCornersAreConcentricWithTheirGroup() {
        XCTAssertGreaterThan(SettingsRowMetrics.formGroupInset, 0)
        #if os(tvOS)
        let groupRadius = SettingsFormMetrics.groupCornerRadius
        XCTAssertEqual(SettingsFormMetrics.groupInset, 16)
        XCTAssertEqual(SettingsRowMetrics.formGroupInset, SettingsFormMetrics.groupInset)
        XCTAssertEqual(SettingsRowMetrics.formRowCornerRadius, 12)
        XCTAssertEqual(SettingsFormMetrics.headingInset, 28)
        #else
        let groupRadius = PlozzTheme.Metrics.Radius.card
        #endif
        XCTAssertEqual(
            SettingsRowMetrics.formRowCornerRadius + SettingsRowMetrics.formGroupInset,
            groupRadius
        )
        XCTAssertGreaterThan(SettingsRowMetrics.formSectionSpacing, SettingsRowMetrics.formRowSpacing)
    }

    func testStandaloneSettingsLinksKeepTheirRoundedContainerShape() {
        XCTAssertEqual(SettingsRowMetrics.navigationCornerRadius, SettingsFormMetrics.groupCornerRadius)
        XCTAssertEqual(SettingsRowMetrics.navigationCornerRadius, 28)
        XCTAssertEqual(SettingsFormMetrics.navigationRowSpacing, 8)
        XCTAssertEqual(SettingsFormMetrics.dividerFocusClearance, 8)
        XCTAssertEqual(SettingsFormMetrics.illustratedGroupSpacing, 16)
        XCTAssertEqual(SettingsRowMetrics.iconTitleInset, 58)
    }

    func testPortraitRowsKeepTheSameVisibleFractionWithEitherNavigation() {
        for density in UIDensity.allCases {
            let metrics = PlozzMetrics(density: density)
            for cardStyle in CardStyle.allCases {
                for viewportWidth: CGFloat in [1536, 1776, 1840] {
                    for leadingInset: CGFloat in [0, 32] {
                        let slot = metrics.portraitRowSlotWidth(
                            viewportWidth: viewportWidth, leadingInset: leadingInset, cardStyle: cardStyle
                        )
                        let margin = cardStyle == .borderless ? metrics.borderlessCardSideMargin : metrics.cardInset
                        let artworkLeading = leadingInset + (cardStyle == .framed ? metrics.cardInset : 0)
                        let whole = floor((viewportWidth - artworkLeading) / (slot + metrics.cardSpacing))
                        if density == .standard { XCTAssertEqual(whole, 6) }
                        let lastCardStart = artworkLeading + whole * (slot + metrics.cardSpacing)
                        XCTAssertEqual(
                            (viewportWidth - lastCardStart) / (slot - 2 * margin),
                            0.25, accuracy: 0.0001
                        )
                    }

                }
            }
        }
        XCTAssertEqual(PlozzTheme.Metrics.portraitRowVisibleCards, 6.25)
        XCTAssertEqual(PlozzMetrics.standard.libraryPosterColumns.count, 6)
        XCTAssertEqual(PlozzMetrics.standard.posterWidth, 280)
    }

    func testLandscapeRowPeekAcrossCombinedDensityAndTextSizes() {
        for density in UIDensity.allCases {
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
                let base = PlozzMetrics(density: density, dynamicTypeSize: textSize)
                for style in CardStyle.allCases {
                    for series in [false, true] {
                        for width: CGFloat in [1536, 1776, 1840] {
                            let leading: CGFloat = 32
                            let metrics = base.fittingLandscapeRow(
                                viewportWidth: width, leadingInset: leading, cardStyle: style, showsSeriesArtwork: series
                            )
                            let slot = metrics.cardSlotWidth(for: .landscape, cardStyle: style, showsSeriesArtwork: series)
                            let pitch = slot + metrics.cardSpacing
                            let available = width - leading - (style == .framed ? metrics.cardInset : 0)
                            let count = floor(available / pitch)
                            let surface = slot - 2 * (style == .borderless ? metrics.borderlessCardSideMargin : metrics.cardInset)
                            XCTAssertGreaterThanOrEqual(count, 1)
                            XCTAssertEqual((available - count * pitch) / surface, 0.25, accuracy: 0.0001)
                            if series, base.continueWatchingWidth > (base.landscapeWidth * ContinueWatchingCardShape.widthScale).rounded() {
                                XCTAssertGreaterThanOrEqual(metrics.continueWatchingWidth + 0.001, base.continueWatchingWidth)
                            }
                        }
                    }
                }
            }
        }
    }

    func testIncreasingDensityDoesNotShrinkPinnedContinueWatchingArtwork() {
        let widths = UIDensity.allCases.map {
            PlozzMetrics(density: $0).fittingLandscapeRow(
                viewportWidth: 1776, leadingInset: 0, cardStyle: .borderless, showsSeriesArtwork: true
            ).continueWatchingWidth
        }
        XCTAssertEqual(widths, widths.sorted())
    }

    #if os(tvOS)
    func testTVTextSizeReflowsHomeRailsAndScalesHeadingsAtEveryDensity() {
        let sizes: [DynamicTypeSize] = [.large, .xLarge, .xxLarge, .xxxLarge, .accessibility1,
                                        .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        let viewport: CGFloat = 1776
        for density in UIDensity.allCases {
            let steps = sizes.map { PlozzMetrics(density: density, dynamicTypeSize: $0) }
            for (smaller, larger) in zip(steps, steps.dropFirst()) {
                XCTAssertGreaterThan(larger.sectionHeaderFontSize, smaller.sectionHeaderFontSize)
            }
            XCTAssertGreaterThan(steps.last!.cardStatusCueFontSize, steps[0].cardStatusCueFontSize)
            for style in CardStyle.allCases {
                let posters = steps.map { m in
                    let slot = m.portraitRowSlotWidth(viewportWidth: viewport, leadingInset: 0, cardStyle: style)
                    let margin = style == .framed ? m.cardInset : m.borderlessCardSideMargin
                    let available = viewport - (style == .framed ? m.cardInset : 0)
                    let pitch = slot + m.cardSpacing
                    XCTAssertEqual(available - floor(available / pitch) * pitch, (slot - 2 * margin) / 4, accuracy: 0.001)
                    return slot
                }
                // Libraries use ordinary landscape cards, not the Continue Watching target.
                let libraries = steps.map {
                    $0.fittingLandscapeRow(viewportWidth: viewport, leadingInset: 0, cardStyle: style,
                                           showsSeriesArtwork: false).landscapeWidth
                }
                for widths in [posters, libraries] {
                    XCTAssertEqual(widths, widths.sorted())
                    XCTAssertGreaterThan(widths.last!, widths[0])
                }
            }
        }
        let featured = sizes.map {
            FeaturedCardLayout.rail(viewportWidth: viewport, television: true,
                                    textWidthScale: PlozzMetrics(density: .standard, dynamicTypeSize: $0).railTextWidthScale)
        }
        XCTAssertGreaterThan(featured.last!.size.width, featured[0].size.width)
        for (size, gap) in featured {
            let pitch = size.width + gap
            let available = viewport - PlozzTheme.Metrics.screenPadding
            XCTAssertEqual(available - floor(available / pitch) * pitch, size.width / 4, accuracy: 0.001)
        }
    }
    #endif

    func testRailCanParkAtAPartialFinalSlotWithoutLosingTheLeadingStop() {
        XCTAssertEqual(RowSlotTargets.slot(for: 0, pitch: 366, maximum: 105), 0)
        XCTAssertEqual(RowSlotTargets.slot(for: 102, pitch: 366, maximum: 105), 105)
        XCTAssertEqual(RowSlotTargets.slot(for: 550, pitch: 400, maximum: 550), 550)
        XCTAssertEqual(RowSlotTargets.slot(for: 601, pitch: 400, maximum: 550), 550)
        XCTAssertEqual(RowSlotTargets.slot(for: 402, pitch: 400, maximum: 550), 400)
    }

    func testPortraitRowSizingPreservesDensityAndUnmeasuredFallback() {
        let widths = UIDensity.allCases.map {
            PlozzMetrics(density: $0).portraitRowSlotWidth(
                viewportWidth: 1920, leadingInset: 80, cardStyle: .borderless
            )
        }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(Set(widths).count, UIDensity.allCases.count)
        let metrics = PlozzMetrics.standard
        XCTAssertEqual(
            metrics.portraitRowSlotWidth(viewportWidth: 0, leadingInset: 80, cardStyle: .borderless),
            metrics.posterWidth
        )
    }

    func testArtworkSizePreservesCardDimensionsAcrossDensityAndDynamicType() {
        for density in UIDensity.allCases {
            for type in [DynamicTypeSize.large, .accessibility3] {
                for metrics in [PlozzMetrics(density: density, dynamicTypeSize: type),
                                .touch(density: density, dynamicTypeSize: type)] {
                    XCTAssertEqual(metrics.artworkSize(for: .poster),
                                   CGSize(width: metrics.posterWidth, height: metrics.posterHeight))
                    XCTAssertEqual(metrics.artworkSize(for: .landscape),
                                   CGSize(width: metrics.landscapeWidth, height: metrics.landscapeHeight))
                    for details in ContinueWatchingPlaybackDetails.allCases {
                        XCTAssertEqual(metrics.artworkSize(for: .poster, showsSeriesArtwork: true, playbackDetails: details),
                                       CGSize(width: metrics.posterWidth, height: metrics.posterHeight))
                        XCTAssertEqual(details.cardAspectRatio, 2.0 / 3.0)
                        XCTAssertEqual(metrics.artworkSize(for: .landscape, showsSeriesArtwork: true, playbackDetails: details),
                                       CGSize(width: metrics.continueWatchingWidth,
                                              height: (metrics.continueWatchingWidth / ContinueWatchingCardShape.aspectRatio).rounded()))
                    }
                }
            }
        }
    }

    func testAllCardProgressBarsMatchDetailedAcrossDensityAndDynamicType() {
        for density in UIDensity.allCases {
            for type in DynamicTypeSize.allCases {
                for metrics in [PlozzMetrics(density: density, dynamicTypeSize: type),
                                .touch(density: density, dynamicTypeSize: type)] {
                    XCTAssertEqual(metrics.progressBarHeight, metrics.resumeChipBarHeight)
                    XCTAssertGreaterThanOrEqual(metrics.progressBarHeight, 3)
                }
            }
        }
        #if os(tvOS)
        XCTAssertEqual(PlozzMetrics.standard.progressBarHeight, 8)
        #else
        XCTAssertEqual(PlozzMetrics.touch(density: .standard).progressBarHeight, 6)
        #endif
    }

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
            XCTAssertEqual(environment.plozzCardCaptionsHidden, view != .browse && view != .extras)
        }

        environment.plozzCardCaptionsHidden = true
        environment.plozzCardCaptionView = .browse
        XCTAssertFalse(environment.plozzCardCaptionsHidden, "A destination must not inherit its source's forced visibility.")
        environment.plozzCardCaptionsHidden = true
        environment.plozzCardCaptionView = .episodes
        XCTAssertTrue(environment.plozzCardCaptionsHidden, "Episode captions honor the profile's explicit choice.")
    }

    func testCaptionHostingCopyPreservesContextWithoutForcingResolvedDefaults() {
        var source = EnvironmentValues()
        source.plozzCardCaptionView = .home
        var target = EnvironmentValues()
        target.plozzCardCaptionsHidden = true
        target.copyCardCaptionPresentation(from: source)
        XCTAssertFalse(target.plozzCardCaptionsHidden)
        XCTAssertTrue(target.plozzCardCaptionsHiddenWithArtworkTitle)
        source.plozzCardCaptionSettings.preference = .show
        target.copyCardCaptionPresentation(from: source)
        XCTAssertFalse(target.plozzCardCaptionsHiddenWithArtworkTitle)
        source.plozzCardCaptionSettings.preference = .recommended
        source.plozzCardCaptionIsShowcase = true
        target.copyCardCaptionPresentation(from: source)
        XCTAssertTrue(target.plozzCardCaptionsHidden)
        source.plozzCardCaptionSettings.setOverride(.show, for: .home)
        target.copyCardCaptionPresentation(from: source)
        XCTAssertFalse(target.plozzCardCaptionsHiddenWithArtworkTitle)
        source.plozzCardCaptionsHidden = true
        target.copyCardCaptionPresentation(from: source)
        XCTAssertTrue(target.plozzCardCaptionsHidden)
        XCTAssertTrue(target.plozzCardCaptionsHiddenWithArtworkTitle)
    }

    func testContinueWatchingCaptionEnvironmentInheritsParentAndSurvivesNativeHostingCopy() {
        var source = EnvironmentValues()
        source.plozzCardCaptionSettings.setOverride(.show, for: .home)
        source.plozzCardCaptionSettings.setOverride(.hide, for: .recommended)
        for parent in [CardCaptionView.home, .recommended] {
            source.plozzCardCaptionView = parent
            source.plozzCardCaptionSettings.setOverride(.automatic, for: .continueWatching)
            XCTAssertEqual(source.plozzContinueWatchingCaptionsHiddenWithArtworkTitle, parent == .recommended)
            XCTAssertEqual(source.plozzContinueWatchingCaptionsHidden, parent == .recommended)
            source.plozzCardCaptionSettings.setOverride(.show, for: .continueWatching)
            var hosted = EnvironmentValues()
            hosted.copyCardCaptionPresentation(from: source)
            XCTAssertFalse(hosted.plozzContinueWatchingCaptionsHiddenWithArtworkTitle)
            XCTAssertFalse(hosted.plozzContinueWatchingCaptionsHidden)
            XCTAssertEqual(hosted.plozzCardCaptionsHiddenWithArtworkTitle, parent == .recommended)
            source.plozzCardCaptionSettings.setOverride(.hide, for: .continueWatching)
            hosted.copyCardCaptionPresentation(from: source)
            XCTAssertTrue(hosted.plozzContinueWatchingCaptionsHiddenWithArtworkTitle)
            XCTAssertTrue(hosted.plozzContinueWatchingCaptionsHidden)
            XCTAssertEqual(hosted.plozzCardCaptionsHiddenWithArtworkTitle, parent == .recommended)
        }
        source.plozzCardCaptionSettings = .default
        source.plozzCardCaptionView = .home
        XCTAssertFalse(source.plozzContinueWatchingCaptionsHidden)
        XCTAssertTrue(source.plozzContinueWatchingCaptionsHiddenWithArtworkTitle)
    }

    func testPortraitPlaybackDetailsSurviveHostingWithoutChangingLabels() {
        var source = EnvironmentValues()
        XCTAssertEqual(source.plozzContinueWatchingPlaybackDetails, .detailed)
        source.plozzCardCaptionSettings.setOverride(.show, for: .continueWatching)
        var hosted = EnvironmentValues()
        for details in ContinueWatchingPlaybackDetails.allCases {
            source.plozzContinueWatchingPlaybackDetails = details
            hosted.copyHostedPresentation(from: source)
            XCTAssertEqual(hosted.plozzContinueWatchingPlaybackDetails, details)
            XCTAssertFalse(hosted.plozzContinueWatchingCaptionsHiddenWithArtworkTitle)
        }
    }

    func testShowcaseOnlyChangesInheritedLabelsAndDoesNotLeakIntoDestinations() {
        var environment = EnvironmentValues()
        environment.plozzCardCaptionView = .home
        XCTAssertFalse(environment.plozzCardCaptionsHidden)
        environment.plozzCardCaptionIsShowcase = true
        XCTAssertTrue(environment.plozzCardCaptionsHidden)
        environment.plozzCardCaptionSettings.setOverride(.show, for: .home)
        XCTAssertFalse(environment.plozzCardCaptionsHidden)
        environment.plozzCardCaptionSettings.resetOverrides()
        environment.plozzCardCaptionView = .browse
        XCTAssertFalse(environment.plozzCardCaptionIsShowcase)
        XCTAssertFalse(environment.plozzCardCaptionsHidden)
    }

    func testPosterTypographyKeepsTelevisionFontsAndMobileAccessibilityFloors() {
        for density in UIDensity.allCases {
            let standard = PlozzMetrics.touch(density: density)
            let accessible = PlozzMetrics.touch(density: density, dynamicTypeSize: .accessibility3)
            #if os(iOS)
            XCTAssertGreaterThanOrEqual(standard.posterTitleFontSize, 13)
            XCTAssertGreaterThanOrEqual(standard.posterSubtitleFontSize, 12)
            XCTAssertGreaterThan(accessible.posterTitleFontSize, standard.posterTitleFontSize)
            XCTAssertGreaterThan(accessible.posterSubtitleFontSize, standard.posterSubtitleFontSize)
            #else
            XCTAssertEqual(standard.posterTitleFontSize, standard.cardTitleFontSize)
            XCTAssertEqual(accessible.posterSubtitleFontSize, accessible.cardSubtitleFontSize)
            #endif
        }
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
