import CoreModels
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
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .continueWatching)), "Providers")
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
}
