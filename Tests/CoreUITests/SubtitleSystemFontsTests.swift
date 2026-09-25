#if canImport(UIKit) && canImport(MediaAccessibility)
import CoreModels
import CoreText
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
        XCTAssertEqual(style.fontDisplayName, snapshot.displayName)
        XCTAssertEqual(style.fontWeightDisplayName, SubtitleSystemFonts.weightDisplayName(snapshot.weight))
        XCTAssertNotEqual(style.fontWeightDisplayName, String(localized: SubtitleFontWeight.regular.displayName))
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
        XCTAssertEqual(Set(SubtitleSystemFonts.installedFonts.map(\.name)), expected)
        XCTAssertEqual(Set(SubtitleSystemFonts.all.map(\.id)).count, SubtitleSystemFonts.all.count)
    }

    func testChoosingSystemFontDoesNotEnableSystemAppearance() throws {
        var style = SubtitleStyle.default
        style.textColor = .yellow
        style.systemFont = .caption(.smallCapitals)
        XCTAssertFalse(style.followsSystemStyle)
        XCTAssertEqual(style.textColor, .yellow)
        XCTAssertEqual(style.fontDisplayName, String(localized: SubtitleSystemFont.CaptionFamily.smallCapitals.displayName))
        XCTAssertNotNil(SubtitleSystemFonts.descriptor(for: try XCTUnwrap(style.systemFont)))
        XCTAssertNil(SubtitleSystemFonts.descriptor(for: .named("Plozz-test-unavailable-font")))
    }
}
#endif
