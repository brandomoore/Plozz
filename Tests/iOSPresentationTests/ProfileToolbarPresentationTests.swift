#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class ProfileToolbarPresentationTests: XCTestCase {
    func testHomeProfileSharesTheTopTabRowAcrossSidebarChanges() async throws {
        try await assertHomeProfileAlignment(reduceTransparency: false)
    }

    func testOpaqueHomeProfileSharesTheTopTabRowAcrossSidebarChanges() async throws {
        try await assertHomeProfileAlignment(reduceTransparency: true)
    }

    func testAppShellKeepsProfileInTheNativeTabRow() async throws {
        try await assertHomeProfileAlignment(reduceTransparency: false, usesShell: true)
    }

    private func assertHomeProfileAlignment(reduceTransparency: Bool, usesShell: Bool = false) async throws {
        let suite = "HomeToolbar-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let profile = app.profiles.add(name: "Toolbar Fixture", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        defer { app.profiles.remove(profile.id) }
        app.settings.hero.settings.sources = [.recentlyAdded]
        app.settings.hero.settings.isEnabled = true
        app.settings.hero.settings.autoAdvance = false
        app.settings.hero.settings.trailersEnabled = false
        var provider = SeriesHeaderMobileProvider(artworkURL: try await photoURL())
        provider.latestItems = [provider.show]
        let account = Account(id: "header-fixture", from: provider.session)
        let model = HomeViewModel(
            accounts: [ResolvedAccount(account: account, provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore()
        )
        defer { model.invalidate() }
        await model.load()
        let sidebar = PlozziOSSidebarGeometryModel()
        let homeBox = LazyViewState<HomeViewModel>()
        defer { homeBox.discard { $0.invalidate() } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            Group {
                if usesShell {
                    PlozziOSTabShell(
                        appModel: app, homeViewModelBox: homeBox, onAddServer: {},
                        showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                        deferredPairingURL: .constant(nil), systemColorScheme: .dark
                    )
                } else {
                    TabView {
                        Tab("Home", systemImage: "house") {
                            NavigationStack {
                                PlozziOSHomeView(appModel: app, viewModel: model, onAddServer: {}, onShowSettings: {})
                                    .background {
                                        PlozziOSHomeSidebarOverlapProbe(enabled: true, geometryModel: sidebar)
                                            .frame(width: 0, height: 0)
                                    }
                                    .plozzOpaqueNavigationChrome()
                            }
                        }
                        Tab("Music", systemImage: "music.note") { Color.black }
                        Tab("Downloads", systemImage: "arrow.down") { Color.black }
                        Tab("Search", systemImage: "magnifyingglass") { Color.black }
                        Tab("Discover", systemImage: "sparkles") { Color.black }
                    }
                    .tabViewStyle(.sidebarAdaptable)
                    .modifier(PlozziOSNavigationBackground(hidesTopBackdrop: true))
                }
            }
            .environment(app)
            .environment(sidebar)
            .environment(HeroTrailerController())
            .environment(\.themePalette, .dark)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.plozzReduceTransparency, reduceTransparency)
            .preferredColorScheme(.dark)
        )
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitForHostedLayout(window)
        let tabs = try XCTUnwrap(controller(UITabBarController.self, in: host))
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
            window.frame.size = size
            try await waitForHostedLayout(window)
            for hidden in [true, false, true] {
                tabs.sidebar.isHidden = hidden
                try await waitForHostedLayout(window)
                let avatar = try XCTUnwrap(avatarButton(in: window), hierarchy(window))
                let frame = avatar.convert(avatar.bounds, to: window)
                _ = capture(window, name: "home-profile-\(Int(size.width))-sidebar-hidden-\(hidden)")
                XCTAssertEqual(tabs.sidebar.isHidden, hidden)
                XCTAssertTrue(window.bounds.contains(frame))
                if hidden {
                    let tab = try XCTUnwrap(descendants(window).first {
                        ($0 as? UILabel)?.text == "Home"
                            && $0.convert($0.bounds, to: window).minY >= 0
                            && $0.convert($0.bounds, to: window).maxY < 100
                            && $0.bounds.height > 10
                    }, hierarchy(window))
                    let tabFrame = tab.convert(tab.bounds, to: window)
                    XCTAssertEqual(frame.midY, tabFrame.midY, accuracy: 3,
                                   "The profile button must share the top navigation row, not sit below it.")
                }
            }
        }
    }

    private func controller<T: UIViewController>(_ type: T.Type, in owner: UIViewController) -> T? {
        if let match = owner as? T { return match }
        for child in owner.children {
            if let match = controller(type, in: child) { return match }
        }
        return nil
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testNativeToolbarKeepsPhotoCompactAndInOriginalColors() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfile
        defer { app.profiles.update(original) }
        var profile = original
        profile.name = "Toolbar Fixture"
        profile.avatarImageURL = try await photoURL().absoluteString
        app.profiles.update(profile)

        try await withToolbar(app: app) { window, button in
            XCTAssertGreaterThanOrEqual(button.bounds.width, 28)
            XCTAssertLessThanOrEqual(button.bounds.width, 64, "A profile photo must not widen the toolbar.")
            XCTAssertLessThanOrEqual(button.bounds.height, 64)
            let image = self.capture(button, name: "native-toolbar-photo")
            let toolbar = self.capture(window, name: "profile-beside-standard-toolbar-control")
            let photo = try self.greenPixelBounds(toolbar)
            let reference = try self.pixelBounds(toolbar) { r, g, b in b > 120 && Int(b) > Int(r) + 40 && g > 50 }
            @MainActor func glassBounds(around content: CGRect) throws -> CGRect {
                let crop = CGRect(x: content.midX - 28, y: content.midY - 28, width: 56, height: 56)
                let image = UIImage(cgImage: try XCTUnwrap(toolbar.cgImage?.cropping(to: crop)))
                return try self.pixelBounds(image) { r, g, b in max(r, g, b) > 12 }
            }
            let profileGlass = try glassBounds(around: photo)
            let referenceGlass = try glassBounds(around: reference)
            XCTAssertEqual(profileGlass.width, referenceGlass.width, accuracy: 1,
                           "Compare the rendered glass, not just the smaller SwiftUI host frame.")
            XCTAssertEqual(profileGlass.height, referenceGlass.height, accuracy: 1)
            XCTAssertEqual(profileGlass.width, profileGlass.height, accuracy: 1)
            XCTAssertEqual(photo.width, photo.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual((profileGlass.width - photo.width) / 2, 2)
            XCTAssertLessThanOrEqual((profileGlass.width - photo.width) / 2, 4.5)
            XCTAssertGreaterThan(try self.greenPixelCount(image), 100,
                                 "The photo must keep its pixels instead of becoming a template-colored square.")
            XCTAssertTrue(button.isUserInteractionEnabled)
            let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
            let hit = try XCTUnwrap(window.hitTest(center, with: nil))
            XCTAssertTrue(hit === button || hit.isDescendant(of: button))
        }
    }

    func testNativeToolbarUpdatesWhenProfileChangesToSymbolOrEmoji() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfile
        defer { app.profiles.update(original) }
        var profile = original
        profile.name = "Toolbar Fixture"
        profile.avatarImageURL = try await photoURL().absoluteString
        app.profiles.update(profile)

        try await withToolbar(app: app) { window, _ in
            for emoji in [nil, "\u{1F600}"] as [String?] {
                profile.avatarImageURL = nil
                profile.avatarEmoji = emoji
                profile.colorIndex = 0
                profile.avatarEmojiColorIndex = 0
                app.profiles.update(profile)
                try await Task.sleep(for: .milliseconds(300))
                window.layoutIfNeeded()
                let button = try XCTUnwrap(self.avatarButton(in: window))
                XCTAssertLessThanOrEqual(button.bounds.width, 64)
                let image = self.capture(button, name: emoji == nil ? "native-toolbar-symbol" : "native-toolbar-emoji")
                XCTAssertGreaterThan(try self.redPixelCount(image), 50,
                                     "Native controls must preserve the avatar's colored background.")
            }
        }
    }

    private func withToolbar(
        app: PlozziOSAppModel, inspect: (UIWindow, UIView) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                Color.black
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Filter", systemImage: "line.3.horizontal.decrease", action: {})
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.circle)
                        }
                        PlozziOSSettingsToolbarItem {}
                    }
            }
            .environment(app)
            .environment(\.locale, Locale(identifier: "en"))
            .tint(.blue)
            .preferredColorScheme(.dark)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while avatarButton(in: window) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let button = try XCTUnwrap(avatarButton(in: window), hierarchy(window))
        try await inspect(window, button)
    }

    private func avatarButton(in view: UIView) -> UIView? {
        if String(describing: type(of: view)).hasPrefix("UIKitBarItemHost<") {
            return view
        }
        if let bar = view as? UINavigationBar,
           let item = bar.topItem?.rightBarButtonItems?.first,
           let customView = item.customView {
            return customView
        }
        for child in view.subviews {
            if let button = avatarButton(in: child) { return button }
        }
        return nil
    }

    private func hierarchy(_ view: UIView, depth: Int = 0) -> String {
        "\(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame) label=\(view.accessibilityLabel ?? "-")\n"
            + view.subviews.map { hierarchy($0, depth: depth + 1) }.joined()
    }

    private func photoURL() async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://profile-toolbar.example.invalid/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 300, height: 100)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.green.setFill()
            context.fill(CGRect(x: 80, y: 0, width: 140, height: 100))
        }
        let data = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let requestURL = ArtworkImageVariant.musicThumbnail.requestURL(for: url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: requestURL))
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .musicThumbnail)
        _ = try XCTUnwrap(decoded)
        return url
    }

    private func capture(_ view: UIView, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func greenPixelCount(_ image: UIImage) throws -> Int {
        try pixelCount(image) { r, g, b in g > 180 && r < 80 && b < 80 }
    }

    private func greenPixelBounds(_ image: UIImage) throws -> CGRect {
        try pixelBounds(image) { r, g, b in g > 180 && r < 80 && b < 80 }
    }

    private func pixelBounds(_ image: UIImage, matches: (UInt8, UInt8, UInt8) -> Bool) throws -> CGRect {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let pixels = stride(from: 0, to: bytes.count, by: 4).filter {
            matches(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])
        }.map { CGPoint(x: ($0 / 4) % cg.width, y: ($0 / 4) / cg.width) }
        let left = try XCTUnwrap(pixels.map(\.x).min())
        let top = try XCTUnwrap(pixels.map(\.y).min())
        return CGRect(x: left, y: top, width: try XCTUnwrap(pixels.map(\.x).max()) - left + 1,
                      height: try XCTUnwrap(pixels.map(\.y).max()) - top + 1)
    }

    private func redPixelCount(_ image: UIImage) throws -> Int {
        try pixelCount(image) { r, g, b in r > 180 && g < 140 && b < 140 }
    }

    private func pixelCount(_ image: UIImage, matches: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {
            matches(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])
        }.count
    }
}
#endif
