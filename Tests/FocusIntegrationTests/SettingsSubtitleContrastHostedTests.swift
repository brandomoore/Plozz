import CoreUI
@testable import AppShell
@testable import FeatureSettings
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SettingsSubtitleContrastHostedTests: XCTestCase {
    func testSharedTextTiersAndLabelIconsInvertWithRealRowFocus() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for (name, scheme, palette) in [
            ("black", ColorScheme.dark, ThemePalette.pureBlack),
            ("dark", .dark, .dark),
            ("light", .light, .light)
        ] {
            let model = SettingsTierFocusModel()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView:
                SettingsTierFocusFixture(model: model)
                    .environment(\.themePalette, palette)
                    .environment(\.colorScheme, scheme)
                    .background(palette.settingsBackground)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }

            for focusedRow in [0, 1, 2, 0] {
                model.requestedRow = focusedRow
                try await waitUntil { model.focusedRow == focusedRow && model.frames.count == 10 }
                window.layoutIfNeeded()
                let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                let focusFrame = try XCTUnwrap(
                    NavigationRowFocusRequester.frame(of: focus, relativeTo: window)
                )
                let rowFrame = try XCTUnwrap(model.frames["row\(focusedRow)"])
                XCTAssertTrue(focusFrame.contains(CGPoint(x: rowFrame.midX, y: rowFrame.midY)))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "shared-row-tiers-\(name)-focus-\(focusedRow)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let bitmap = try XCTUnwrap(image.cgImage)
                let pixels = try rgbaPixels(bitmap)
                let regions: [(String, Int?, Double)] = [
                    ("title", 0, 4.5), ("subtitle", 0, 4.5), ("deviceIcon", 0, 3),
                    ("keyboard", 1, 3), ("chevron", 1, 3), ("labelIcon", 2, 3),
                    ("outside", nil, 4.5)
                ]
                for (key, row, minimumContrast) in regions {
                    let frame = try XCTUnwrap(model.frames[key]).intersection(window.bounds).integral
                    let backgroundFrame = try XCTUnwrap(model.frames[row.map { "row\($0)" } ?? key])
                    let background = luminance(
                        pixels, x: Int(backgroundFrame.maxX - 2), y: Int(backgroundFrame.midY),
                        width: bitmap.width
                    )
                    if row == focusedRow {
                        XCTAssertEqual(background, scheme == .dark ? 1 : 0, accuracy: 0.05)
                    }
                    var readablePixels = 0
                    for y in Int(frame.minY)..<Int(frame.maxY) {
                        for x in Int(frame.minX)..<Int(frame.maxX) {
                            let ink = luminance(pixels, x: x, y: y, width: bitmap.width)
                            let contrast = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                            if contrast >= minimumContrast { readablePixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(
                        readablePixels, 50,
                        "\(name), \(key), focus \(focusedRow): glyphs must contrast with their own surface."
                    )
                }
            }
        }
    }

    func testDiscoveryAndLibrarySubtitlesStayReadableWhenFocusMoves() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appearances: [(String, ColorScheme, ThemePalette)] = [
            ("dark", .dark, .dark),
            ("black", .dark, .pureBlack),
            ("light", .light, .light)
        ]

        for (name, scheme, palette) in appearances {
            let model = SettingsSubtitleFocusModel()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = UIHostingController(rootView:
                SettingsSubtitleFocusFixture(model: model)
                    .environment(\.themePalette, palette)
                    .environment(\.colorScheme, scheme)
                    .background(palette.settingsBackground)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }

            for focusedRow in [0, 1, 0] {
                model.requestedRow = focusedRow
                try await waitUntil { model.focusedRow == focusedRow && model.frames.count == 2 }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "settings-subtitles-\(name)-focus-\(focusedRow)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let bitmap = try XCTUnwrap(image.cgImage)
                let pixels = try rgbaPixels(bitmap)

                for row in 0...1 {
                    let frame = try XCTUnwrap(model.frames[row])
                    let background = luminance(
                        pixels, x: Int(frame.maxX - 6), y: Int(frame.midY), width: bitmap.width
                    )
                    if row == focusedRow {
                        XCTAssertEqual(background, scheme == .dark ? 1 : 0, accuracy: 0.05,
                                       "The production row must actually show its inverted focus background.")
                    }
                    // Exclude the title, checkmark and padding; only subtitle glyphs can pass.
                    let subtitle = CGRect(
                        x: frame.minX + 20, y: frame.midY + 2,
                        width: frame.width - 100, height: frame.height / 2 - 14
                    ).intersection(window.bounds).integral
                    XCTAssertGreaterThan(subtitle.height, 10)
                    var readablePixels = 0
                    for y in Int(subtitle.minY)..<Int(subtitle.maxY) {
                        for x in Int(subtitle.minX)..<Int(subtitle.maxX) {
                            let ink = luminance(pixels, x: x, y: y, width: bitmap.width)
                            let contrast = (max(ink, background) + 0.05) / (min(ink, background) + 0.05)
                            if contrast >= 4.5 { readablePixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(readablePixels, 100,
                                         "\(name), row \(row), focused \(focusedRow): subtitle must retain body-text contrast.")
                }
            }
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func luminance(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> Double {
        let offset = (y * width + x) * 4
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixels[offset])
            + 0.7152 * linear(pixels[offset + 1])
            + 0.0722 * linear(pixels[offset + 2])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The settings row must acquire real tvOS focus.")
    }
}

@MainActor @Observable
private final class SettingsTierFocusModel {
    var requestedRow = 0
    var focusedRow: Int?
    var frames: [String: CGRect] = [:]
}

private struct SettingsTierFocusFixture: View {
    let model: SettingsTierFocusModel
    @FocusState private var focusedRow: Int?

    var body: some View {
        VStack(spacing: 32) {
            Button {} label: {
                HStack(alignment: .top, spacing: 20) {
                    Image(systemName: "externaldrive.connected.to.line.below.fill")
                        .font(.system(size: 32)).frame(width: 44, height: 44)
                        .plozzForeground(.secondary)
                        .modifier(Region(model: model, name: "deviceIcon"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Media Server").font(.headline).plozzForeground(.primary)
                            .modifier(Region(model: model, name: "title"))
                        Text(verbatim: "192.0.2.1 · SFTP · SMB · WebDAV detected")
                            .font(.subheadline).plozzForeground(.secondary)
                            .modifier(Region(model: model, name: "subtitle"))
                    }
                    Spacer()
                }
                .padding(.vertical, 14).padding(.horizontal, 12)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
            .focused($focusedRow, equals: 0)
            .modifier(Region(model: model, name: "row0"))

            Button {} label: {
                HStack(spacing: 20) {
                    Image(systemName: "keyboard").font(.system(size: 30)).frame(width: 44, height: 44)
                        .plozzForeground(.secondary)
                        .modifier(Region(model: model, name: "keyboard"))
                    Text(verbatim: "Enter an address manually").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.forward").plozzForeground(.tertiary)
                        .modifier(Region(model: model, name: "chevron"))
                }
                .padding(.vertical, 14).padding(.horizontal, 12)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
            .focused($focusedRow, equals: 1)
            .modifier(Region(model: model, name: "row1"))

            Button {} label: {
                HStack {
                    Label {
                        Text(verbatim: "Settings label")
                    } icon: {
                        Image(systemName: "gearshape.fill").font(.system(size: 32))
                            .modifier(Region(model: model, name: "labelIcon"))
                    }
                    .labelStyle(SettingsIconLabelStyle())
                    Spacer()
                }
                .padding(14)
            }
            .buttonStyle(SettingsFocusButtonStyle())
            .focused($focusedRow, equals: 2)
            .modifier(Region(model: model, name: "row2"))

            Text(verbatim: "Supporting text outside a focus row")
                .plozzForeground(.secondary)
                .padding(.horizontal, 20)
                .modifier(Region(model: model, name: "outside"))
        }
        .frame(width: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.requestedRow, initial: true) { _, row in focusedRow = row }
        .onChange(of: focusedRow) { _, row in model.focusedRow = row }
    }

    private struct Region: ViewModifier {
        let model: SettingsTierFocusModel
        let name: String

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                model.frames[name] = $0
            }
        }
    }
}

@MainActor @Observable
private final class SettingsSubtitleFocusModel {
    var requestedRow = 0
    var focusedRow: Int?
    var frames: [Int: CGRect] = [:]
}

private struct SettingsSubtitleFocusFixture: View {
    let model: SettingsSubtitleFocusModel
    @FocusState private var focusedRow: Int?

    var body: some View {
        VStack(spacing: 32) {
            ForEach(0..<2) { row in
                SettingsCheckableRow(
                    title: Text(verbatim: row == 0 ? "Simkl" : "Movies"),
                    subtitle: Text(verbatim: row == 0
                        ? "Movies and shows people are watching this week."
                        : "Example Server"),
                    isChecked: true,
                    prominence: .secondary,
                    flushLeading: false,
                    action: {}
                )
                .focused($focusedRow, equals: row)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.frames[row] = $0
                }
            }
        }
        .frame(width: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.requestedRow, initial: true) { _, row in focusedRow = row }
        .onChange(of: focusedRow) { _, row in model.focusedRow = row }
    }
}
