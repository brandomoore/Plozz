import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class GradientBackgroundHostedTests: XCTestCase {
    func testHomeTintUsesArtworkAndToggleRestoresFlatPageWithoutRebuildingContent() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let state = GradientFixtureState()
        let counter = GradientBodyCounter()
        let url = URL(string: "https://gradient.example.test/\(UUID().uuidString).png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let request = URLRequest(url: ArtworkImageVariant.heroBackdrop.requestURL(for: url))
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: request)
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .heroBackdrop)
        XCTAssertNotNil(decoded)
        let host = UIHostingController(rootView: GradientHomeFixture(state: state, counter: counter, url: url))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            cache.removeCachedResponse(for: request)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        let initialEvaluations = counter.evaluations
        try await Task.sleep(for: .seconds(1.2))
        let tinted = try capture(window)
        let red = try pixel(tinted, at: CGPoint(x: 600, y: 400))
        XCTAssertGreaterThan(red[0], red[2] + 10)
        XCTAssertEqual(counter.evaluations, initialEvaluations, "Palette publication must invalidate only the background.")
        state.enabled = false
        try await Task.sleep(for: .milliseconds(200))
        let flat = try capture(window)
        let a = try pixel(flat, at: CGPoint(x: 600, y: 80))
        let b = try pixel(flat, at: CGPoint(x: 600, y: 470))
        XCTAssertEqual(a, b)
        state.enabled = true
        state.visible = false
        try await Task.sleep(for: .seconds(1))
        let inactive = try pixel(capture(window), at: CGPoint(x: 600, y: 400))
        XCTAssertLessThan(abs(inactive[0] - inactive[2]), 15, "Hidden Home must drop its artwork tint.")
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    func testAllThemeGradientsAndDisabledFlatBackgroundsRender() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for theme in [AppTheme.pureBlack, .dark, .light] {
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            for enabled in [false, true] {
                host.rootView = AnyView(
                    AppBackground(palette: palette)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(theme.displayName).font(.largeTitle.bold())
                                Text("Gradient Backgrounds").font(.title2)
                            }
                            .foregroundStyle(palette.primaryText)
                            .padding(60)
                        }
                        .environment(\.themePalette, palette)
                        .environment(\.gradientBackgroundsEnabled, enabled)
                        .transaction { $0.disablesAnimations = true }
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let first = try pixel(image, at: CGPoint(x: 800, y: 80))
                let last = try pixel(image, at: CGPoint(x: 800, y: 470))
                let difference = zip(first, last).map { abs($0 - $1) }.reduce(0, +)
                if enabled { XCTAssertGreaterThan(difference, 2) }
                else { XCTAssertLessThanOrEqual(difference, 2) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(theme.rawValue)-gradient-\(enabled)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x * scale, y: point.y * scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(data: $0.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}

@MainActor @Observable
private final class GradientFixtureState {
    var enabled = true
    var visible = true
}
@MainActor
private final class GradientBodyCounter { var evaluations = 0 }
private struct GradientHomeFixture: View {
    let state: GradientFixtureState
    let counter: GradientBodyCounter
    let url: URL
    var body: some View {
        GradientFixtureContent(counter: counter)
            .overlay(alignment: .topLeading) {
                FallbackAsyncImage(references: [.remote(url)], variant: .heroBackdrop, pinIdentity: "artwork") {
                    Color.clear
                }
                .reportingHeroArtwork(id: "artwork")
                .frame(width: 48, height: 48)
            }
            .heroArtworkSource(id: "artwork", isActive: state.visible)
            .homeGradientBackground(scope: ObjectIdentifier(state), isVisible: state.visible)
            .background { AppBackground(palette: .dark) }
            .environment(\.themePalette, .dark)
            .environment(\.gradientBackgroundsEnabled, state.enabled)
    }
}
private struct GradientFixtureContent: View {
    let counter: GradientBodyCounter
    var body: some View {
        let _ = { counter.evaluations += 1 }()
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
