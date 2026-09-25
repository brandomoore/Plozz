#if canImport(UIKit) && canImport(MediaAccessibility)
import CoreModels
import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class SubtitleSystemFontsTests: XCTestCase {
    func testWeightCyclingStartsFromTheCapturedWeightNotTheFallback() throws {
        var style = SubtitleStyle.default
        style.fontWeight = .regular
        style.fontDescriptor = try XCTUnwrap(SubtitleSystemFonts.capture(
            UIFont.systemFont(ofSize: 30, weight: .semibold).fontDescriptor
        ))
        XCTAssertEqual(SubtitleSystemFonts.adjacentWeight(for: style, forward: true), .bold)
        XCTAssertEqual(SubtitleSystemFonts.adjacentWeight(for: style, forward: false), .medium)
        style.fontDescriptor = try XCTUnwrap(SubtitleSystemFonts.capture(
            UIFont.systemFont(ofSize: 30, weight: .light).fontDescriptor
        ))
        XCTAssertEqual(SubtitleSystemFonts.adjacentWeight(for: style, forward: true), .regular)
        XCTAssertEqual(SubtitleSystemFonts.adjacentWeight(for: style, forward: false), .bold)
    }

    func testSecureDescriptorSnapshotPreservesAllAttributesAcrossCodable() throws {
        let feature: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector
        ]
        let descriptor = UIFont.systemFont(ofSize: 30, weight: .light).fontDescriptor.addingAttributes([
            .featureSettings: [feature],
            .matrix: NSValue(cgAffineTransform: CGAffineTransform(a: 1, b: 0, c: 0.08, d: 1, tx: 0, ty: 0)),
            .cascadeList: [UIFont(name: "Courier", size: 30)!.fontDescriptor]
        ])
        let snapshot = try XCTUnwrap(SubtitleSystemFonts.capture(descriptor))
        let decoded = try JSONDecoder().decode(SubtitleFontDescriptor.self, from: JSONEncoder().encode(snapshot))
        let restored = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: decoded))
        XCTAssertEqual(restored.fontAttributes as NSDictionary, descriptor.fontAttributes as NSDictionary)
        XCTAssertEqual(snapshot, decoded)
        XCTAssertEqual(snapshot.weight, Double(UIFont.Weight.light.rawValue), accuracy: 0.001)
        XCTAssertFalse(snapshot.displayName.isEmpty)

        var style = SubtitleStyle.default
        style.fontDescriptor = decoded
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(style.fontDisplayName, Text(verbatim: snapshot.displayName))
        XCTAssertEqual(style.fontWeightDisplayName(locale: locale), SubtitleSystemFonts.weightDisplayName(snapshot.weight, locale: locale))
        XCTAssertNotEqual(style.fontWeightDisplayName(locale: locale), SubtitleFontWeight.regular.displayName)
    }

    func testAWeightEditRetainsFeaturesMatrixCascadeAndSlant() throws {
        let descriptor = UIFont.systemFont(ofSize: 30, weight: .regular).fontDescriptor
            .withSymbolicTraits(.traitItalic)!
            .addingAttributes([
                .featureSettings: [[UIFontDescriptor.FeatureKey.type: kLowerCaseType,
                                    UIFontDescriptor.FeatureKey.selector: kLowerCaseSmallCapsSelector]],
                .matrix: NSValue(cgAffineTransform: CGAffineTransform(scaleX: 0.97, y: 1)),
                .cascadeList: [UIFont(name: "Courier", size: 30)!.fontDescriptor]
            ])
        var style = SubtitleStyle.default
        style.fontDescriptor = try XCTUnwrap(SubtitleSystemFonts.capture(descriptor))
        style.selectFontWeight(.bold)
        let edited = try XCTUnwrap(style.resolvedFontDescriptor)
        for key: UIFontDescriptor.AttributeName in [.featureSettings, .matrix, .cascadeList] {
            XCTAssertEqual(edited.object(forKey: key) as? NSObject, descriptor.object(forKey: key) as? NSObject)
        }
        XCTAssertTrue(edited.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(style.fontDescriptor?.weight ?? 0, Double(UIFont.Weight.bold.rawValue), accuracy: 0.05)
    }

    func testEveryCaptionFamilyCanBeFrozenWithoutLosingFeatures() throws {
        for entry in SubtitleSystemFonts.captionFonts {
            let saved = try XCTUnwrap(SubtitleSystemFonts.capture(entry.descriptor))
            let restored = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: saved))
            XCTAssertEqual(restored.fontAttributes as NSDictionary, entry.descriptor.fontAttributes as NSDictionary)
        }
    }

    func testEveryNativeCaptionFamilyIsSelectableAndPreservesItsDescriptor() throws {
        XCTAssertEqual(SubtitleSystemFonts.captionFonts.count, 8)
        for family in SubtitleSystemFont.CaptionFamily.allCases {
            let entry = try XCTUnwrap(SubtitleSystemFonts.captionFonts.first { $0.id == .caption(family) })
            XCTAssertEqual(entry.name, Text(family.displayName))
            XCTAssertEqual(SubtitleSystemFonts.displayName(for: entry.id), Text(family.displayName))
            let descriptor = try XCTUnwrap(SubtitleSystemFonts.descriptor(for: entry.id))
            let font = UIFont(descriptor: descriptor, size: 42)
            XCTAssertEqual(font.familyName, UIFont(descriptor: entry.descriptor, size: 42).familyName)
            XCTAssertEqual(descriptor.object(forKey: .featureSettings) as? NSArray,
                           entry.descriptor.object(forKey: .featureSettings) as? NSArray)
        }
    }

    func testSystemSubmenuIncludesAllAvailableNonBundledFamilies() {
        let bundled = Set(SubtitleFontFamily.allCases.filter { !$0.usesSystemFont && $0 != .avenirNext }.map(\.displayName))
        let expected = Set(UIFont.familyNames.filter {
            !bundled.contains($0) && !UIFont.fontNames(forFamilyName: $0).isEmpty
        })
        let installed = SubtitleSystemFonts.installedFonts
        XCTAssertEqual(installed.count, expected.count)
        for family in expected {
            let faces = Set(UIFont.fontNames(forFamilyName: family))
            XCTAssertTrue(installed.contains { entry in
                guard case .named(let name) = entry.id else { return false }
                return faces.contains(name) && entry.name == Text(verbatim: family)
            }, family)
        }
        XCTAssertEqual(Set(SubtitleSystemFonts.all.map(\.id)).count, SubtitleSystemFonts.all.count)
    }

    func testChoosingSystemFontDoesNotEnableSystemAppearance() throws {
        var style = SubtitleStyle.default
        style.textColor = .yellow
        style.systemFont = .caption(.smallCapitals)
        XCTAssertFalse(style.followsSystemStyle)
        XCTAssertEqual(style.textColor, .yellow)
        XCTAssertEqual(style.fontDisplayName, Text(SubtitleSystemFont.CaptionFamily.smallCapitals.displayName))
        XCTAssertNotNil(SubtitleSystemFonts.descriptor(for: try XCTUnwrap(style.systemFont)))
        XCTAssertNil(SubtitleSystemFonts.descriptor(for: .named("Plozz-test-unavailable-font")))
    }

    func testWeightResourcesKeepAppCopyAndUseTheSuppliedNumberLocale() {
        let english = Locale(identifier: "en_US")
        let german = Locale(identifier: "de_DE")
        let englishWeight = SubtitleSystemFonts.weightDisplayName(0.1234, locale: english)
        let germanWeight = SubtitleSystemFonts.weightDisplayName(0.1234, locale: german)
        XCTAssertTrue(String(localized: englishWeight).contains("0.123"))
        XCTAssertTrue(String(localized: germanWeight).contains("0,123"))
        var style = SubtitleStyle.default
        style.fontWeight = .semibold
        XCTAssertEqual(style.fontWeightDisplayName(locale: german), SubtitleFontWeight.semibold.displayName)
    }

    func testStandardSystemWeightsReuseExistingSubtitleWeightResources() {
        let pairs: [(UIFont.Weight, SubtitleFontWeight)] = [
            (.regular, .regular), (.medium, .medium), (.semibold, .semibold), (.bold, .bold)
        ]
        for (system, subtitle) in pairs {
            XCTAssertEqual(
                SubtitleSystemFonts.weightDisplayName(Double(system.rawValue), locale: Locale(identifier: "en")),
                subtitle.displayName
            )
        }
    }

    func testExtraSystemWeightNamesHaveFontSpecificKeysAndUnchangedEnglish() {
        let names: [(UIFont.Weight, String, String)] = [
            (.ultraLight, "subtitleWeight.ultralight", "Ultralight"),
            (.thin, "subtitleWeight.thin", "Thin"),
            (.light, "subtitleWeight.light", "Light"),
            (.heavy, "subtitleWeight.heavy", "Heavy"),
            (.black, "subtitleWeight.black", "Black")
        ]
        let english = Locale(identifier: "en")
        for (weight, key, label) in names {
            var resource = SubtitleSystemFonts.weightDisplayName(Double(weight.rawValue), locale: english)
            XCTAssertEqual(resource.key, key)
            XCTAssertNotEqual(resource.key, label, "Font weights must not share generic brightness/color keys.")
            resource.locale = english
            XCTAssertEqual(String(localized: resource), label)
        }
    }
}
#endif
