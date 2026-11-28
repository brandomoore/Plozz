#if os(iOS)
import CoreImage
import CoreModels
import CoreUI
import FeatureAuth
import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

private struct SettingsLanguageScopeProbe: View {
    @Environment(\.locale) private var locale
    let update: (String?) -> Void

    var body: some View {
        Color.clear.frame(height: 1)
            .onChange(of: locale, initial: true) { _, value in
                update(value.language.languageCode?.identifier)
            }
    }
}

@MainActor
final class SettingsCommunityPresentationTests: XCTestCase {
    private var capturedImages: [CGImage] = []

    func testSeerrBelongsToTheActiveProfileButRemainsHiddenForKids() async throws {
        let suite = "SeerrProfileCategory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageSettingsModel(store: AppLanguageSettingsStore(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1300)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for isKids in [false, true] {
            var headerFrame = CGRect.zero
            var sectionFrame = CGRect.zero
            var firstRowFrame = CGRect.zero
            window.rootViewController = UIHostingController(rootView:
                PlozziOSProfileSettingsSection(
                    showsParentalControls: isKids,
                    isKidsProfile: isKids,
                    appLanguage: language
                ) {
                    PlozziOSProfileIdentityHeader(
                        profile: Profile(id: "profile-header", name: "Current profile"),
                        profileCount: 2, onSwitchProfile: {}
                    )
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerFrame = $0 }
                } row: { category in
                    PlozziOSSettingsCategoryLabel(category: category, accounts: [], isAccountIncluded: { _ in true })
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            if category == .playback { firstRowFrame = $0 }
                        }
                } management: {
                    EmptyView()
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sectionFrame = $0 }
                .frame(width: 390)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.gradientBackgroundsEnabled, false)
                .background(Color.black)
            )
            window.makeKeyAndVisible()
            try await waitForHostedLayout(window)
            let text = try recognizedText(in: window, name: "Profile settings Seerr kids-\(isKids)")
            XCTAssertEqual(text.components(separatedBy: "Seerr").count - 1, isKids ? 0 : 1, text)
            XCTAssertEqual(text.components(separatedBy: "Downloads").count - 1, isKids ? 0 : 1, text)
            XCTAssertEqual(text.components(separatedBy: "Current profile").count - 1, 1, text)
            XCTAssertFalse(text.contains("Saved to your profile"), text)
            XCTAssertGreaterThan(headerFrame.height, 0)
            XCTAssertEqual(headerFrame.minY, sectionFrame.minY, accuracy: 1,
                           "The identity belongs inside the top of the settings card, not a separate section.")
            XCTAssertGreaterThanOrEqual(firstRowFrame.minY, headerFrame.maxY)
            XCTAssertLessThan(firstRowFrame.minY - headerFrame.maxY, MobileSettingsMetrics.sectionSpacing,
                              "There must not be a section gap between the profile header and its settings.")
        }
    }

    func testLanguagePickerUsesAppOwnedModelWithoutAnInheritedEnvironment() async throws {
        let suite = "SettingsLanguage-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLanguageSettingsStore(defaults: defaults)
        store.save(.explicit("en"))
        let language = AppLanguageSettingsModel(store: store)
        let app = PlozziOSAppModel(appLanguage: language)
        XCTAssertTrue(app.appLanguage === language)

        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var observedLanguage: String?
        window.rootViewController = UIHostingController(rootView:
            VStack {
                AppLanguageScope(model: app.appLanguage) {
                    SettingsLanguageScopeProbe { observedLanguage = $0 }
                }
                // Deliberately outside the scope: Settings can be hosted separately.
                List { PlozziOSSettingsLanguagePicker(appLanguage: app.appLanguage) }
            }
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for code in ["en", "de"] {
            app.appLanguage.language = .explicit(code)
            try await waitForHostedLayout(window)
            let text = try recognizedText(in: window, name: "settings-language-\(code)")
            XCTAssertTrue(text.contains(try XCTUnwrap(language.language.endonym)), text)
            XCTAssertEqual(observedLanguage, code)
            XCTAssertEqual(store.load(), .explicit(code))
        }
        app.appLanguage.language = .system
        try await waitForHostedLayout(window)
        XCTAssertEqual(observedLanguage, "en")
        XCTAssertEqual(store.load(), .system)
    }

    func testCategoryTitlesAlignIncludingScreensAndNavigation() throws {
        for (width, textSize) in [(320.0, DynamicTypeSize.large), (390.0, .accessibility3), (500.0, .large)] {
            let renderer = ImageRenderer(content:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ProfileSettingsCategory.allCases) { category in
                        PlozziOSSettingsCategoryLabel(
                            category: category, accounts: [], isAccountIncluded: { _ in true }
                        )
                        .frame(width: width, height: 180, alignment: .leading)
                    }
                }
                .labelStyle(SettingsIconLabelStyle())
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.dynamicTypeSize, textSize)
                .background(Color.black)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Settings category alignment \(width) \(textSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let iconColumnWidth = UIFontMetrics(forTextStyle: .body).scaledValue(
                for: SettingsRowMetrics.iconColumnWidth,
                compatibleWith: UITraitCollection(preferredContentSizeCategory:
                    textSize == .accessibility3 ? .accessibilityExtraLarge : .large)
            )
            let titles = try ["Playback", "Subtitles", "Live TV", "Sources", "Downloads", "Appearance",
                              "Screens", "Trackers", "Seerr", "Language"].enumerated().map { index, title in
                // Recognize each row at native resolution rather than downsampling the tall category list.
                let rowTop = index * 180
                let row = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: rowTop, width: image.width, height: 180)))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: row).perform([request])
                let result = try XCTUnwrap(request.results?.first {
                    $0.topCandidates(1).first?.string.contains(title) == true
                }, "Missing category \(title)")
                let candidate = try XCTUnwrap(result.topCandidates(1).first)
                let range = try XCTUnwrap(candidate.string.range(of: title))
                let bounds = try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
                let top = max(0, rowTop + Int((1 - bounds.maxY) * 180) - 2)
                let bottom = min(image.height, rowTop + Int((1 - bounds.minY) * 180) + 2)
                // Measure title ink, excluding the independently centered icon column.
                let leading = try XCTUnwrap((Int(iconColumnWidth)..<image.width).first { x in
                    (top..<bottom).contains { y in
                        let offset = (y * image.width + x) * 4
                        return pixels[offset] > 230 && pixels[offset + 1] > 230 && pixels[offset + 2] > 230
                    }
                })
                return CGFloat(leading)
            }
            let leading = try XCTUnwrap(titles.first)
            for title in titles {
                XCTAssertEqual(title, leading, accuracy: 3, "All category titles must share one leading column.")
            }
        }
    }

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

    func testMobileCommunityUsesCompactSingleLineLinksWithoutSubtitlesOrQRCodes() async throws {
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        for light in [false, true] {
            for width: CGFloat in [320, 390, 768] {
                for textSize in [DynamicTypeSize.large, .accessibility3] {
                    capturedImages.removeAll(keepingCapacity: true)
                    let content = ScrollView {
                        PlozziOSCommunitySettingsSection()
                    }
                    .settingsPageSurface()
                    .environment(\.dynamicTypeSize, textSize)
                    let text = try await renderedText(
                        content, size: CGSize(width: width, height: 568),
                        light: light, name: "compact-community-\(Int(width))-\(light)-\(textSize)",
                        initialOnly: true
                    )
                    assertCommunity(in: text)
                    let image = try XCTUnwrap(capturedImages.last)
                    XCTAssertTrue(detector.features(in: CIImage(cgImage: image)).isEmpty,
                                  "Mobile Settings should offer direct links, not scannable codes.")
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    func bounds(for label: String) throws -> CGRect {
                        let candidate = try XCTUnwrap(request.results?.compactMap {
                            $0.topCandidates(1).first
                        }.first { $0.string.contains(label) })
                        let range = try XCTUnwrap(candidate.string.range(of: label))
                        return try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
                    }
                    let discord = try bounds(for: "Discord")
                    let github = try bounds(for: "GitHub")
                    XCTAssertGreaterThan(discord.minY, github.maxY, "Each link must occupy its own readable row.")
                    if textSize == .large {
                        let rowSpacing = (discord.midY - github.midY) * CGFloat(image.height)
                        XCTAssertGreaterThanOrEqual(rowSpacing, 44, "Keep a usable native touch target.")
                        XCTAssertLessThanOrEqual(rowSpacing, 56, "Community links should be standard-height rows.")
                    }
                }
            }
        }
    }

    func testCommunityArtworkIsAvailableInMobileAppResources() throws {
        for asset in ["DiscordMark", "GitHubMark", "DiscordLockup", "GitHubLockup"] {
            let image = try XCTUnwrap(UIImage(named: asset), "\(asset) must be bundled for iOS, not only tvOS.")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
    }

    func testCompactSettingsExposeCommunityLinksInBothThemes() async throws {
        let model = try makeSettingsAppWithAccount()
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
                let firstCapture = capturedImages.count
                let text = try await renderedText(
                    content, size: size, light: light,
                    name: "compact-settings-community-\(Int(size.width))-\(light)"
                )
                XCTAssertTrue(text.localizedCaseInsensitiveContains("Manage Plozz"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("All profiles"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Everyone"), text)
                XCTAssertFalse(text.contains("Applies to all profiles on this device."), text)
                assertCommunity(in: text)
                XCTAssertFalse(text.contains("Mozz"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("More apps"), text)
                XCTAssertTrue(text.contains("Help & Diagnostics"), text)
                XCTAssertTrue(text.contains("Version"), text)
                XCTAssertTrue(text.contains("Build"), text)
                try assertSignOutFollowsSupport(in: text, image: capturedImages[firstCapture])
            }
        }
    }

    func testRegularSettingsExposeCommunityLinksInBothThemes() async throws {
        let model = try makeSettingsAppWithAccount()
        let originalTheme = model.settings.theme.theme
        defer { model.settings.theme.theme = originalTheme }
        for light in [false, true] {
            model.settings.theme.theme = light ? .light : .dark
            for size in [CGSize(width: 768, height: 1024), CGSize(width: 844, height: 390)] {
                let content = PlozziOSSettingsView(
                    appModel: model, onClose: {}, systemColorScheme: light ? .light : .dark
                )
                .environment(\.horizontalSizeClass, .regular)
                let firstCapture = capturedImages.count
                let text = try await renderedText(
                    content, size: size, light: light,
                    name: "regular-settings-community-\(Int(size.width))-\(light)",
                    leadingColumn: true
                )
                XCTAssertTrue(text.localizedCaseInsensitiveContains("Manage Plozz"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("All profiles"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Everyone"), text)
                XCTAssertFalse(text.contains("Applies to all profiles on this device."), text)
                assertCommunity(in: text)
                XCTAssertFalse(text.contains("Mozz"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("More apps"), text)
                XCTAssertTrue(text.contains("Help & Diagnostics"), text)
                XCTAssertTrue(text.contains("Version"), text)
                XCTAssertTrue(text.contains("Build"), text)
                try assertSignOutFollowsSupport(in: text, image: capturedImages[firstCapture])
            }
        }
    }

    private func makeSettingsAppWithAccount() throws -> PlozziOSAppModel {
        let suite = "SettingsManagement-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "settings-server",
            server: MediaServer(
                id: "settings-server", name: "Test server",
                baseURL: URL(string: "https://settings.fixture.invalid")!, provider: .jellyfin
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture"
        ), token: "fixture")
        return PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: accounts, profileStore: ProfileStore(defaults: defaults)
        )
    }

    private func assertSignOutFollowsSupport(in text: String, image: CGImage) throws {
        let support = try XCTUnwrap(text.range(of: "Attributions"), text)
        let signOut = try XCTUnwrap(text.range(of: "Sign Out of All Accounts"), text)
        XCTAssertLessThan(support.lowerBound, signOut.lowerBound, text)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let label = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains("Sign Out of All Accounts") == true
        })
        let recognized = try XCTUnwrap(label.topCandidates(1).first)
        let titleRange = try XCTUnwrap(recognized.string.range(of: "Sign Out of All Accounts"))
        let box = try XCTUnwrap(recognized.boundingBox(for: titleRange)).boundingBox
        let title = CGRect(
            x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
            width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)
        ).integral
        let icon = CGRect(x: max(0, title.minX - 44), y: title.minY - 5, width: 36, height: title.height + 10)
        XCTAssertGreaterThan(try redPixelCount(in: image, rect: title), 20, "The sign-out title must stay red.")
        XCTAssertGreaterThan(try redPixelCount(in: image, rect: icon), 10, "The sign-out icon must stay red.")
    }

    private func redPixelCount(in image: CGImage, rect: CGRect) throws -> Int {
        let crop = try XCTUnwrap(image.cropping(to: rect.integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter { index in
            let red = Int(pixels[index])
            return red > 100 && red > Int(pixels[index + 1]) * 3 / 2
                && red > Int(pixels[index + 2]) * 3 / 2
        }.count
    }

    func testLibrarySourceNamesStayInlineWithAdaptiveOverflow() async throws {
        let accounts: [Account] = [
            ("plex", "Family Plex", ProviderKind.plex),
            ("jellyfin", "Cinema Server", .jellyfin),
            ("smb", "Archive NAS", .mediaShare),
            ("silo", "Weekend Silo", .silo)
        ].map { id, name, provider in
            Account(
                id: id,
                server: MediaServer(
                    id: id, name: name, baseURL: URL(string: "https://\(id).example.test")!,
                    provider: provider
                ),
                userID: id, userName: id, deviceID: "test"
            )
        }
        for (width, typeSize) in [
            (320.0, DynamicTypeSize.large), (320.0, .accessibility3),
            (390.0, .large), (768.0, .large)
        ] {
            let label = ScrollView {
                SettingsSectionGroup {
                    PlozziOSSettingsCategoryLabel(
                        category: .libraries, accounts: accounts, isAccountIncluded: { _ in true }
                    )
                }
            }
            .settingsPageSurface()
            .dynamicTypeSize(typeSize)
            let text = try await renderedText(
                label, size: CGSize(width: width, height: 844), light: false,
                name: "library-sources-\(width)-\(typeSize)", initialOnly: true
            )
            if typeSize.isAccessibilitySize {
                XCTAssertTrue(text.contains("Fam"), "Keep part of the source name, not only an ellipsis: \(text)")
                XCTAssertTrue(text.contains("+3"), text)
            } else {
                XCTAssertTrue(text.contains("Family Plex"), text)
                let visibleCount = ["Family Plex", "Cinema Server", "Archive NAS"]
                    .filter { text.contains($0) }.count
                XCTAssertTrue(text.contains("+\(4 - visibleCount) more"), text)
                if width == 768 { XCTAssertEqual(visibleCount, 3, text) }
            }
            XCTAssertFalse(text.contains("Weekend Silo"), text)
            try assertLibrarySourcesShareOneLine()
        }
        let label = ScrollView {
            SettingsSectionGroup {
                PlozziOSSettingsCategoryLabel(
                    category: .libraries, accounts: accounts, isAccountIncluded: { $0 == "silo" }
                )
            }
        }
        .settingsPageSurface()
        let text = try await renderedText(
            label, size: CGSize(width: 320, height: 568), light: false,
            name: "library-profile-selection", initialOnly: true
        )
        XCTAssertTrue(text.contains("Weekend Silo"), text)
        XCTAssertFalse(text.contains("Family Plex"), text)
        XCTAssertFalse(text.contains("more"), text)
        try assertLibrarySourcesShareOneLine()
    }

    private func assertLibrarySourcesShareOneLine(file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(capturedImages.last)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let sources = (request.results ?? []).filter {
            $0.topCandidates(1).first?.string.contains("Libraries") == false
        }
        let midpoints = sources.map { $0.boundingBox.midY * CGFloat(image.height) }
        let first = try XCTUnwrap(midpoints.first, file: file, line: line)
        for midpoint in midpoints {
            XCTAssertEqual(midpoint, first, accuracy: 5,
                           "Source names and overflow must share one line.", file: file, line: line)
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
        for label in ["Discord", "GitHub"] {
            XCTAssertTrue(text.contains(label), "Missing \(label): \(text)", file: file, line: line)
        }
        for label in ["QR Codes", "Join the community", "Source code and issues"] {
            XCTAssertFalse(text.contains(label), "Remove redundant mobile community content: \(text)", file: file, line: line)
        }
    }

    private func renderedText(
        _ content: some View, size: CGSize, light: Bool, name: String,
        initialOnly: Bool = false, leadingColumn: Bool = false
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
        let scrolls = scrollViews(in: window)
        // UIKit reports the detail collection as full-width; the narrow scroll owns the sidebar.
        let scroll = try XCTUnwrap(leadingColumn ? scrolls.first {
            $0.bounds.width > 0 && $0.bounds.width < window.bounds.width / 2
        } : scrolls.first, scrolls.map {
            "\(type(of: $0)): \($0.accessibilityIdentifier ?? "unidentified") \($0.frame)"
        }.joined(separator: "\n"))
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
        var text = try recognizedText(in: window, name: "\(name)-bottom")
        for index in 0..<12 {
            let top = -scroll.adjustedContentInset.top
            if scroll.contentOffset.y <= top { return text }
            scroll.setContentOffset(CGPoint(
                x: 0, y: max(top, scroll.contentOffset.y - scroll.bounds.height * 0.55)
            ), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            text += " " + (try recognizedText(in: window, name: "\(name)-above-bottom-\(index)"))
        }
        XCTFail("The bounded capture did not reach the top of \(name).")
        return text
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
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
#endif
