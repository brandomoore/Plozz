import CoreModels
import CoreUI
@testable import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SettingsControlRowsHostedTests: XCTestCase {
    func testProfileHintFitsWithoutChangingHeaderSize() throws {
        for name in ["Alex", "Alexandria Morgan-Williams"] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                for focused in [false, true] {
                    for scheme in [ColorScheme.light, .dark] {
                        let renderer = ImageRenderer(content:
                            SettingsFocusRow(isFocused: focused, size: .contained) {
                                SettingsWorkspaceProfileLabel(profile: Profile(name: name))
                            }
                            .frame(width: 750)
                            .background(scheme == .dark ? Color.black : Color.white)
                            .environment(\.layoutDirection, direction)
                            .environment(\.themePalette, scheme == .dark ? .dark : .light)
                            .environment(\.colorScheme, scheme)
                            .environment(\._accessibilityReduceMotion, true)
                        )
                        renderer.scale = 1
                        let image = try XCTUnwrap(renderer.cgImage)
                        XCTAssertEqual(image.width, 750)
                        XCTAssertEqual(image.height, 100, "Focus changes must not move adjacent controls or rows.")
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        XCTAssertEqual(labels.contains("Switch profile"), focused, "\(labels)")
                        XCTAssertTrue(labels.contains(name), "Keep the profile name readable: \(labels)")
                        let attachment = XCTAttachment(image: UIImage(cgImage: image))
                        attachment.name = "Profile hint \(name) \(direction) \(scheme) focused=\(focused)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }

    func testNavigationAndMenuLabelsShareTheFormFocusHeight() throws {
        let labels: [AnyView] = [
            AnyView(SettingsRowLabel(icon: nil, title: "Manage channels")),
            AnyView(SettingsRowLabel(icon: "sparkles.tv", title: "Manage channels")),
            AnyView(SettingsRowLabel(title: Text("Manage channels"), icon: {
                Color.clear.frame(width: 30, height: 30)
            })),
            AnyView(SettingsSectionLabel(
                title: Text("Channel order"), icon: nil, assetIcon: nil,
                value: Text("Name"), subtitle: nil,
                accessorySymbol: "chevron.up.chevron.down"
            )),
            AnyView(SettingsDisclosureLabel {
                Label("Guide preferences", systemImage: "calendar")
            }.settingsFormRowLayout())
        ]
        let expectedHeight = Int(
            SettingsRowMetrics.minHeight(.primary) + 2 * SettingsRowMetrics.verticalPadding(.primary)
        )
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for label in labels {
                let renderer = ImageRenderer(content:
                    SettingsFocusRow(isFocused: true, size: .contained) { label }
                        .frame(width: 600)
                        .environment(\.layoutDirection, direction)
                        .environment(\.themePalette, .dark)
                        .environment(\.colorScheme, .dark)
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.height, expectedHeight)
                let bytes = try pixels(image)
                for y in [0, image.height - 1] {
                    XCTAssertGreaterThan(bytes[(y * image.width + image.width / 2) * 4], 230,
                                         "The shared height must be inside the painted focus fill.")
                }
            }
        }
    }

    func testCompactInsetsRemainExplicitAndMultilineRowsCanGrow() throws {
        let compact = ImageRenderer(content:
            SettingsRowLabel(
                title: Text("Source"),
                contentInsets: .init(top: 8, leading: 12, bottom: 8, trailing: 12),
                icon: { Color.clear.frame(width: 30, height: 30) }
            )
            .frame(width: 600)
        )
        let multiline = ImageRenderer(content:
            SettingsRowLabel(icon: "sparkles.tv", title: "Manage channels", secondary: {
                Text("Channels from your libraries").font(SettingsRowMetrics.descriptionFont)
            })
            .frame(width: 600)
        )
        compact.scale = 1
        multiline.scale = 1
        let standardHeight = Int(
            SettingsRowMetrics.minHeight(.primary) + 2 * SettingsRowMetrics.verticalPadding(.primary)
        )
        XCTAssertLessThan(try XCTUnwrap(compact.cgImage).height, standardHeight)
        XCTAssertGreaterThan(try XCTUnwrap(multiline.cgImage).height, standardHeight)
    }

    func testConnectedGroupsKeepOuterCornersAndNarrowInternalGaps() throws {
        for count in 1...3 {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let renderer = ImageRenderer(content:
                    SettingsConnectedControlGroups {
                        ForEach(0..<count, id: \.self) { _ in
                            Color.clear.frame(height: 64)
                        }
                    }
                    .frame(width: 320)
                    .environment(\.layoutDirection, direction)
                    .environment(\.themePalette, .dark)
                    .environment(\.gradientBackgroundsEnabled, false)
                )
                let reference = ImageRenderer(content:
                    VStack(spacing: 8) {
                        ForEach(0..<count, id: \.self) { index in
                            UnevenRoundedRectangle(
                                topLeadingRadius: index == 0 ? 28 : 8,
                                bottomLeadingRadius: index == count - 1 ? 28 : 8,
                                bottomTrailingRadius: index == count - 1 ? 28 : 8,
                                topTrailingRadius: index == 0 ? 28 : 8,
                                style: .continuous
                            )
                            .fill(.white)
                            .frame(width: 320, height: 96)
                        }
                    }
                    .environment(\.layoutDirection, direction)
                )
                renderer.scale = 1
                reference.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.height, count * 96 + (count - 1) * 8)
                let actual = try pixels(image)
                let expected = try pixels(XCTUnwrap(reference.cgImage))
                XCTAssertEqual(actual.count, expected.count)
                let mismatches = stride(from: 3, to: min(actual.count, expected.count), by: 4).filter {
                    (actual[$0] > 0) != (expected[$0] > 0)
                }
                let differences = mismatches.prefix(12).map {
                    "\(($0 / 4) % image.width),\(($0 / 4) / image.width):\(actual[$0])/\(expected[$0])"
                }
                XCTAssertEqual(
                    mismatches.count, 0,
                    "\(count) groups, \(direction): \(differences). Expected 28pt outside and 8pt facing corners."
                )
            }
        }
    }

    func testEveryoneBadgeUsesTheProfileAvatarSizeAndCircularOutline() throws {
        for syncEnabled in [false, true] {
            for palette in [ThemePalette.dark, .light] {
                let renderer = ImageRenderer(content:
                    SettingsWorkspaceScopeBadge(syncEnabled: syncEnabled)
                        .environment(\.themePalette, palette)
                )
                let reference = ImageRenderer(content:
                    Circle().fill(Color.white)
                        .frame(width: SettingsWorkspaceHeaderMetrics.iconSize,
                               height: SettingsWorkspaceHeaderMetrics.iconSize)
                )
                renderer.scale = 1
                reference.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                let outline = try XCTUnwrap(reference.cgImage)
                XCTAssertEqual(image.width, 52)
                XCTAssertEqual(image.height, 52)
                let actual = try pixels(image)
                let expected = try pixels(outline)
                for index in stride(from: 3, to: actual.count, by: 4) where expected[index] == 0 {
                    XCTAssertEqual(actual[index], 0, "The glyph and border must stay within the circular badge.")
                }
                XCTAssertGreaterThan(actual[(26 * image.width + 1) * 4 + 3], 0)
                XCTAssertGreaterThan(actual[(1 * image.width + 26) * 4 + 3], 0)
            }
        }
    }

    func testGroupedControlHelperAndDividerShareTheTextKeyline() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let renderer = ImageRenderer(content:
                SettingsControlGroup {
                    VStack(spacing: 0) {
                        Color(red: 1, green: 0, blue: 0).frame(height: 40).settingsFormRowLayout()
                        Color(red: 0, green: 1, blue: 0).frame(height: 8).settingsHelperText()
                    }
                    Color.clear.frame(height: 40)
                }
                .frame(width: 320)
                .environment(\.layoutDirection, direction)
                .environment(\.themePalette, .dark)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bytes = try pixels(image)
            for (y, channel) in [(48, 0), (94, 1)] {
                let columns = (0..<image.width).filter {
                    let offset = (y * image.width + $0) * 4
                    return bytes[offset + channel] > 100 && bytes[offset + 2] < 10
                }
                XCTAssertEqual(columns, Array(28..<292),
                               "Controls and helpers share a 16pt group inset plus 12pt text inset.")
            }
            let divider = (0..<image.width).filter {
                bytes[(106 * image.width + $0) * 4] > bytes[(105 * image.width + $0) * 4] + 5
            }
            XCTAssertEqual(divider, Array(28..<292))
        }
    }

    func testGroupedFocusUsesTheActualInsetAndConcentricCornerSilhouette() throws {
        for illustrated in [false, true] {
            let renderer = ImageRenderer(content:
                SettingsControlGroup(illustrated: illustrated) {
                    SettingsFocusRow(isFocused: true) {
                        Color.clear.frame(height: 80)
                    }
                }
                .frame(width: 320)
                .background(Color.black)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
            )
            let reference = ImageRenderer(content:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 288, height: 80)
                    .padding(16)
                    .background(Color.black)
            )
            renderer.scale = 1
            reference.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let expected = try XCTUnwrap(reference.cgImage)
            XCTAssertEqual(image.width, 320)
            XCTAssertEqual(image.height, 112)
            let actualBytes = try pixels(image)
            let expectedBytes = try pixels(expected)
            let mismatches = stride(from: 0, to: actualBytes.count, by: 4).filter {
                (actualBytes[$0] > 240) != (expectedBytes[$0] > 240)
            }
            XCTAssertEqual(mismatches.count, 0,
                           "A 28pt outer corner and 16pt inset require a 12pt contained focus corner, without bleed.")
        }
    }

    func testGroupedIconDividersFollowTheTextColumnInBothDirections() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let renderer = ImageRenderer(content:
                SettingsControlGroup(dividerLeadingInset: SettingsRowMetrics.iconTitleInset) {
                    Color.clear.frame(height: 40)
                    Color.clear.frame(height: 40)
                }
                .frame(width: 320)
                .environment(\.layoutDirection, direction)
                .environment(\.themePalette, .dark)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bytes = try pixels(image)
            let columns = (0..<image.width).filter {
                bytes[(64 * image.width + $0) * 4] > bytes[(63 * image.width + $0) * 4] + 5
            }
            XCTAssertEqual(columns, direction == .leftToRight ? Array(74..<292) : Array(28..<246))
        }
    }

    func testIllustratedCardChromeUsesTheContainedCornerRadius() throws {
        let renderer = ImageRenderer(content:
            SettingsControlGroup(illustrated: true) {
                Button {} label: { Color.clear.frame(height: 80) }
                    .buttonStyle(ThemeCardButtonStyle(accent: .white, isSelected: true, cornerRadius: 32))
            }
            .frame(width: 320)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        )
        let reference = ImageRenderer(content:
            Button {} label: { Color.clear.frame(width: 288, height: 80) }
                .buttonStyle(ThemeCardButtonStyle(accent: .white, isSelected: true, cornerRadius: 12))
                .padding(16)
                .settingsGroupSurface(cornerRadius: 28)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        reference.scale = 1
        let actualBytes = try pixels(XCTUnwrap(renderer.cgImage))
        let expectedBytes = try pixels(XCTUnwrap(reference.cgImage))
        XCTAssertEqual(actualBytes.count, expectedBytes.count)
        let mismatches = zip(actualBytes, expectedBytes).filter { $0 != $1 }
        XCTAssertEqual(mismatches.count, 0, "Illustrated cards must derive their chrome from the containing group.")
    }

    func testStandaloneNavigationFocusMatchesTheIdleContainerSilhouette() throws {
        let focused = ImageRenderer(content:
            SettingsFocusRow(isFocused: true, size: .navigation) {
                Color.clear.frame(width: 320, height: 80)
            }
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        )
        let idle = ImageRenderer(content:
            RoundedRectangle(cornerRadius: SettingsRowMetrics.navigationCornerRadius, style: .continuous)
                .fill(Color.white)
                .frame(width: 320, height: 80)
                .background(Color.black)
        )
        focused.scale = 1
        idle.scale = 1
        let focusedPixels = try pixels(XCTUnwrap(focused.cgImage))
        let idlePixels = try pixels(XCTUnwrap(idle.cgImage))
        XCTAssertEqual(focusedPixels.map { $0 > 128 }, idlePixels.map { $0 > 128 },
                       "Focus must not tighten the standalone card's rounded outline.")
    }

    func testSeparatorsFollowTheWholeRowAndNeverTheLastVisibleItem() throws {
        for count in [3, 1, 2, 0] {
            let renderer = ImageRenderer(content:
                SettingsControlRows {
                    ForEach(0..<count, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            Color.red.frame(width: 100, height: 40)
                            if index == 0 {
                                // A helper belongs to the first row, not to a new row.
                                Color.green.frame(width: 100, height: 40)
                            }
                        }
                    }
                }
                .frame(width: 320, height: 240, alignment: .topLeading)
                .background(Color.black)
                .environment(\.themePalette, .dark)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bytes = try pixels(image)
            let lineRows = (0..<image.height).filter { y in
                let offset = (y * image.width + 280) * 4
                return bytes[offset] > 0 || bytes[offset + 1] > 0 || bytes[offset + 2] > 0
            }
            let expected = count < 2 ? [] : Array([88, 145].prefix(count - 1))
            XCTAssertEqual(lineRows, expected,
                           "\(count) rows: separate only adjacent controls, after the first row's helper.")
        }
    }

    func testFocusFillLeavesEightPointsOnEitherSideOfTheDivider() throws {
        for focused in 0..<3 {
            let renderer = ImageRenderer(content:
                SettingsControlRows {
                    ForEach(0..<3) { index in
                        SettingsFocusRow(isFocused: index == focused) {
                            Color.clear.frame(width: 320, height: 40)
                        }
                    }
                }
                .frame(width: 320, height: 200, alignment: .topLeading)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .environment(\.themePalette, .dark)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bytes = try pixels(image)
            let whiteRows = (0..<image.height).filter { bytes[($0 * image.width + 160) * 4] > 240 }
            let top = focused * 57
            XCTAssertEqual(whiteRows, Array(top..<(top + 40)),
                           "The focus fill must not bleed into the shared 8pt divider clearance.")
            for dividerY in [48, 105] {
                XCTAssertGreaterThan(bytes[(dividerY * image.width + 160) * 4], 0)
                for y in (dividerY - 8)...(dividerY + 8) where y != dividerY {
                    XCTAssertEqual(bytes[(y * image.width + 160) * 4], 0)
                }
            }
        }
    }

    func testCategorySeparatorsStartAtTheIconRowsTextColumnInBothDirections() throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let renderer = ImageRenderer(content:
                SettingsControlRows(dividerLeadingInset: SettingsRowMetrics.iconTitleInset) {
                    Color.clear.frame(height: 40)
                    Color.clear.frame(height: 40)
                }
                .frame(width: 320)
                .background(Color.black)
                .environment(\.layoutDirection, direction)
                .environment(\.themePalette, .dark)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bytes = try pixels(image)
            let lineColumns = (0..<image.width).filter { bytes[(48 * image.width + $0) * 4] > 0 }
            XCTAssertEqual(lineColumns, direction == .leftToRight ? Array(58..<320) : Array(0..<262))
        }
    }

    func testIllustratedGroupsUseSixteenPointPaddingAndGapWithoutADivider() throws {
        let renderer = ImageRenderer(content:
            SettingsControlGroup(illustrated: true) {
                Color(red: 1, green: 0, blue: 0).frame(height: 40)
                Color(red: 0, green: 1, blue: 0).frame(height: 40)
            }
            .frame(width: 320)
            .environment(\.themePalette, .dark)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bytes = try pixels(image)
        XCTAssertEqual(image.height, 128)
        let redRows = (0..<image.height).filter {
            let offset = ($0 * image.width + 160) * 4
            return bytes[offset] > 240 && bytes[offset + 1] < 10
        }
        XCTAssertEqual(redRows, Array(16..<56))
        let redColumns = (0..<image.width).filter {
            let offset = (32 * image.width + $0) * 4
            return bytes[offset] > 240 && bytes[offset + 1] < 10
        }
        XCTAssertEqual(redColumns, Array(16..<304))
        for y in 57..<72 {
            let offset = (y * image.width + 160) * 4
            let previous = ((y - 1) * image.width + 160) * 4
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - Int(bytes[previous + channel])), 1,
                                         "The surface gradient must not contain a separator in the 16pt gap.")
            }
        }
        let greenRows = (0..<image.height).filter {
            let offset = ($0 * image.width + 160) * 4
            return bytes[offset + 1] > 100 && bytes[offset] < 10
        }
        XCTAssertEqual(greenRows, Array(72..<112))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
