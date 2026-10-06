#if os(iOS)
import CoreModels
import CoreUI
@testable import FeatureLiveTV
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LiveTVSourcesPresentationTests: XCTestCase {
    func testSetupChoicesFitTabletWidthsInBothDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(768), 834] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
                window.rootViewController = UIHostingController(rootView:
                    LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
                        .environment(\.themePalette, .light)
                        .environment(\.colorScheme, .light)
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.layoutDirection, direction)
                        .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await waitForHostedLayout(window)
                let image = snapshot(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "tablet-onboarding-\(Int(width))-\(direction)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                for choice in ["IPTV playlist", "Media server", "Plozz channels"] {
                    XCTAssertTrue(text.contains(choice), "\(choice) must be visible without scrolling: \(text)")
                }
            }
        }
    }

    func testEmbeddedSourcesRevealTheSettingsBackgroundWithoutExtraRowInsets() async throws {
        let suite = "LiveTVSourcesPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 768] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    host.rootView = AnyView(
                        NavigationStack {
                            SettingsPageList {
                                LiveTVSourcesView(
                                    store: SourcesFixtureStore(), presentation: .settingsPane,
                                    connectServer: {}, createChannel: {}, scanChannels: {}
                                )
                            }
                            .navigationTitle("Sources")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(profiles)
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                        .environment(\.locale, Locale(identifier: "en_US"))
                    )
                    try await settle(window)
                    let actual = snapshot(window)
                    let attachment = XCTAttachment(image: actual)
                    attachment.name = "sources-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(actual.cgImage)).perform([request])
                    let header = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string == "ADD A SOURCE"
                    })
                    let headerFrame = CGRect(
                        x: header.boundingBox.minX * width,
                        y: (1 - header.boundingBox.maxY) * window.bounds.height,
                        width: header.boundingBox.width * width,
                        height: header.boundingBox.height * window.bounds.height
                    )
                    let y = headerFrame.midY
                    host.rootView = AnyView(
                        NavigationStack {
                            Color.clear.settingsPageSurface()
                                .navigationTitle("Sources")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                    )
                    try await settle(window)
                    let reference = snapshot(window)
                    XCTAssertEqual(try leadingInkEdge(actual, background: reference, header: headerFrame),
                                   24, accuracy: 2, "The pane must not gain a second native List row inset.")
                    for x in [width * 0.7, width - 32] {
                        let point = CGPoint(x: x, y: y)
                        for (observed, expected) in zip(try pixel(actual, at: point), try pixel(reference, at: point)) {
                            XCTAssertLessThanOrEqual(abs(observed - expected), 2,
                                                     "The Sources list cell must not cover the shared settings background.")
                        }
                    }
                }
            }
        }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func leadingInkEdge(_ image: UIImage, background: UIImage, header: CGRect) throws -> CGFloat {
        let top = max(0, Int(floor(header.minY)) - 2)
        let bottom = min(Int(image.size.height), Int(ceil(header.maxY)) + 2)
        let right = min(Int(image.size.width), Int(ceil(header.maxX)) + 2)
        var leading: Int?
        // Vision's line box can extend beyond the glyphs; ignore faint panel shadows.
        scan: for x in 0..<right {
            for y in top..<bottom {
                let point = CGPoint(x: x, y: y)
                let observed = try pixel(image, at: point)
                let expected = try pixel(background, at: point)
                if zip(observed, expected).contains(where: { abs($0.0 - $0.1) > 40 }) {
                    leading = x
                    break scan
                }
            }
        }
        return CGFloat(try XCTUnwrap(leading, "The source header must have visible text."))
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}

private struct SourcesFixtureStore: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws { throw LiveTVSourcesStoreError.saveFailed }
}
#endif
