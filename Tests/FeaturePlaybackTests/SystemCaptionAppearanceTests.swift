#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreModels
import AVFoundation
import CoreMedia
import MediaAccessibility
import UIKit
import XCTest

@testable import FeaturePlayback

/// "Use System Caption Style" draws Plozz's subtitles in the device's caption
/// look: the device decides how text looks, Plozz still decides where it sits.
@MainActor
final class SystemCaptionAppearanceTests: XCTestCase {
    private let largeYellowOnBlackBox = SystemCaptionAppearance(
        textColor: SubtitleColor(red: 1, green: 1, blue: 0, alpha: 0.9),
        fontFamilyName: "Avenir Next",
        isBold: true,
        relativeSize: 1.5,
        edge: .uniform,
        background: SubtitleColor(red: 0, green: 0, blue: 1, alpha: 0.5),
        windowColor: SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.75),
        windowCornerRadius: 12
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
        XCTAssertEqual(style.background.cornerRadius, 12)
        XCTAssertEqual(largeYellowOnBlackBox.background, SubtitleColor(red: 0, green: 0, blue: 1, alpha: 0.5))
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
        XCTAssertTrue(appearance.applied(to: .default).background.isEnabled, "The window survives a transparent text background.")
        appearance.windowColor = nil
        XCTAssertFalse(appearance.applied(to: .default).background.isEnabled)
    }

    func testExplicitDeviceTextColorOverridesFileColors() {
        var appearance = largeYellowOnBlackBox
        appearance.allowsSourceColors = false
        XCTAssertFalse(appearance.applied(to: .default).usesSourceColors)
        appearance.allowsSourceColors = true
        XCTAssertTrue(appearance.applied(to: .default).usesSourceColors)
    }

    func testNativeRulesUseCustomLookAndClearOverridesForSystemStyle() throws {
        var style = SubtitleStyle.default
        style.fontFamily = .avenirNext
        style.fontWeight = .bold
        style.fontScale = 0.4
        style.opacity = 0.5
        style.textColor = .yellow
        style.usesSourcePosition = false
        style.verticalPosition = 0.2
        let attributes = try XCTUnwrap(style.textStyleRules()?.first?.textMarkupAttributes)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_FontFamilyName as String] as? String, "Avenir Next")
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double], [0.5, 1, 0.85, 0])
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String] as? Double, 2)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] as? Double, 80)
        style.followsSystemStyle = true
        XCTAssertNil(style.textStyleRules())
    }

    func testSystemSizesAreNotClampedToTheCustomEditorRange() {
        var appearance = largeYellowOnBlackBox
        appearance.relativeSize = 0.1
        XCTAssertEqual(appearance.applied(to: .default).fontScale, 0.1)
        appearance.relativeSize = 4
        XCTAssertEqual(appearance.applied(to: .default).fontScale, 4)
        appearance.relativeSize = .nan
        XCTAssertEqual(appearance.applied(to: .default).fontScale, 1)
    }

    func testNativeSystemFontChoicesUseNativeGenericFamilies() throws {
        for family in SubtitleSystemFont.CaptionFamily.allCases {
            var style = SubtitleStyle.default
            style.systemFont = .caption(family)
            let attributes = try XCTUnwrap(style.textStyleRules()?.first?.textMarkupAttributes)
            XCTAssertNotNil(attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String])
            XCTAssertNil(attributes[kCMTextMarkupAttribute_FontFamilyName as String])
        }
    }

    func testAppearanceRefreshesOnCaptionChangesAndReturnFromSettings() {
        let notifications = NotificationCenter()
        var snapshot = largeYellowOnBlackBox
        let model = SystemCaptionStyle(readAppearance: { snapshot }, notifications: notifications)
        snapshot.textColor = .cyan
        notifications.post(name: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String), object: nil)
        XCTAssertEqual(model.appearance.textColor, .cyan)
        snapshot.windowCornerRadius = 20
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(model.appearance.windowCornerRadius, 20)
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
