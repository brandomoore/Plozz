#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class ProfileToolbarPresentationTests: XCTestCase {
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
        return view.subviews.lazy.compactMap { self.avatarButton(in: $0) }.first
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
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
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
