import CoreModels
import CoreUI
@testable import FeatureSettings
import SwiftUI
import XCTest

final class ViewCustomizationCycleTests: XCTestCase {
    func testMixedHelpExplainsBehaviorOnlyWhenSelected() throws {
        var settings = CardCaptionSettings.default
        for view in [CardCaptionView.home, .recommended] {
            for choice in view.customizationChoices {
                settings.setOverride(choice, for: view)
                let explanation = settings.cardLabelMixedExplanation(in: view)
                XCTAssertEqual(explanation != nil, choice == .mixed)
                if choice == .mixed {
                    let text = String(localized: try XCTUnwrap(explanation))
                    XCTAssertTrue(text.contains("series artwork"))
                    XCTAssertTrue(text.contains("other cards keep their labels"))
                    #if os(tvOS)
                    XCTAssertTrue(text.contains("Showcase"))
                    #else
                    XCTAssertFalse(text.contains("Showcase"))
                    #endif
                    XCTAssertEqual(settings.cardLabelHelp(in: view), explanation)
                } else {
                    XCTAssertEqual(settings.cardLabelHelp(in: view), view.cardLabelDetail)
                }
            }
        }
        XCTAssertNil(settings.cardLabelMixedExplanation(in: .browse))
        XCTAssertNil(settings.cardLabelMixedExplanation(in: .continueWatching))
    }

    func testSharedRowCopyDistinguishesEachParentFromTheSharedOverride() throws {
        let home = try XCTUnwrap(CardCaptionSettingsPage.home.sharedRowNote)
        XCTAssertEqual(String(localized: home), "Continue Watching is shared with Recommended.")
        let recommended = try XCTUnwrap(CardCaptionSettingsPage.recommended.sharedRowNote)
        XCTAssertEqual(String(localized: recommended), "Continue Watching is shared with Home.")
        for page in CardCaptionSettingsPage.allCases where page != .home && page != .recommended {
            XCTAssertNil(page.sharedRowNote)
        }
        var settings = CardCaptionSettings.default
        for choice in [CardCaptionOverride.show, .hide] {
            settings.setOverride(choice, for: .continueWatching)
            XCTAssertEqual(settings.cardLabelHelp(in: .continueWatching),
                           settings.customizationDetail(in: .continueWatching))
        }
        settings.setOverride(.automatic, for: .continueWatching)
        XCTAssertEqual(String(localized: settings.cardLabelHelp(in: .continueWatching)), "Uses this page's default.")
    }

    func testOnlyPagesWithOverridesUseDefaultControlTitles() {
        for page in CardCaptionSettingsPage.allCases {
            XCTAssertEqual(page.hasOverrides, page == .home || page == .recommended)
            for view in page.controls {
                let expected: String
                if page == .detail || view.isRowOverride {
                    expected = String(localized: view.cardLabelTitle)
                } else {
                    expected = page.hasOverrides ? "Default" : "Card labels"
                }
                XCTAssertEqual(String(localized: page.controlTitle(for: view)), expected)
            }
        }
    }

    func testLibraryLabelControlsAreGroupedByPage() {
        XCTAssertEqual(CardCaptionSettingsScope.libraries.pages, [.recommended, .browse, .collections, .playlists])
        XCTAssertEqual(CardCaptionSettingsPage.recommended.controls, [.recommended, .continueWatching])
        for page in CardCaptionSettingsScope.libraries.pages where page != .recommended {
            XCTAssertEqual(page.controls, [page.firstControl])
        }
    }

    func testEveryCaptionSettingHasARecognizablePageInTheSharedEditor() {
        XCTAssertEqual(CardCaptionSettingsScope.home.pages, [.home])
        XCTAssertEqual(CardCaptionSettingsScope.detail.pages, [.detail])
        XCTAssertEqual(CardCaptionSettingsPage.home.controls, [.home, .continueWatching, .homeLibraries])
        XCTAssertEqual(CardCaptionSettingsPage.detail.controls, [.episodes, .related, .extras])
        XCTAssertEqual(CardCaptionSettingsPage.people.controls, [.filmography])
        let controls = CardCaptionSettingsScope.all.pages.flatMap(\.controls)
        XCTAssertEqual(Set(controls), Set(CardCaptionView.allCases))
        for view in CardCaptionView.allCases {
            XCTAssertEqual(controls.filter { $0 == view }.count, view == .continueWatching ? 2 : 1)
        }
    }

    func testDetailPreviewHighlightsOnlyTheEditedRow() {
        var settings = CardCaptionSettings.default
        settings.setOverride(.hide, for: .episodes)
        for editing in CardCaptionSettingsPage.detail.controls {
            let snapshot = CardLabelScopePreview.snapshot(
                page: .detail, editing: editing, settings: settings,
                isShowcase: false, seriesArtwork: true, layout: .landscape
            )
            XCTAssertEqual(snapshot.rows.map(\.view), [.episodes, .related, .extras])
            XCTAssertEqual(snapshot.rows.filter(\.highlighted).map(\.view), [editing])
            XCTAssertEqual(snapshot.rows.map(\.showsLabels), [false, true, true])
        }
    }

    func testHomePreviewIncludesIndependentLibraryOverrideAndParentHighlighting() throws {
        var settings = CardCaptionSettings.default
        settings.setOverride(.hide, for: .home)
        settings.setOverride(.show, for: .continueWatching)
        for choice in CardCaptionView.homeLibraries.customizationChoices {
            settings.setOverride(choice, for: .homeLibraries)
            for editing in CardCaptionSettingsPage.home.controls {
                let snapshot = CardLabelScopePreview.snapshot(
                    page: .home, editing: editing, settings: settings,
                    isShowcase: true, seriesArtwork: true, layout: .portrait
                )
                XCTAssertEqual(snapshot.rows.map(\.view), [.continueWatching, .home, .homeLibraries])
                let libraries = try XCTUnwrap(snapshot.rows.last)
                XCTAssertEqual(libraries.showsLabels, choice == .show)
                XCTAssertEqual(libraries.highlighted,
                               editing == .homeLibraries || (editing == .home && choice == .automatic))
                XCTAssertTrue(try XCTUnwrap(snapshot.rows.first).showsLabels)
                XCTAssertEqual(String(localized: libraries.title), "Libraries")
            }
        }
        XCTAssertFalse(CardCaptionSettingsPage.recommended.controls.contains(.homeLibraries))
        settings.setOverride(.automatic, for: .homeLibraries)
        XCTAssertEqual(String(localized: settings.cardLabelHelp(in: .homeLibraries)), "Uses this page's default.")
    }

    func testLibraryLabelPreviewShowsEachParentAndTheSharedRowOverride() throws {
        var settings = CardCaptionSettings.default
        settings.setOverride(.show, for: .home)
        settings.setOverride(.hide, for: .recommended)
        for choice in CardCaptionView.continueWatching.customizationChoices {
            settings.setOverride(choice, for: .continueWatching)
            for page in [CardCaptionSettingsPage.home, .recommended] {
                let preview = CardLabelScopePreview.snapshot(
                    page: page, editing: .continueWatching, settings: settings, isShowcase: true,
                    seriesArtwork: true, layout: .landscape
                )
                XCTAssertEqual(preview.page, page)
                let watching = try XCTUnwrap(preview.rows.first)
                let ordinary = try XCTUnwrap(preview.rows.first { $0.view == page.firstControl })
                XCTAssertTrue(watching.isContinueWatching)
                XCTAssertTrue(watching.highlighted)
                XCTAssertFalse(ordinary.highlighted)
                XCTAssertEqual(watching.showsLabels, choice == .automatic ? preview.page == .home : choice == .show)
                XCTAssertEqual(ordinary.showsLabels, preview.page == .home)
            }
            let recommended = CardLabelScopePreview.snapshot(
                page: .recommended, editing: .recommended, settings: settings, isShowcase: true,
                seriesArtwork: true, layout: .landscape
            )
            XCTAssertEqual(recommended.rows.first?.highlighted, choice == .automatic)
            XCTAssertEqual(recommended.rows.last?.highlighted, true)
        }
    }

    func testLibraryLabelPreviewsUseTheActualLayoutAndDoNotChangePreferences() {
        let settings = CardCaptionSettings.default
        for showcase in [false, true] {
            for seriesArtwork in [false, true] {
                for layout in [ContinueWatchingCardLayout.portrait, .landscape] {
                    for page in CardCaptionSettingsScope.all.pages {
                        for view in page.controls {
                            let isShowcase = [.home, .recommended].contains(page) && showcase
                            let snapshot = CardLabelScopePreview.snapshot(
                                page: page, editing: view, settings: settings,
                                isShowcase: isShowcase,
                                seriesArtwork: seriesArtwork, layout: layout
                            )
                            XCTAssertEqual(snapshot.layout, layout)
                            for row in snapshot.rows {
                                XCTAssertEqual(row.showsLabels, settings.showsLabels(
                                    in: row.isContinueWatching ? page.firstControl : row.view,
                                    isShowcase: isShowcase,
                                    hasArtworkTitle: row.isContinueWatching && seriesArtwork,
                                    isContinueWatching: row.isContinueWatching
                                ))
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(settings, .default)
    }

    func testEveryLabelIllustrationUsesPackedCardsAndTheActualArtworkShape() throws {
        for viewport: CGFloat in [390, 1024, 1920] {
            let metrics = viewport == 1920 ? PlozzMetrics(density: .standard) : .touch(density: .standard)
            for style in CardStyle.allCases {
                for page in CardCaptionSettingsPage.allCases {
                    for layout in ContinueWatchingCardLayout.allCases {
                        for seriesArtwork in [false, true] {
                            let preview = CardLabelScopePreview.snapshot(
                                page: page, editing: page.firstControl, settings: .init(preference: .show),
                                isShowcase: false, seriesArtwork: seriesArtwork, layout: layout
                            )
                            XCTAssertEqual(preview.seriesArtwork, seriesArtwork)
                            for details in ContinueWatchingPlaybackDetails.allCases {
                                for row in preview.rows {
                                    let geometry = SettingsIllustrationCardGeometry(
                                        row: row, preview: preview, style: style, metrics: metrics,
                                        playbackDetails: details, viewportWidth: viewport
                                    )
                                    let first = try XCTUnwrap(geometry.cards.first)
                                    let second = try XCTUnwrap(geometry.cards.dropFirst().first)
                                    XCTAssertEqual(first.surface.minX, 0, accuracy: 0.001)
                                    XCTAssertEqual(second.surface.minX - first.surface.maxX, geometry.gap, accuracy: 0.001)
                                    XCTAssertLessThan(geometry.gap / first.artwork.width, 0.3,
                                                      "A media row must not distribute its cards across empty space.")
                                    let landscape = row.isContinueWatching ? layout == .landscape
                                        : row.view == .episodes || row.view == .extras || row.view == .homeLibraries
                                    let expected: CGFloat = if row.isContinueWatching && layout == .portrait {
                                        details.cardAspectRatio
                                    } else if row.isContinueWatching && seriesArtwork {
                                        ContinueWatchingCardShape.aspectRatio
                                    } else {
                                        landscape ? 16.0 / 9 : 2.0 / 3
                                    }
                                    XCTAssertEqual(first.artwork.width / first.artwork.height, expected, accuracy: 0.005)
                                    for card in geometry.cards {
                                        XCTAssertLessThanOrEqual(card.surface.maxY, geometry.height + 0.001)
                                        XCTAssertGreaterThan(card.captions[0].minY, card.artwork.maxY)
                                        XCTAssertLessThan(card.captions[0].width, card.artwork.width)
                                    }
                                    if preview.isGrid {
                                        XCTAssertEqual(Set(geometry.cards.map(\.artwork.minY)).count, 2)
                                        XCTAssertTrue(geometry.cards.allSatisfy {
                                            $0.surface.maxX <= SettingsIllustrationCardGeometry.width + 0.001
                                        })
                                    } else {
                                        XCTAssertEqual(Set(geometry.cards.map(\.artwork.minY)).count, 1)
                                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry.cards.last).surface.maxX, 300)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testLabelIllustrationsKeepGeometryStableWithoutDrawingEmptyFramesAsCaptions() throws {
        let metrics = PlozzMetrics(density: .standard)
        for page in CardCaptionSettingsPage.allCases {
            let preview = CardLabelScopePreview.snapshot(
                page: page, editing: page.firstControl, settings: .init(preference: .show),
                isShowcase: false, seriesArtwork: true, layout: .landscape
            )
            for row in preview.rows {
                let hidden = CardLabelScopePreview.Row(view: row.view, showsLabels: false, highlighted: row.highlighted)
                let shown = SettingsIllustrationCardGeometry(
                    row: row, preview: preview, style: .framed, metrics: metrics,
                    playbackDetails: .detailed, viewportWidth: 1920
                )
                let off = SettingsIllustrationCardGeometry(
                    row: hidden, preview: preview, style: .framed, metrics: metrics,
                    playbackDetails: .detailed, viewportWidth: 1920
                )
                XCTAssertEqual(shown.height, off.height)
                XCTAssertEqual(shown.cards.map(\.artwork), off.cards.map(\.artwork))
                XCTAssertLessThan(try XCTUnwrap(off.cards.first).surface.height,
                                  try XCTUnwrap(shown.cards.first).surface.height)
            }
        }
    }

    func testArtworkCyclesThroughExactlyItsSupportedChoicesAndRemainsCustom() {
        for preference in ArtworkPreference.allCases {
            for area in ArtworkArea.allCases {
                var settings = ArtworkSettings(preference: preference)
                let choices = area.customizationChoices
                XCTAssertEqual(choices, area == .details ? [.library, .online, .mixed] : [.library, .online])
                let initial = choices.firstIndex(of: settings.customization(in: area))!
                for step in 1...(choices.count * 3) {
                    settings.toggleCustomization(in: area)
                    XCTAssertEqual(settings.customization(in: area), choices[(initial + step) % choices.count])
                    XCTAssertNotEqual(settings.override(for: area), .automatic)
                    XCTAssertNil(settings.selectedPreset, "Matching a preset value must not silently reselect it.")
                    XCTAssertEqual(settings.overrides.count, 1)
                    XCTAssertEqual(settings.preference, preference)
                    for other in ArtworkArea.allCases where other != area {
                        XCTAssertEqual(settings.preference(in: other), preference)
                    }
                }
            }
        }
    }

    func testLabelsCycleThroughExactlyTheirSupportedChoicesAndRemainCustom() {
        for preference in CardCaptionPreference.allCases {
            for view in CardCaptionView.allCases {
                var settings = CardCaptionSettings(preference: preference)
                let choices = view.customizationChoices
                XCTAssertEqual(choices, view.isRowOverride
                    ? [.automatic, .show, .hide]
                    : [.home, .recommended].contains(view) ? [.show, .hide, .mixed] : [.show, .hide])
                let initial = choices.firstIndex(of: settings.customization(in: view))!
                for step in 1...(choices.count * 3) {
                    settings.toggleCustomization(in: view)
                    XCTAssertEqual(settings.customization(in: view), choices[(initial + step) % choices.count])
                    let followsParent = settings.customization(in: view) == .automatic
                    XCTAssertEqual(settings.selectedPreset, followsParent ? preference : nil)
                    XCTAssertEqual(settings.overrides.count + settings.mixedOverrides.count, followsParent ? 0 : 1)
                    XCTAssertEqual(settings.preference, preference)
                    for other in CardCaptionView.allCases where other != view
                        && !(view == .home && other == .homeLibraries) {
                        for artworkTitle in [false, true] {
                            XCTAssertEqual(
                                settings.showsLabels(in: other, isShowcase: true, hasArtworkTitle: artworkTitle),
                                CardCaptionSettings(preference: preference).showsLabels(
                                    in: other, isShowcase: true, hasArtworkTitle: artworkTitle
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    func testEveryPresetReplacesTheEntireConfigurationIncludingReselection() {
        for previous in ArtworkPreference.allCases {
            for next in ArtworkPreference.allCases {
                var settings = ArtworkSettings(preference: previous)
                for area in ArtworkArea.allCases { settings.toggleCustomization(in: area) }
                settings.applyPreset(next)
                XCTAssertEqual(settings, ArtworkSettings(preference: next))
                XCTAssertEqual(settings.selectedPreset, next)
            }
        }
        for previous in CardCaptionPreference.allCases {
            for next in CardCaptionPreference.allCases {
                var settings = CardCaptionSettings(preference: previous)
                for view in CardCaptionView.allCases { settings.toggleCustomization(in: view) }
                settings.applyPreset(next)
                XCTAssertEqual(settings, CardCaptionSettings(preference: next))
                XCTAssertEqual(settings.selectedPreset, next)
            }
        }
    }

    func testRecommendedValuesDescribeTheirActualBehavior() {
        let artwork = ArtworkSettings.default
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .home)), "Metadata providers")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .recommendedHero)), "Metadata providers")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .browse)), "Library")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .continueWatching)), "Metadata providers")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .details)), "Mixed")
        XCTAssertNotNil(artwork.customizationDetail(in: .details))
        XCTAssertTrue(artwork.prefersTextlessArtwork(in: .continueWatching))
        let labels = CardCaptionSettings.default
        XCTAssertEqual(String(localized: labels.customizationValue(in: .home)), "Mixed")
        XCTAssertEqual(String(localized: labels.customizationValue(in: .recommended)), "Mixed")
        XCTAssertEqual(String(localized: labels.customizationDetail(in: .home)),
                       "Labels are visible except in Showcase and on series artwork.")
        XCTAssertEqual(String(localized: labels.customizationValue(in: .continueWatching)), "Use default")
        XCTAssertEqual(String(localized: labels.customizationValue(in: .homeLibraries)), "Use default")
        for view in CardCaptionView.allCases where view != .home && view != .recommended && !view.isRowOverride {
            XCTAssertEqual(String(localized: labels.customizationValue(in: view)), "On")
        }
        var customized = labels
        customized.toggleCustomization(in: .home)
        XCTAssertEqual(String(localized: customized.customizationValue(in: .home)), "On")
        XCTAssertEqual(String(localized: customized.customizationDetail(in: .home)), "Labels are visible in this view.")
        XCTAssertTrue(customized.showsLabels(in: .home, isShowcase: true, hasArtworkTitle: true))
        customized.toggleCustomization(in: .home)
        XCTAssertEqual(String(localized: customized.customizationValue(in: .home)), "Off")
        XCTAssertEqual(String(localized: customized.customizationDetail(in: .home)), "Labels are hidden in this view.")
        customized.toggleCustomization(in: .home)
        XCTAssertEqual(String(localized: customized.customizationValue(in: .home)), "Mixed")
        XCTAssertEqual(String(localized: customized.customizationDetail(in: .home)),
                       "Labels are visible except in Showcase and on series artwork.")
        XCTAssertFalse(customized.showsLabels(in: .home, isShowcase: true))
    }

    func testEveryArtworkScopeHasABoundedHighlightAndConciseHelp() throws {
        let bounds = CGRect(origin: .zero, size: ArtworkScopeDiagram.screen)
        for area in ArtworkArea.allCases {
            for navigation in NavigationStyle.allCases {
                for kind in ArtworkScopeDiagram.DetailKind.allCases {
                    let regions = ArtworkScopeDiagram.regions(
                        for: area, navigationStyle: navigation, detailKind: kind
                    )
                    XCTAssertFalse(regions.isEmpty, area.rawValue)
                    XCTAssertTrue(regions.contains { $0.artwork && $0.highlighted }, area.rawValue)
                    XCTAssertTrue(regions.allSatisfy { bounds.contains($0.frame) }, area.rawValue)
                    XCTAssertTrue(regions.filter(\.highlighted).allSatisfy(\.artwork), area.rawValue)
                }
            }
            let detail = String(localized: try XCTUnwrap(ArtworkSettings.default.customizationDetail(in: area)))
            XCTAssertFalse(detail.contains("own choice"), detail)
            XCTAssertFalse(detail.contains("separate choices"), detail)
            XCTAssertFalse(detail.contains("Providers"), detail)
        }
        let hero = ArtworkScopeDiagram.regions(for: .home).filter(\.highlighted)
        let rows = ArtworkScopeDiagram.regions(for: .homeRows).filter(\.highlighted)
        XCTAssertEqual(Set(hero.map(\.kind)), [.backdrop, .logo])
        XCTAssertTrue(rows.allSatisfy { $0.kind == .poster })
        let player = ArtworkScopeDiagram.regions(for: .playback).filter(\.highlighted)
        XCTAssertTrue(player.allSatisfy { $0.kind == .thumbnail && $0.frame.minY >= 105 },
                      "The diagram must highlight player artwork, never the video itself.")
    }

    func testTitleDetailsSeparateMovieAndShowLayoutsFromEpisodeArtwork() {
        let movie = ArtworkScopeDiagram.regions(for: .details, detailKind: .movie)
        let show = ArtworkScopeDiagram.regions(for: .details, detailKind: .series)
        let episodes = ArtworkScopeDiagram.regions(for: .episodes)
        XCTAssertFalse(movie.contains { $0.kind == .episode || $0.kind == .poster },
                       "A resting movie hero has neither an episode rail nor visible Related posters.")
        XCTAssertEqual(movie.first?.frame, CGRect(origin: .zero, size: ArtworkScopeDiagram.screen))
        XCTAssertTrue(show.contains { $0.kind == .episode })
        XCTAssertTrue(show.filter { $0.kind == .episode }.allSatisfy { !$0.highlighted })
        XCTAssertTrue(show.filter(\.highlighted).allSatisfy { $0.kind == .backdrop || $0.kind == .logo })
        XCTAssertTrue(episodes.filter(\.highlighted).allSatisfy { $0.kind == .episode })
        for regions in [movie, show, episodes] {
            XCTAssertFalse(regions.contains { $0.kind == .navigation })
        }
    }

    func testNavigationChromeMatchesTheSelectedModeAndPushedPageExceptions() {
        let sidebar = ArtworkScopeDiagram.regions(for: .home, navigationStyle: .sidebar)
            .filter { $0.kind == .navigation }
        let rail = ArtworkScopeDiagram.regions(for: .home, navigationStyle: .rail)
            .filter { $0.kind == .navigation }
        let tabs = ArtworkScopeDiagram.regions(for: .home, navigationStyle: .tabBar)
            .filter { $0.kind == .navigation }
        XCTAssertEqual(sidebar.count, 1, "The native sidebar is a trigger, not a permanently pinned rail.")
        XCTAssertGreaterThan(rail.count, 1)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertGreaterThan(tabs[0].frame.width, tabs[0].frame.height * 5)
        XCTAssertFalse(ArtworkScopeDiagram.regions(for: .browse, navigationStyle: .tabBar)
            .contains { $0.kind == .navigation })
        XCTAssertEqual(ArtworkScopeDiagram.regions(for: .search, navigationStyle: .rail)
            .filter { $0.kind == .navigation }.count, 1)
    }

    func testArtworkGridCardsHaveConsistentGuttersWithoutOverlappingRows() throws {
        for area in [ArtworkArea.browse, .collections, .playlists, .search, .watchlist] {
            for navigation in NavigationStyle.allCases {
                let posters = ArtworkScopeDiagram.regions(for: area, navigationStyle: navigation)
                    .filter { $0.kind == .poster }
                for (index, poster) in posters.enumerated() {
                    for other in posters.dropFirst(index + 1) {
                        XCTAssertFalse(poster.frame.intersects(other.frame), "\(area): overlapping cards")
                    }
                }
                let first = try XCTUnwrap(posters.first)
                let next = try XCTUnwrap(posters.dropFirst().first)
                let gap = next.frame.minX - first.frame.maxX
                XCTAssertGreaterThan(gap, 2)
                XCTAssertLessThan(gap / first.frame.width, 0.3)
            }
        }
    }

    func testIllustrationsPreservePosterThumbnailAndAlbumAspectRatios() {
        for area in ArtworkArea.allCases {
            for region in ArtworkScopeDiagram.regions(for: area) where region.artwork {
                let expected: CGFloat?
                switch region.kind {
                case .poster: expected = 2.0 / 3
                case .thumbnail, .episode: expected = 16.0 / 9
                case .seriesCard: expected = ContinueWatchingCardShape.aspectRatio
                case .portraitSeriesCard: expected = ContinueWatchingCardShape.portraitAspectRatio
                case .cover: expected = 1
                default: expected = nil
                }
                if let expected {
                    XCTAssertEqual(region.frame.width / region.frame.height, expected, accuracy: 0.001,
                                   "\(area): \(region.kind)")
                }
            }
        }
        XCTAssertTrue(ArtworkScopeDiagram.regions(for: .topShelf).filter(\.highlighted)
            .allSatisfy { $0.kind == .poster })
        XCTAssertTrue(ArtworkScopeDiagram.regions(for: .downloads).filter(\.highlighted)
            .allSatisfy { $0.kind == .thumbnail })
    }

    func testHomePreviewsFollowHeroAndContinueWatchingPresentation() {
        var settings = HeroSettings.default
        settings.style = .followsFocus
        let showcase = ArtworkScopeDiagram.regions(for: .home, heroSettings: settings)
        XCTAssertEqual(showcase.first?.frame.width, 192)
        settings.style = .carousel
        let carousel = ArtworkScopeDiagram.regions(for: .home, heroSettings: settings)
        XCTAssertEqual(carousel.first?.frame, CGRect(origin: .zero, size: ArtworkScopeDiagram.screen))
        XCTAssertFalse(carousel.contains { $0.kind == .poster })
        settings.isEnabled = false
        let inactive = ArtworkScopeDiagram.regions(for: .home, heroSettings: settings)
        XCTAssertFalse(inactive.contains(where: \.highlighted))
        XCTAssertFalse(inactive.contains { $0.kind == .backdrop || $0.kind == .logo })
        for seriesArtwork in [true, false] {
            let watching = ArtworkScopeDiagram.regions(
                for: .continueWatching, heroSettings: settings,
                continueWatchingShowsSeriesArtwork: seriesArtwork
            ).filter(\.highlighted)
            XCTAssertEqual(watching.count, 3)
            XCTAssertTrue(watching.allSatisfy { $0.kind == (seriesArtwork ? .seriesCard : .thumbnail) })
            let portrait = ArtworkScopeDiagram.regions(
                for: .continueWatching, heroSettings: settings,
                continueWatchingShowsSeriesArtwork: seriesArtwork, continueWatchingLayout: .portrait
            ).filter(\.highlighted)
            XCTAssertEqual(portrait.count, 6)
            for region in portrait {
                XCTAssertEqual(region.kind, .portraitSeriesCard)
                XCTAssertEqual(region.frame.width / region.frame.height,
                               ContinueWatchingCardShape.portraitAspectRatio, accuracy: 0.001)
                XCTAssertTrue(CGRect(origin: .zero, size: ArtworkScopeDiagram.screen).contains(region.frame))
            }
        }
    }

    func testLabelHelpMatchesTheConfiguredStyleAndVisibility() {
        for preference in CardCaptionPreference.allCases {
            for view in CardCaptionView.allCases {
                var settings = CardCaptionSettings(preference: preference)
                for _ in 0..<3 {
                    let help = settings.customizationHelp(in: view, style: .framed)
                    let expected: String
                    if view == .continueWatching {
                        switch settings.customization(in: view) {
                        case .automatic: expected = "Uses Home rows or Recommended, depending on where the row appears."
                        case .show: expected = "Labels are visible below Continue Watching artwork."
                        case .hide: expected = "Labels are hidden below Continue Watching artwork."
                        case .mixed: XCTFail("Unsupported Continue Watching choice"); return
                        }

                    } else if view == .homeLibraries, settings.customization(in: view) == .automatic {
                        expected = "Uses Home's default."
                    } else {
                        expected = settings.customization(in: view) == .mixed
                        ? "Labels are visible except in Showcase and on series artwork."
                        : settings.showsLabels(in: view) ? "Labels are visible in this view." : "Labels are hidden in this view."
                    }
                    XCTAssertEqual(String(localized: help.detail), expected)
                    let isContinueWatching = view == .continueWatching
                    let parent = isContinueWatching ? CardCaptionView.home : view
                    let showsCaptions = settings.showsLabels(in: parent, isContinueWatching: isContinueWatching)
                    XCTAssertEqual(help.illustration, .captions(
                        style: .framed, showsCaptions: showsCaptions,
                        showsMixedCaptions: settings.customization(in: view) == .mixed
                            || (isContinueWatching && showsCaptions != settings.showsLabels(
                                in: parent, hasArtworkTitle: true, isContinueWatching: true
                            ))
                    ))
                    settings.toggleCustomization(in: view)
                }

            }
        }
    }

    func testContinueWatchingArtworkNamesAndPreviewCaptionChoices() {
        XCTAssertEqual(ContinueWatchingArtworkStyle.allCases.map { String(localized: $0.displayName) },
                       ["Artwork + logo", "Thumbnail", "Poster"])
        for parent in [CardCaptionView.home, .recommended] {
            for choice in CardCaptionView.continueWatching.customizationChoices {
                var captions = CardCaptionSettings.default
                captions.setOverride(choice, for: .continueWatching)
                for showcase in [false, true] {
                    for style in ContinueWatchingArtworkStyle.allCases {
                        XCTAssertEqual(
                            style.showsCaptions(settings: captions, in: parent, isShowcase: showcase),
                            choice == .automatic ? !showcase && style == .thumbnail : choice == .show
                        )
                    }
                }
            }
        }
    }

    func testProgressOnlyDiagramUsesNormalPosterHeight() {
        let regions = ArtworkScopeDiagram.regions(
            for: .continueWatching, continueWatchingLayout: .portrait,
            continueWatchingPlaybackDetails: .progressOnly
        ).filter(\.highlighted)
        XCTAssertEqual(regions.count, 6)
        for region in regions {
            XCTAssertEqual(region.frame.width / region.frame.height, 2.0 / 3.0, accuracy: 0.001)
        }
        XCTAssertEqual(String(localized: ContinueWatchingPlaybackDetails.detailed.displayName), "Detailed")
        XCTAssertEqual(String(localized: ContinueWatchingPlaybackDetails.progressOnly.displayName), "Progress only")
    }
}
