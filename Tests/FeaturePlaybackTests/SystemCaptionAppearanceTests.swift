#if canImport(MediaAccessibility) && canImport(SwiftUI)
import CoreModels
import CoreUI
import CoreText
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

    func testPlozzKeepsPlacementAndHDRButSystemOwnsColorOverridePolicy() {
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
        XCTAssertTrue(style.usesSourceColors)
        XCTAssertTrue(style.followsSystemStyle)
    }

    func testNoBackgroundOnTheDeviceMeansNoBox() {
        var appearance = largeYellowOnBlackBox
        appearance.background = nil
        XCTAssertTrue(appearance.applied(to: .default).background.isEnabled, "The window survives a transparent text background.")
        appearance.windowColor = nil
        XCTAssertFalse(appearance.applied(to: .default).background.isEnabled)
    }

    func testFirstActualEditFreezesEveryOtherEffectiveFieldAndDescriptor() throws {
        var appearance = largeYellowOnBlackBox
        appearance.fontDescriptor = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: .caption(.smallCapitals)))
        appearance.otherSourceOverrides.relativeSize = false
        appearance.otherSourceOverrides.backgroundColor = false
        appearance.otherSourceOverrides.backgroundOpacity = false
        appearance.otherSourceOverrides.windowColor = false
        appearance.otherSourceOverrides.windowOpacity = true
        appearance.otherSourceOverrides.windowCornerRadius = false
        appearance.otherSourceOverrides.edge = false
        appearance.allowsSourceFont = false
        appearance.allowsSourceOpacity = false
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        var saved = SubtitleStyle.profileDefault
        saved.systemFont = .named("Courier")
        saved.fontScale = 0.2
        saved.opacity = 0.3
        saved.background.horizontalPadding = 23
        saved.background.verticalPadding = 11
        saved.secondary = .init(differentiate: true, relativeScale: 0.73, gap: 13)
        let effective = system.resolved(saved)
        XCTAssertEqual(effective.fontScale, 1.5)
        XCTAssertEqual(effective.opacity, 1)
        XCTAssertNotNil(effective.fontDescriptor)
        XCTAssertNil(effective.systemFont, "A stale custom font must not masquerade as the current device font.")
        XCTAssertEqual(effective.glyphBackground, appearance.background)
        XCTAssertEqual(effective.background.horizontalPadding, 23, "Padding is a Plozz value, not a public system measurement.")
        XCTAssertEqual(effective.background.verticalPadding, 11)

        let mutations: [(inout SubtitleStyle) -> Void] = [
            { $0.fontScale += 0.01 },
            { $0.textColor.alpha = 0.33 },
            { $0.textColor.red = 0.25 },
            { $0.glyphBackground.alpha = 0.23 },
            { $0.glyphBackground.blue = 0.25 },
            { $0.background.color.alpha = 0.41 },
            { $0.background.color.red = 0.42 },
            { $0.background.cornerRadius = 3.7 },
            { $0.edge.style = .depressed },
            { $0.captionSourceOverrides?.windowColor.toggle() },
            { $0.verticalPosition = 0.27 },
            { $0.hdrLuminanceScale = 0.37 }
        ]
        for mutation in mutations {
            var expected = effective
            mutation(&expected)
            expected.followsSystemStyle = false
            let edited = system.editing(saved, mutation)
            XCTAssertEqual(edited, expected, "Only the chosen value and matching flag may change.")
            XCTAssertEqual(system.resolved(edited), edited)
            let roundTrip = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(edited))
            XCTAssertEqual(roundTrip, expected)
            XCTAssertEqual(try XCTUnwrap(roundTrip.resolvedFontDescriptor).fontAttributes as NSDictionary,
                           try XCTUnwrap(effective.resolvedFontDescriptor).fontAttributes as NSDictionary)
        }
    }

    func testNoOpAndRepeatedFineStepsDoNotReapplyOrRebaseSystemAppearance() {
        let system = SystemCaptionStyle(readAppearance: { self.largeYellowOnBlackBox }, notifications: NotificationCenter())
        let saved = SubtitleStyle.profileDefault
        XCTAssertEqual(system.editing(saved) { $0.fontScale = 1.5 }, saved)
        XCTAssertEqual(system.editing(saved) { _ in }, saved)
        var edited = saved
        for step in 1...30 {
            edited = system.editing(edited) { $0.fontScale = Double(150 + step) / 100 }
            XCTAssertEqual(edited.fontScale, Double(150 + step) / 100)
            XCTAssertFalse(edited.followsSystemStyle)
            XCTAssertEqual(edited.glyphBackground, largeYellowOnBlackBox.background)
        }
        edited.fontScale = 4
        XCTAssertEqual(system.editing(edited) { $0.fontScale = 4 }, edited)
    }

    func testSwitchingOffFreezesAndSwitchingOnRestoresCurrentAndFutureSettings() {
        let notifications = NotificationCenter()
        var appearance = largeYellowOnBlackBox
        appearance.allowsSourceColors = false
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: notifications)
        let frozen = system.editing(.profileDefault) { $0.followsSystemStyle = false }
        var expected = system.resolved(.profileDefault)
        expected.followsSystemStyle = false
        XCTAssertEqual(frozen, expected)
        appearance.textColor = .cyan
        appearance.relativeSize = 0.73
        appearance.windowCornerRadius = 2.3
        appearance.allowsSourceColors = true
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(system.resolved(frozen), frozen)
        let matching = system.editing(frozen) { $0.followsSystemStyle = true }
        XCTAssertTrue(matching.followsSystemStyle)
        XCTAssertEqual(system.resolved(matching).textColor, .cyan)
        XCTAssertEqual(system.resolved(matching).fontScale, 0.73)
        XCTAssertTrue(system.resolved(matching).usesSourceColors, "An old frozen source policy must not win over current settings.")
        appearance.background = .yellow
        appearance.windowCornerRadius = 8.7
        notifications.post(name: Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String), object: nil)
        XCTAssertEqual(system.resolved(matching).glyphBackground, .yellow)
        XCTAssertEqual(system.resolved(matching).background.cornerRadius, 8.7)
    }

    func testCurrentSnapshotReadsEveryPublicVisualValueAndBehavior() {
        let appearance = SystemCaptionAppearance.current()
        let style = appearance.applied(to: .profileDefault)
        XCTAssertEqual(style.fontScale, Double(MACaptionAppearanceGetRelativeCharacterSize(.user, nil)))
        XCTAssertEqual(style.textColor.alpha, Double(MACaptionAppearanceGetForegroundOpacity(.user, nil)))
        XCTAssertEqual(style.glyphBackground.alpha, Double(MACaptionAppearanceGetBackgroundOpacity(.user, nil)))
        XCTAssertEqual(style.background.color.alpha, Double(MACaptionAppearanceGetWindowOpacity(.user, nil)))
        XCTAssertEqual(style.background.cornerRadius, Double(MACaptionAppearanceGetWindowRoundedCornerRadius(.user, nil)))
        XCTAssertEqual(style.captionEdgeStyleRawValue, Int(MACaptionAppearanceGetTextEdgeStyle(.user, nil).rawValue))
        let readers: [(WritableKeyPath<SubtitleCaptionSourceOverrides, Bool>, (UnsafeMutablePointer<MACaptionAppearanceBehavior>) -> Void)] = [
            (\.font, { _ = MACaptionAppearanceCopyFontDescriptorForStyle(.user, $0, .default).takeRetainedValue() }),
            (\.relativeSize, { _ = MACaptionAppearanceGetRelativeCharacterSize(.user, $0) }),
            (\.foregroundColor, { _ = MACaptionAppearanceCopyForegroundColor(.user, $0).takeRetainedValue() }),
            (\.foregroundOpacity, { _ = MACaptionAppearanceGetForegroundOpacity(.user, $0) }),
            (\.backgroundColor, { _ = MACaptionAppearanceCopyBackgroundColor(.user, $0).takeRetainedValue() }),
            (\.backgroundOpacity, { _ = MACaptionAppearanceGetBackgroundOpacity(.user, $0) }),
            (\.windowColor, { _ = MACaptionAppearanceCopyWindowColor(.user, $0).takeRetainedValue() }),
            (\.windowOpacity, { _ = MACaptionAppearanceGetWindowOpacity(.user, $0) }),
            (\.windowCornerRadius, { _ = MACaptionAppearanceGetWindowRoundedCornerRadius(.user, $0) }),
            (\.edge, { _ = MACaptionAppearanceGetTextEdgeStyle(.user, $0) })
        ]
        for (keyPath, reader) in readers {
            var behavior = MACaptionAppearanceBehavior.useValue
            reader(&behavior)
            XCTAssertEqual(style.captionSourceOverrides?[keyPath: keyPath], behavior == .useContentIfAvailable)
        }
        let colors: [(SubtitleColor, CGColor)] = [
            (style.textColor, MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue()),
            (style.glyphBackground, MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue()),
            (style.background.color, MACaptionAppearanceCopyWindowColor(.user, nil).takeRetainedValue())
        ]
        for (saved, color) in colors {
            let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!
            XCTAssertEqual(saved.red, Double(rgb.components![0]))
            XCTAssertEqual(saved.green, Double(rgb.components![1]))
            XCTAssertEqual(saved.blue, Double(rgb.components![2]))
        }
        XCTAssertNotNil(style.fontDescriptor)
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

    func testSelectingUniformForAnExistingCustomStyleSurvivesPersistence() throws {
        let system = SystemCaptionStyle(readAppearance: { self.largeYellowOnBlackBox }, notifications: NotificationCenter())
        var custom = SubtitleStyle.default
        custom.usesSourceColors = false
        let edited = system.editing(custom) { $0.edge = .init(style: .uniform, color: .cyan, thickness: 9) }
        let restored = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(restored, edited)
        XCTAssertEqual(restored.edge.style, .uniform)
        XCTAssertNil(restored.sourceTextColor(.yellow), "Selecting an edge must not start honoring source alpha.")
    }

    func testNativeRulesKeepFrozenLineAndWindowBackgroundsSeparate() throws {
        let system = SystemCaptionStyle(readAppearance: { self.largeYellowOnBlackBox }, notifications: NotificationCenter())
        let frozen = system.editing(.profileDefault) { $0.followsSystemStyle = false }
        let rules = try XCTUnwrap(frozen.textStyleRules()?.first?.textMarkupAttributes)
        XCTAssertEqual(rules[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double], [0.5, 0, 0, 1])
        XCTAssertEqual(rules[kCMTextMarkupAttribute_BackgroundColorARGB as String] as? [Double], [0.75, 0, 0, 0])
        XCTAssertEqual(rules[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String, kCMTextMarkupCharacterEdgeStyle_Uniform as String)
    }

    func testUndefinedEdgeRemainsIdentifiableInsteadOfClaimingAppleSelectedShadow() throws {
        var appearance = largeYellowOnBlackBox
        appearance.edge = .dropShadow
        appearance.edgeRawValue = Int(MACaptionAppearanceTextEdgeStyle.undefined.rawValue)
        let system = SystemCaptionStyle(readAppearance: { appearance }, notifications: NotificationCenter())
        let frozen = system.editing(.profileDefault) { $0.fontScale += 0.01 }
        let restored = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(frozen))
        XCTAssertEqual(restored.captionEdgeStyleRawValue, appearance.edgeRawValue)
        XCTAssertNotEqual(String(localized: SubtitleStyleEditorValues.edgeName(restored)),
                          String(localized: SubtitleEdgeStyle.dropShadow.displayName))
        let edited = system.editing(restored) { $0.edge.style = .uniform }
        XCTAssertNil(edited.captionEdgeStyleRawValue)
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
