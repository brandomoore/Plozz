import CoreModels
import CoreUI
@testable import FeatureSettings
import XCTest

final class ViewCustomizationCycleTests: XCTestCase {
    func testArtworkTogglesOnlyItsOwnValueAndRemainsCustom() {
        for preference in ArtworkPreference.allCases {
            for area in ArtworkArea.allCases {
                var settings = ArtworkSettings(preference: preference)
                let inherited = settings.prefersOnlineArtwork(in: area)
                for _ in 0..<3 {
                    settings.toggleCustomization(in: area)
                    XCTAssertEqual(settings.prefersOnlineArtwork(in: area), !inherited)
                    XCTAssertNotEqual(settings.override(for: area), .automatic)
                    settings.toggleCustomization(in: area)
                    XCTAssertEqual(settings.prefersOnlineArtwork(in: area), inherited)
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

    func testLabelsToggleOnlyTheirOwnValueAndRemainCustom() {
        for preference in CardCaptionPreference.allCases {
            for view in CardCaptionView.allCases {
                var settings = CardCaptionSettings(preference: preference)
                let inherited = settings.showsLabels(in: view)
                for _ in 0..<3 {
                    settings.toggleCustomization(in: view)
                    XCTAssertEqual(settings.showsLabels(in: view), !inherited)
                    XCTAssertNotEqual(settings.override(for: view), .automatic)
                    settings.toggleCustomization(in: view)
                    XCTAssertEqual(settings.showsLabels(in: view), inherited)
                    XCTAssertNotEqual(settings.override(for: view), .automatic)
                    XCTAssertNil(settings.selectedPreset)
                    XCTAssertEqual(settings.overrides.count, 1)
                    XCTAssertEqual(settings.preference, preference)
                    for other in CardCaptionView.allCases where other != view {
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
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .browse)), "Library")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .continueWatching)), "Metadata providers")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .details)), "Library")
        XCTAssertNotNil(artwork.customizationDetail(in: .details))
        XCTAssertTrue(artwork.prefersTextlessArtwork(in: .continueWatching))
        let labels = CardCaptionSettings.default
        XCTAssertEqual(String(localized: labels.customizationValue(in: .home)), "Mixed")
        XCTAssertEqual(String(localized: labels.customizationValue(in: .recommended)), "Mixed")
        XCTAssertNotNil(labels.customizationDetail(in: .home))
        for view in CardCaptionView.allCases where view != .home && view != .recommended {
            XCTAssertEqual(String(localized: labels.customizationValue(in: view)), "On")
        }
        var customized = labels
        customized.toggleCustomization(in: .home)
        XCTAssertEqual(String(localized: customized.customizationValue(in: .home)), "Off")
        XCTAssertNil(customized.customizationDetail(in: .home))
        customized.toggleCustomization(in: .home)
        XCTAssertEqual(String(localized: customized.customizationValue(in: .home)), "On")
        XCTAssertTrue(customized.showsLabels(in: .home, isShowcase: true, hasArtworkTitle: true))
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

    func testIllustrationsPreservePosterThumbnailAndAlbumAspectRatios() {
        for area in ArtworkArea.allCases {
            for region in ArtworkScopeDiagram.regions(for: area) where region.artwork {
                let expected: CGFloat?
                switch region.kind {
                case .poster: expected = 2.0 / 3
                case .thumbnail, .episode: expected = 16.0 / 9
                case .seriesCard: expected = ContinueWatchingCardShape.aspectRatio
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
        }
    }

    func testLabelHelpMatchesTheConfiguredStyleAndVisibility() {
        for preference in CardCaptionPreference.allCases {
            for view in CardCaptionView.allCases {
                var settings = CardCaptionSettings(preference: preference)
                for _ in 0..<3 {
                    let help = settings.customizationHelp(in: view, style: .framed)
                    XCTAssertFalse(String(localized: help.detail).isEmpty)
                    XCTAssertEqual(help.illustration, .captions(
                        style: .framed, showsCaptions: settings.showsLabels(in: view),
                        showsMixedCaptions: settings.customizationDetail(in: view) != nil
                    ))
                    settings.toggleCustomization(in: view)
                }
            }
        }
    }
}
