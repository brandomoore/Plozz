#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreModels
import XCTest

@testable import FeaturePlayback

/// "Use System Caption Style" draws Plozz's subtitles in the device's caption
/// look: the device decides how text looks, Plozz still decides where it sits.
final class SystemCaptionAppearanceTests: XCTestCase {
    private let largeYellowOnBlackBox = SystemCaptionAppearance(
        textColor: SubtitleColor(red: 1, green: 1, blue: 0, alpha: 0.9),
        fontFamilyName: "Avenir Next",
        isBold: true,
        relativeSize: 1.5,
        edge: .uniform,
        background: SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.75)
    )

    func testDeviceStyleDecidesHowTextLooks() {
        let style = largeYellowOnBlackBox.applied(to: .default)
        XCTAssertEqual(style.fontFamily, .avenirNext)
        XCTAssertEqual(style.fontWeight, .bold)
        XCTAssertEqual(style.fontScale, 1.5)
        XCTAssertEqual(style.textColor, SubtitleColor(red: 1, green: 1, blue: 0, alpha: 0.9))
        XCTAssertEqual(style.opacity, 1, "the device's text opacity is in its colour")
        XCTAssertEqual(style.edge.style, .uniform)
        XCTAssertFalse(style.border.isEnabled, "the device's uniform edge is its only outline")
        XCTAssertTrue(style.background.isEnabled)
        XCTAssertEqual(style.background.color, SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.75))
    }

    func testPlozzKeepsPlacementFileFormattingAndHDRBrightness() {
        var own = SubtitleStyle.default
        own.verticalPosition = 0.3
        own.verticalAnchor = .top
        own.horizontalOffset = -0.2
        own.hdrLuminanceScale = 0.6
        own.usesSourcePosition = false
        own.usesSourceColors = false
        own.followsSystemStyle = true

        let style = largeYellowOnBlackBox.applied(to: own)
        XCTAssertEqual(style.verticalPosition, 0.3)
        XCTAssertEqual(style.verticalAnchor, .top)
        XCTAssertEqual(style.horizontalOffset, -0.2)
        XCTAssertEqual(style.hdrLuminanceScale, 0.6)
        XCTAssertFalse(style.usesSourcePosition)
        XCTAssertFalse(style.usesSourceColors)
        XCTAssertTrue(style.followsSystemStyle)
    }

    func testNoBackgroundOnTheDeviceMeansNoBox() {
        var appearance = largeYellowOnBlackBox
        appearance.background = nil
        XCTAssertFalse(appearance.applied(to: .default).background.isEnabled)
    }

    func testTextSizeStaysWithinWhatThePlayerCanDraw() {
        var appearance = largeYellowOnBlackBox
        appearance.relativeSize = 0.1
        XCTAssertEqual(appearance.applied(to: .default).fontScale, 0.4)
        appearance.relativeSize = 4
        XCTAssertEqual(appearance.applied(to: .default).fontScale, 2.5)
    }

    func testDeviceFontsPlozzDoesNotBundleUseTheSystemFont() {
        XCTAssertEqual(SystemCaptionAppearance.family(named: nil), .system)
        XCTAssertEqual(SystemCaptionAppearance.family(named: "Helvetica"), .system)
        XCTAssertEqual(SystemCaptionAppearance.family(named: "Menlo"), .system)
        XCTAssertEqual(SystemCaptionAppearance.family(named: "Avenir Next"), .avenirNext)
        XCTAssertEqual(SystemCaptionAppearance.family(named: "SF Pro Rounded"), .sfRounded)
        XCTAssertEqual(SystemCaptionAppearance.family(named: "OpenDyslexic"), .openDyslexic)
    }

    @MainActor
    func testOnlyAStyleThatFollowsTheSystemIsRestyled() {
        var own = SubtitleStyle.default
        own.textColor = .cyan
        XCTAssertEqual(SystemCaptionStyle.shared.resolved(own), own)

        own.followsSystemStyle = true
        XCTAssertEqual(
            SystemCaptionStyle.shared.resolved(own),
            SystemCaptionStyle.shared.appearance.applied(to: own)
        )
    }
}
#endif
