import CoreModels
@testable import CoreUI
@testable import FeatureSettings
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SettingsControlRowsHostedTests: XCTestCase {
    func testNavigationLinksAndControlsKeepTheirFocusFillAcrossBackgroundPreferences() async throws {
        let sceneDeadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = SettingsSurfaceFocusHost(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let system = try XCTUnwrap(UIFocusSystem(for: window))

        for kind in SettingsSurfaceFixture.Kind.allCases {
            let appearance = SettingsSurfaceAppearance()
            host.rootView = AnyView(SettingsSurfaceFixture(kind: kind, appearance: appearance))
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(5)
            while focusItems(in: host.view).isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let item = try XCTUnwrap(focusItems(in: host.view).first, kind.rawValue)
            host.target = item
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            let focusDeadline = ContinuousClock.now + .seconds(5)
            while system.focusedItem !== item, ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(system.focusedItem === item, kind.rawValue)
            host.target = nil
            let originalFrame = try focusFrame(item, in: window)

            for (name, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                appearance.palette = palette
                for (gradient, reduced) in [(true, false), (false, false), (false, true), (true, true), (true, false)] {
                    appearance.gradient = gradient
                    appearance.reduced = reduced
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    XCTAssertTrue(system.focusedItem === item, "Changing appearance must retain \(kind.rawValue) focus.")
                    let frame = try focusFrame(item, in: window)
                    XCTAssertEqual(frame, originalFrame, "Appearance changes must not move or resize the focused row.")
                    guard window.bounds.contains(frame), frame.width > 0, frame.height > 16 else {
                        XCTFail("The focused row must be visible inside the captured window: \(frame)")
                        return
                    }
                    let image = DetailTransitionSnapshot.image(of: window)
                    let cgImage = try XCTUnwrap(image.cgImage)
                    let scale = CGFloat(cgImage.width) / window.bounds.width
                    let bytes = try pixels(cgImage)
                    let label = "\(kind.rawValue)-\(name)-gradient-\(gradient)-reduced-\(reduced)"
                    for fraction in [CGFloat(0.25), 0.5, 0.75] {
                        for y in [frame.minY + 8, frame.maxY - 8] {
                            let x = frame.minX + frame.width * fraction
                            let offset = (Int(y * scale) * cgImage.width + Int(x * scale)) * 4
                            XCTAssertTrue((0..<3).allSatisfy {
                                palette.isLight ? bytes[offset + $0] < 20 : bytes[offset + $0] > 235
                            }, "\(label): the focused row must paint its contrasting fill, not its idle surface.")
                        }
                    }
                    if !gradient && !reduced {
                        let attachment = XCTAttachment(image: image)
                        attachment.name = label
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        let crop = try XCTUnwrap(cgImage.cropping(to: frame
                            .applying(CGAffineTransform(scaleX: scale, y: scale))))
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        try VNImageRequestHandler(cgImage: crop).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: " ")
                        XCTAssertTrue(text.contains(kind.title), "\(label): keep the focused title readable: \(text)")
                        if kind == .homeEditor {
                            XCTAssertTrue(text.contains("Tab order and visibility apply to all libraries."),
                                          "\(label): keep secondary text readable: \(text)")
                        }
                    }
                }
            }
        }
    }

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

    func testStandaloneNavigationOwnsItsIdleSurfaceAcrossBackgroundPreferences() throws {
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            for (gradient, reduced) in [(true, false), (false, false), (false, true), (true, true)] {
                let content = Color.clear.frame(width: 320, height: 80)
                let row = SettingsFocusRow(isFocused: false, size: .navigation) { content }
                let reference = content.settingsGroupSurface(cornerRadius: SettingsRowMetrics.navigationCornerRadius)
                let images = try [AnyView(row), AnyView(reference)].map { view in
                    let renderer = ImageRenderer(content: view
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                        .environment(\.plozzReduceTransparency, reduced))
                    renderer.scale = 1
                    return try pixels(XCTUnwrap(renderer.cgImage))
                }
                XCTAssertEqual(images[0], images[1], "Moving the idle surface must preserve its existing appearance.")
            }
        }
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

    private func focusItems(in view: UIView) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [view]
        var seen = Set<ObjectIdentifier>()
        var seenItems = Set<ObjectIdentifier>()
        var items: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            for item in container.focusItems(in: container.coordinateSpace.convert(view.bounds, from: view)) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let child = item as? UIView { containers.append(child) }
                if item.canBecomeFocused, !(item is UIScrollView),
                   seenItems.insert(ObjectIdentifier(item)).inserted {
                    items.append(item)
                }
            }
        }
        return items
    }

    private func focusFrame(_ item: any UIFocusItem, in window: UIWindow) throws -> CGRect {
        if let view = item as? UIView { return view.convert(view.bounds, to: window) }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return try XCTUnwrap(nil as CGRect?, "The focused control must provide its coordinate space.")
    }
}

@MainActor
private final class SettingsSurfaceFocusHost: UIHostingController<AnyView> {
    weak var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

@MainActor @Observable
private final class SettingsSurfaceAppearance {
    var palette = ThemePalette.dark
    var gradient = true
    var reduced = false
}

private struct SettingsSurfaceFixture: View {
    enum Kind: String, CaseIterable {
        case page, route, homeEditor, action, toggle, checkmark, menu, stepper

        var title: String {
            switch self {
            case .page: "Theme"
            case .route: "Artwork"
            case .homeEditor: "Library Navigation"
            case .action: "Customize labels"
            case .toggle: "Gradient Backgrounds"
            case .checkmark: "Dark"
            case .menu: "Layout"
            case .stepper: "Text size"
            }
        }
    }
    let kind: Kind
    let appearance: SettingsSurfaceAppearance

    var body: some View {
        NavigationStack {
            control
                .frame(width: 960, height: 720, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsPageBackground()
        }
        .environment(\.themePalette, appearance.palette)
        .environment(\.colorScheme, appearance.palette.isLight ? .light : .dark)
        .environment(\.gradientBackgroundsEnabled, appearance.gradient)
        .environment(\.plozzReduceTransparency, appearance.reduced)
        .environment(\.locale, Locale(identifier: "en"))
        .transaction { $0.disablesAnimations = true }
    }

    @ViewBuilder private var control: some View {
        switch kind {
        case .page, .route:
            SettingsFormLayout(title: Text("Appearance"), rows: [
                kind == .page
                    ? SettingsSplitRow(id: "theme", title: "Theme") { EmptyView() }.page()
                    : SettingsSplitRow(id: "artwork", title: "Artwork") { EmptyView() }.destination(.artwork)
            ])
        case .homeEditor:
            HomeEditorLink { EmptyView() } label: {
                HomeEditorRowLabel(
                    title: Text("Library Navigation"),
                    subtitle: Text("Tab order and visibility apply to all libraries."),
                    titleSymbol: "arrow.up.arrow.down"
                )
            }
        default:
            SettingsControlGroup {
                switch kind {
                case .action:
                    Button {} label: { SettingsDisclosureLabel { Text("Customize labels") } }
                        .buttonStyle(SettingsFormButtonStyle())
                case .toggle:
                    Toggle("Gradient Backgrounds", isOn: .constant(false))
                case .checkmark:
                    SettingsCheckableRow(title: Text("Dark"), isChecked: true) {}
                case .menu:
                    SettingsMenuRow(title: "Layout", value: Text("Classic")) {
                        Button("Classic") {}
                    }
                case .stepper:
                    SettingsStepper(options: [1, 2, 3], selection: .constant(2), label: "Text size",
                                    verbatimTitle: { "\($0)" })
                default:
                    EmptyView()
                }
            }
        }
    }
}
