import CoreModels
import CoreImage
import CoreUI
@testable import FeatureSettings
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SettingsCommunityLinksHostedTests: XCTestCase {
    func testDiscordMarkDoesNotDistortOneSideOfTheSilhouette() throws {
        let mark = try XCTUnwrap(UIImage(named: "DiscordMark"))
        let size = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            mark.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        let bitmap = try XCTUnwrap(image.cgImage)
        let pixels = try rgba(bitmap)
        var ink = 0
        var asymmetric = 0
        for y in 0..<size {
            for x in 0..<size {
                let filled = pixels[(y * size + x) * 4 + 3] > 128
                let mirrored = pixels[(y * size + size - 1 - x) * 4 + 3] > 128
                if filled { ink += 1 }
                if filled != mirrored { asymmetric += 1 }
            }
        }
        XCTAssertGreaterThan(ink, 4_000)
        // The original mark is almost symmetric; the SVG asset compiler warped its left side.
        XCTAssertLessThan(Double(asymmetric) / Double(max(ink, 1)), 0.02)
        let attachment = XCTAttachment(image: image)
        attachment.name = "discord-mark-silhouette"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCommunityLogosHaveComparableVisibleAreaAtMobileAndTVSizes() throws {
        for height in [CGFloat(32), CGFloat(40)] {
            var areas: [SettingsCommunityLogo.Brand: Double] = [:]
            for brand in SettingsCommunityLogo.Brand.allCases {
                let renderer = ImageRenderer(content: SettingsCommunityLogo(brand: brand, height: height))
                renderer.scale = 4
                renderer.isOpaque = false
                let image = try XCTUnwrap(renderer.cgImage)
                let pixels = try rgba(image)
                let area = stride(from: 3, to: pixels.count, by: 4).reduce(0.0) {
                    $0 + Double(pixels[$1]) / 255
                }
                XCTAssertGreaterThan(area, 1_000)
                areas[brand] = area
            }
            let discord = try XCTUnwrap(areas[.discord])
            let github = try XCTUnwrap(areas[.github])
            XCTAssertEqual(discord / github, 1, accuracy: 0.08, "Balance visible artwork, not bounding-box height.")
        }
    }

    func testAboutCodesDecodeSideBySideInBothThemes() async throws {
        for (asset, aspect) in [("DiscordLockup", 635.303 / 96), ("GitHubLockup", 416.0 / 95)] {
            let image = try XCTUnwrap(UIImage(named: asset))
            XCTAssertEqual(image.size.width / image.size.height, aspect, accuracy: 0.01)
        }
        for scheme in [ColorScheme.light, .dark] {
            let codes = try await renderCodes(
                SettingsAboutSection(
                    version: "1.0",
                    build: "1",
                    repoURL: AppLinks.repository.absoluteString,
                    showsReleaseNotes: true,
                    onActivate: {}
                )
                .frame(width: PlozzTheme.Metrics.settingsContentMaxWidth),
                scheme: scheme,
                name: "about-\(scheme)"
            )
            XCTAssertEqual(codes[0].bounds.midY, codes[1].bounds.midY, accuracy: 1)
            XCTAssertGreaterThan(codes[1].bounds.midX - codes[0].bounds.midX, 180, "Discord comes first.")
        }
    }

    func testNarrowCodesStackWithoutShrinkingInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let codes = try await renderCodes(
                SettingsCommunityLinks().frame(width: 320),
                scheme: scheme,
                name: "compact-\(scheme)"
            )
            XCTAssertEqual(codes[0].bounds.midX, codes[1].bounds.midX, accuracy: 1)
            XCTAssertGreaterThan(codes[0].bounds.midY - codes[1].bounds.midY, 180, "Discord stays above GitHub.")
        }
    }

    private func renderCodes(
        _ content: some View,
        scheme: ColorScheme,
        name: String
    ) async throws -> [CIQRCodeFeature] {
        let deadline = Date().addingTimeInterval(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let palette = scheme == .dark ? ThemePalette.dark : .light
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView:
            content
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, scheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.settingsBackground)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let bitmap = try XCTUnwrap(image.cgImage)
        let codes = detector.features(in: CIImage(cgImage: bitmap)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(Set(codes.compactMap(\.messageString)), [
            "https://discord.gg/YkXnmB8rcF",
            "https://github.com/brandomoore/Plozz"
        ])
        let pair = try XCTUnwrap(codes.count == 2 ? codes : nil, "Both codes must decode.")
        for code in codes {
            XCTAssertGreaterThan(code.bounds.width, 115, "Keep the 180-point scan card.")
        }
        return pair.sorted { ($0.messageString ?? "") < ($1.messageString ?? "") }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
