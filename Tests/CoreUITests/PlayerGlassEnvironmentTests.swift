import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI

@MainActor
final class PlayerGlassEnvironmentTests: XCTestCase {
    func testPanelsFollowTheResolvedProfileAndAccessibilityPreferenceWithoutAnotherGate() {
        for preference in TransparencyPreference.allCases {
            for systemReduced in [false, true] {
                var environment = EnvironmentValues()
                let expected = preference.reducesTransparency(systemReduceTransparency: systemReduced)
                environment.plozzReduceTransparency = expected
                XCTAssertEqual(environment.plozzReducePanelGlass, expected)
                environment.plozzReduceTransparency = !expected
                XCTAssertEqual(environment.plozzReducePanelGlass, !expected,
                               "Panels must read the live preference, not a copied launch-time value.")
            }
        }
    }

    func testMaterialPreviewsCanStillSelectEachActualSurfaceExplicitly() {
        var environment = EnvironmentValues()
        environment.plozzReducePanelGlass = true
        XCTAssertTrue(environment.plozzReducePanelGlass)
        environment.plozzReducePanelGlass = false
        XCTAssertFalse(environment.plozzReducePanelGlass)
    }
}
