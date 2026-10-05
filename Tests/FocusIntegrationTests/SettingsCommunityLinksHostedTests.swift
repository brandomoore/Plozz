import CoreModels
import CoreImage
import CoreUI
@testable import FeatureSettings
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SettingsCommunityLinksHostedTests: XCTestCase {
    func testUpdateDialogShowsScannableFocusableDiscordCardInBothThemes() async throws {
        let suite = "ReleaseNotesCommunity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReleaseNotesStore(defaults: defaults)
        let catalog = try ReleaseNotesCatalog.load()
        for scheme in [ColorScheme.light, .dark] {
            store.saveLastSeenReleaseID("release/048")
            let model = ReleaseNotesModel(catalog: catalog, currentReleaseID: "release/049", store: store)
            model.prepareForStartup()
            _ = try await renderCodes(
                ReleaseNotesStartupView(model: model),
                scheme: scheme, name: "update-discord-\(scheme)",
                expectedURLs: [AppLinks.discord.absoluteString], requiresDiscordFocus: true
            )
        }
    }

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
        name: String,
        expectedURLs: Set<String> = [AppLinks.discord.absoluteString, AppLinks.repository.absoluteString],
        requiresDiscordFocus: Bool = false
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
        let host = CommunityFocusHost(rootView:
            content
                .environment(\.themePalette, palette)
                .environment(\.colorScheme, scheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.settingsBackground)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        if requiresDiscordFocus {
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let deadline = ContinuousClock.now + .seconds(3)
            while system.focusedItem == nil, ContinuousClock.now < deadline {
                system.requestFocusUpdate(to: host)
                system.updateFocusIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let items = focusItems(in: window)
            let detail = items.map { "\(type(of: $0)): \($0.frame)" }.joined(separator: "\n")
            let card = try XCTUnwrap(items.first {
                $0.frame.height >= 180 && $0.frame.width > 500
            }, detail)
            let initialFocus = try XCTUnwrap(system.focusedItem)
            XCTAssertLessThan(initialFocus.frame.width, 200, "Done retains initial focus, not the card.\n\(detail)")
            host.target = card
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            XCTAssertTrue(system.focusedItem === card, "The QR card must be reachable by native focus.")
            host.target = nil
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
        }
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
        XCTAssertEqual(Set(codes.compactMap(\.messageString)), expectedURLs)
        let decoded = try XCTUnwrap(codes.count == expectedURLs.count ? codes : nil, "Every expected code must decode.")
        for code in codes {
            XCTAssertGreaterThan(code.bounds.width, 115, "Keep the 180-point scan card.")
        }
        return decoded.sorted { ($0.messageString ?? "") < ($1.messageString ?? "") }
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
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

private final class CommunityFocusHost<Content: View>: UIHostingController<Content> {
    weak var target: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}
