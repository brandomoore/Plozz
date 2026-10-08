import CoreModels
@testable import FeatureSettings
import XCTest

final class ViewCustomizationCycleTests: XCTestCase {
    func testArtworkCyclesBothSourcesAndInheritanceWithoutChangingTheMainChoice() {
        for preference in ArtworkPreference.allCases {
            for area in ArtworkArea.allCases {
                var settings = ArtworkSettings(preference: preference)
                let inherited = settings.prefersOnlineArtwork(in: area)
                for _ in 0..<2 {
                    settings.cycleCustomization(in: area)
                    XCTAssertEqual(settings.prefersOnlineArtwork(in: area), !inherited)
                    XCTAssertNotEqual(settings.override(for: area), .automatic)
                    settings.cycleCustomization(in: area)
                    XCTAssertEqual(settings.prefersOnlineArtwork(in: area), inherited)
                    XCTAssertNotEqual(settings.override(for: area), .automatic)
                    settings.cycleCustomization(in: area)
                    XCTAssertEqual(settings.override(for: area), .automatic)
                    XCTAssertTrue(settings.overrides.isEmpty)
                    XCTAssertEqual(settings.preference, preference)
                }
            }
        }
    }

    func testLabelsCycleBothValuesAndInheritanceWithoutChangingTheMainChoice() {
        for preference in CardCaptionPreference.allCases {
            for view in CardCaptionView.allCases {
                var settings = CardCaptionSettings(preference: preference)
                let inherited = settings.showsLabels(in: view)
                for _ in 0..<2 {
                    settings.cycleCustomization(in: view)
                    XCTAssertEqual(settings.showsLabels(in: view), !inherited)
                    XCTAssertNotEqual(settings.override(for: view), .automatic)
                    settings.cycleCustomization(in: view)
                    XCTAssertEqual(settings.showsLabels(in: view), inherited)
                    XCTAssertNotEqual(settings.override(for: view), .automatic)
                    settings.cycleCustomization(in: view)
                    XCTAssertEqual(settings.override(for: view), .automatic)
                    XCTAssertTrue(settings.overrides.isEmpty)
                    XCTAssertEqual(settings.preference, preference)
                }
            }
        }
    }

    func testMainChangesKeepExplicitChoicesAndCyclingResetsOnlyTheChosenView() {
        var artwork = ArtworkSettings(preference: .online)
        artwork.setOverride(.online, for: .browse)
        artwork.setOverride(.online, for: .search)
        artwork.preference = .library
        artwork.cycleCustomization(in: .browse)
        XCTAssertEqual(artwork.override(for: .browse), .library)
        artwork.cycleCustomization(in: .browse)
        XCTAssertEqual(artwork.override(for: .browse), .automatic)
        XCTAssertEqual(artwork.override(for: .search), .online)

        var labels = CardCaptionSettings(preference: .show)
        labels.setOverride(.show, for: .browse)
        labels.setOverride(.show, for: .search)
        labels.preference = .hide
        labels.cycleCustomization(in: .browse)
        XCTAssertEqual(labels.override(for: .browse), .hide)
        labels.cycleCustomization(in: .browse)
        XCTAssertEqual(labels.override(for: .browse), .automatic)
        XCTAssertEqual(labels.override(for: .search), .show)
    }

    func testRecommendedValuesDescribeTheirActualBehavior() {
        let artwork = ArtworkSettings.default
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .browse)), "Library artwork")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .continueWatching)), "Metadata providers")
        XCTAssertEqual(String(localized: artwork.customizationValue(in: .details)), "Library artwork; alternate backgrounds")
        XCTAssertTrue(artwork.prefersTextlessArtwork(in: .continueWatching))
        let labels = CardCaptionSettings.default
        XCTAssertEqual(String(localized: labels.customizationValue(in: .home)), "Labels except Showcase and series artwork")
        for view in CardCaptionView.allCases where view != .home {
            XCTAssertEqual(String(localized: labels.customizationValue(in: view)), "Labels")
        }
    }
}
