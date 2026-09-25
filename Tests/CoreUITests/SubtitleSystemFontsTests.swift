#if canImport(UIKit) && canImport(MediaAccessibility)
import CoreModels
import CoreText
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class SubtitleSystemFontsTests: XCTestCase {
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
