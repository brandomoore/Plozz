#if os(iOS)
import CoreImage
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class SettingsCommunityPresentationTests: XCTestCase {
    private var capturedImages: [CGImage] = []

    func testCompactSettingsTitleStartsLeadingAndCentersOnlyAfterScrolling() async throws {
        let model = PlozziOSAppModel()
        let originalTheme = model.settings.theme.theme
        model.settings.theme.theme = .dark
        defer { model.settings.theme.theme = originalTheme }
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (size, textSize) in [
            (CGSize(width: 320, height: 568), DynamicTypeSize.large),
            (CGSize(width: 390, height: 844), .large),
            (CGSize(width: 440, height: 956), .large),
            (CGSize(width: 390, height: 844), .accessibility3)
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView:
                PlozziOSSettingsView(appModel: model, onClose: {}, systemColorScheme: .dark)
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.dynamicTypeSize, textSize)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.makeKeyAndVisible()
            try await waitForHostedLayout(window)
            let bar = try XCTUnwrap(navigationBar(in: window))
            XCTAssertEqual(bar.topItem?.title, "Settings")
            XCTAssertLessThanOrEqual(bar.bounds.height, 64, "Settings must not reserve a large-title block.")
            let expanded = try settingsTitleFrame(in: window, name: "settings-leading-\(Int(size.width))-\(textSize)")
            XCTAssertEqual(expanded.minX, 16, accuracy: 3,
                           "The resting title must follow the leading card keyline.")
            let scroll = try XCTUnwrap(scrollViews(in: window).first)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 300), animated: false)
            try await waitForHostedLayout(window)
            let collapsed = try settingsTitleFrame(in: window, name: "settings-scrolled-\(Int(size.width))-\(textSize)")
            XCTAssertEqual(collapsed.midX, size.width / 2, accuracy: 4, "Only the scrolled title is centered.")
            XCTAssertLessThanOrEqual(bar.bounds.height, 64)
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            try await waitForHostedLayout(window)
            let restored = try settingsTitleFrame(in: window, name: "settings-restored-\(Int(size.width))-\(textSize)")
            XCTAssertEqual(restored.minX, 16, accuracy: 3,
                           "Returning to the top restores the aligned leading title.")
        }
    }

    private func settingsTitleFrame(in window: UIWindow, name: String) throws -> CGRect {
        _ = try recognizedText(in: window, name: name)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(capturedImages.last)).perform([request])
        let label = try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string == "Settings" })
        let bounds = label.boundingBox
        return CGRect(
            x: bounds.minX * window.bounds.width, y: (1 - bounds.maxY) * window.bounds.height,
            width: bounds.width * window.bounds.width, height: bounds.height * window.bounds.height
        )
    }

    private func navigationBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        return view.subviews.lazy.compactMap { self.navigationBar(in: $0) }.first
    }

    func testUpdateDialogShowsDiscordJoinButtonWithoutQRCodeOnPhoneAndPad() async throws {
        let suite = "ReleaseNotesCommunity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReleaseNotesStore(defaults: defaults)
        let catalog = try ReleaseNotesCatalog.load()
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        for light in [false, true] {
            for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844), CGSize(width: 768, height: 1024)] {
                store.saveLastSeenReleaseID("release/048")
                let model = ReleaseNotesModel(
                    catalog: catalog, currentReleaseID: "release/049", store: store, platform: .iOS
                )
                model.prepareForStartup()
                let text = try await renderedText(
                    ReleaseNotesStartupView(model: model), size: size, light: light,
                    name: "update-discord-\(Int(size.width))-\(light)", initialOnly: true
                )
                XCTAssertTrue(text.contains("Join the new Discord community"), text)
                XCTAssertTrue(text.contains("Join Discord"), text)
                let image = try XCTUnwrap(capturedImages.last)
                let urls = detector.features(in: CIImage(cgImage: image))
                    .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
                XCTAssertTrue(urls.isEmpty, "The mobile invite must be a direct button, not a QR code.")
                try assertJoinButtonFill(in: image, light: light)
            }
        }
    }

    func testExpandedCommunityCodesRemainScannableOnNarrowPhone() async throws {
        let content = ScrollView {
            PlozziOSCommunitySettingsSection(showsQRCodes: true)
        }
        .settingsPageSurface()
        _ = try await renderedText(
            content, size: CGSize(width: 320, height: 568),
            light: false, name: "compact-expanded-community"
        )
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let urls = capturedImages.flatMap { image in
            detector.features(in: CIImage(cgImage: image))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        XCTAssertEqual(Set(urls), [AppLinks.discord.absoluteString, AppLinks.repository.absoluteString])
    }

    func testCommunityArtworkIsAvailableInMobileAppResources() throws {
        for asset in ["DiscordMark", "GitHubMark", "DiscordLockup", "GitHubLockup"] {
            let image = try XCTUnwrap(UIImage(named: asset), "\(asset) must be bundled for iOS, not only tvOS.")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    func testCompactSettingsExposeCommunityLinksInBothThemes() async throws {
        let model = PlozziOSAppModel()
        let originalTheme = model.settings.theme.theme
        defer { model.settings.theme.theme = originalTheme }
        for light in [false, true] {
            model.settings.theme.theme = light ? .light : .dark
            for size in [CGSize(width: 390, height: 844), CGSize(width: 320, height: 568)] {
                let content = PlozziOSSettingsView(
                    appModel: model,
                    onClose: {},
                    systemColorScheme: light ? .light : .dark
                )
                .environment(\.horizontalSizeClass, .compact)
                let text = try await renderedText(
                    content, size: size, light: light,
                    name: "compact-settings-community-\(Int(size.width))-\(light)"
                )
                assertCommunity(in: text)
                XCTAssertTrue(text.contains("Help & Diagnostics"), text)
                XCTAssertTrue(text.contains("Version"), text)
            }
        }
    }

    func testRegularAboutKeepsCommunityLinksInBothThemes() async throws {
        for light in [false, true] {
            for size in [CGSize(width: 768, height: 1024), CGSize(width: 844, height: 390)] {
                let content = NavigationStack {
                    PlozziOSAboutSettingsView(
                        hasAccounts: false,
                        isKidsProfile: false,
                        onSignOutAll: {}
                    )
                }
                let text = try await renderedText(
                    content, size: size, light: light,
                    name: "regular-about-community-\(Int(size.width))-\(light)"
                )
                assertCommunity(in: text)
            }
        }
    }

    private func assertJoinButtonFill(in image: CGImage, light: Bool) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let label = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string == "Join Discord"
        })
        let point = CGPoint(
            x: floor(label.boundingBox.minX * CGFloat(image.width)) - 8,
            y: floor((1 - label.boundingBox.midY) * CGFloat(image.height))
        )
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThanOrEqual(Int(rgba[0...2].max()!) - Int(rgba[0...2].min()!), 2, "Use Plozz's monochrome CTA, not system blue.")
        if light {
            XCTAssertLessThan(rgba[0], 52)
        } else {
            XCTAssertGreaterThan(rgba[0], 230)
        }
    }

    private func assertCommunity(in text: String, file: StaticString = #filePath, line: UInt = #line) {
        for label in ["Discord", "GitHub", "QR Codes"] {
            XCTAssertTrue(text.contains(label), "Missing \(label): \(text)", file: file, line: line)
        }
    }

    private func renderedText(
        _ content: some View, size: CGSize, light: Bool, name: String, initialOnly: Bool = false
    ) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = light ? .light : .dark
        window.rootViewController = UIHostingController(rootView:
            content
                .environment(\.themePalette, light ? .light : .dark)
                .environment(\.colorScheme, light ? .light : .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let scroll = try XCTUnwrap(scrollViews(in: window).first)
        if initialOnly {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            return try recognizedText(in: window, name: name)
        }
        for _ in 0..<5 {
            scroll.setContentOffset(CGPoint(
                x: 0,
                y: max(-scroll.adjustedContentInset.top,
                       scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            ), animated: false)
            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
        }
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        let bottomText = try recognizedText(in: window, name: "\(name)-bottom")
        scroll.setContentOffset(CGPoint(
            x: 0,
            y: max(-scroll.adjustedContentInset.top, scroll.contentOffset.y - scroll.bounds.height * 0.55)
        ), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        return bottomText + " " + (try recognizedText(in: window, name: "\(name)-above-bottom"))
    }

    private func recognizedText(in window: UIWindow, name: String) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        let bitmap = try XCTUnwrap(image.cgImage)
        capturedImages.append(bitmap)
        try VNImageRequestHandler(cgImage: bitmap).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
