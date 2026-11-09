#if os(iOS)
import CoreModels
import CoreUI
@testable import FeatureMusic
@testable import PlozziOSPresentationHost
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class MusicLandingPresentationTests: XCTestCase {
    func testBrowsePillsAndRailsHaveMobileMarginsAndNeutralInk() async throws {
        for width in [430.0, 834.0] {
            for palette in [ThemePalette.dark, .light, .pureBlack] {
                try await mount(width: width, palette: palette) { window, scrolls in
                    let pills = try XCTUnwrap(scrolls.first { $0.bounds.height < 100 })
                    XCTAssertGreaterThanOrEqual(pills.bounds.height, 44, "Native pills retain a full touch target")
                    XCTAssertLessThanOrEqual(pills.bounds.height, 54, "Browse stays compact, not a second row of large tiles")
                    let image = self.capture(window)
                    let labels = try self.textFrames(image)
                    let recent = try XCTUnwrap(labels["Recently Played"])
                    XCTAssertEqual(recent.minX, 20, accuracy: 3)
                    let titles = ["Playlists", "Albums", "Artists", "Genres"]
                    let frames = try titles.map { title in
                        try XCTUnwrap(labels[title], "Missing browse destination: \(title)")
                    }
                    for frame in frames {
                        // OCR measures ink, so descenders shift a label's box within the same baseline.
                        XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 4)
                        XCTAssertGreaterThan(frame.minX, 20)
                        XCTAssertLessThan(frame.maxX, width - 20)
                    }
                    XCTAssertLessThan(frames[0].maxY, recent.minY)
                    XCTAssertLessThan(recent.height, 30, "Use a touch-scale section heading, not TV typography")
                    let rail = try XCTUnwrap(scrolls.first { $0.bounds.height > 100 && $0.bounds.height < 400 })
                    XCTAssertEqual(rail.contentOffset.x, 0, accuracy: 1)
                    let artY = rail.convert(rail.bounds, to: window).minY + 75
                    let outside = try self.pixel(image, at: CGPoint(x: 10, y: artY))
                    let inside = try self.pixel(image, at: CGPoint(x: 30, y: artY))
                    XCTAssertLessThan(abs(outside[0] - outside[2]), 0.03, "Artwork must not touch the screen edge")
                    XCTAssertGreaterThan(abs(inside[0] - inside[2]), 0.1, "The first artwork begins inside the margin")
                    try self.assertNeutral(image, in: pills.convert(pills.bounds, to: window))
                }
            }
        }
    }

    func testNarrowLargeTextCanReachEveryBrowseDestinationWithoutWrappingThePage() async throws {
        try await mount(width: 320, textSize: .accessibility3) { window, scrolls in
            let vertical = try XCTUnwrap(scrolls.first { $0.bounds.height > 500 })
            XCTAssertLessThanOrEqual(vertical.contentSize.width, vertical.bounds.width + 1)
            let pills = try XCTUnwrap(scrolls.first { $0.bounds.height < 150 })
            XCTAssertGreaterThan(pills.contentSize.width, pills.bounds.width)
            XCTAssertNotNil(try self.textFrames(self.capture(window))["Playlists"])
            pills.setContentOffset(CGPoint(
                x: pills.contentSize.width - pills.bounds.width + pills.adjustedContentInset.right,
                y: pills.contentOffset.y
            ), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotNil(try self.textFrames(self.capture(window))["Genres"])
        }
    }

    func testReducedEffectsKeepReadableTouchSizedBrowsePills() async throws {
        for (reducePanelGlass, reduceTransparency) in [(true, false), (false, true)] {
            try await mount(
                width: 430, reducePanelGlass: reducePanelGlass, reduceTransparency: reduceTransparency
            ) { window, scrolls in
                let pills = try XCTUnwrap(scrolls.first { $0.bounds.height < 100 })
                XCTAssertGreaterThanOrEqual(pills.bounds.height, 44)
                let image = self.capture(window)
                let labels = try self.textFrames(image)
                for title in ["Playlists", "Albums", "Artists", "Genres"] {
                    XCTAssertNotNil(labels[title])
                }
                try self.assertNeutral(image, in: pills.convert(pills.bounds, to: window))
            }
        }
    }

    private func mount(
        width: CGFloat, palette: ThemePalette = .dark, textSize: DynamicTypeSize = .large,
        reducePanelGlass: Bool = false, reduceTransparency: Bool = false,
        inspect: (UIWindow, [UIScrollView]) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_194)
        let controller = AudioPlaybackController()
        let content = MusicLandingFixture.content
        let artworkURL = try XCTUnwrap(content.albums.first?.artworkURL)
        let artwork = await ArtworkImageCache.shared.image(for: artworkURL, variant: .original)
        XCTAssertNotNil(artwork, "Resolve fixture artwork before measuring its edge")
        let view = MusicLandingContent(
            content: content, controller: controller,
            onSelectRoute: { _ in }, onPlayTrack: { _ in }
        )
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette == .light ? .light : .dark)
        .environment(\.dynamicTypeSize, textSize)
        .environment(\.plozzReducePanelGlass, reducePanelGlass)
        .environment(\.plozzReduceTransparency, reduceTransparency)
        .tint(.blue)
        .background(palette.backgroundBase.ignoresSafeArea())
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
        try await inspect(window, descendants(window).compactMap { $0 as? UIScrollView })
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func capture(_ window: UIWindow) -> UIImage {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func textFrames(_ image: UIImage) throws -> [String: CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        var frames: [String: CGRect] = [:]
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let bounds = observation.boundingBox
            let rect = CGRect(x: bounds.minX * image.size.width, y: (1 - bounds.maxY) * image.size.height,
                              width: bounds.width * image.size.width, height: bounds.height * image.size.height)
            if frames[text] == nil || rect.minY < frames[text]!.minY { frames[text] = rect }
        }
        return frames
    }

    private func assertNeutral(_ image: UIImage, in frame: CGRect) throws {
        for x in stride(from: frame.minX + 24, to: min(frame.maxX - 20, frame.minX + 110), by: 3) {
            for y in stride(from: frame.minY + 8, to: frame.maxY - 8, by: 3) {
                let color = try pixel(image, at: CGPoint(x: x, y: y))
                XCTAssertLessThan((color.max() ?? 0) - (color.min() ?? 0), 0.05, "Browse must not inherit the app's blue tint")
            }
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Double] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(
                data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }
}
#endif
