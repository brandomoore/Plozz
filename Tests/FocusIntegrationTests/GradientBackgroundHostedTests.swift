import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class GradientBackgroundHostedTests: XCTestCase {
    func testDetailInformationBandBlendsAtSixtyPercentWithoutIgnoringTransparencyPreferences() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var item = MediaItem(id: "detail-gradient", title: "Detail information", kind: .movie)
        item.overview = "Two people meet while working together. Their friendship grows through shared stories, unexpected choices, and an eventful summer in the city."
        item.productionYear = 2009
        item.runtime = 5_700
        item.genres = ["Comedy", "Drama"]
        item.ratings = [
            .init(source: .rottenTomatoes, value: 64, scale: .percent),
            .init(source: .rottenTomatoesAudience, value: 80, scale: .percent),
            .init(source: .imdb, value: 7.8, scale: .outOfTen),
            .init(source: .tmdb, value: 6.2, scale: .outOfTen)
        ]
        let backdrop = LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)

        for theme in [AppTheme.pureBlack, .dark, .light] {
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            for enabled in [false, true] {
                for reduceTransparency in [false, true] {
                    let opacity = enabled && !reduceTransparency ? 0.6 : 1.0
                    host.rootView = AnyView(
                        ScrollView {
                            DetailInformationSections(item: item, horizontalInset: 60)
                        }
                        .background(backdrop)
                        .environment(\.themePalette, palette)
                        .environment(\.plozzCardFocusStyle, .system)
                        .environment(\.plozzNativeFocusSurface, true)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, enabled)
                        .environment(\.plozzReduceTransparency, reduceTransparency)
                        .transaction { $0.disablesAnimations = true }
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    let image = try capture(window)
                    let top = try pixel(image, at: CGPoint(x: 20, y: 20))
                    let bottom = try pixel(image, at: CGPoint(x: 20, y: 500))
                    host.rootView = AnyView(
                        palette.informationSurface.opacity(opacity)
                            .background(backdrop)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    let reference = try capture(window)
                    for y in [CGFloat(20), 500] {
                        let actual = try pixel(image, at: CGPoint(x: 20, y: y))
                        let expected = try pixel(reference, at: CGPoint(x: 20, y: y))
                        for channel in 0..<3 {
                            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 2,
                                                     "\(theme), gradient=\(enabled), reduceTransparency=\(reduceTransparency)")
                        }
                    }
                    let variation = zip(top, bottom).map { abs($0 - $1) }.reduce(0, +)
                    if opacity < 1 {
                        XCTAssertGreaterThan(variation, 20)
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "detail-information-\(theme.rawValue)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    } else {
                        XCTAssertLessThanOrEqual(variation, 2)
                    }
                }
            }
            host.rootView = AnyView(
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 180)
                        DetailInformationSections(item: item, horizontalInset: 60)
                    }
                }
                .background { AppBackground(palette: palette) }
                .environment(\.themePalette, palette)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.plozzNativeFocusSurface, true)
                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                .environment(\.gradientBackgroundsEnabled, true)
                .environment(\.plozzReduceTransparency, false)
                .transaction { $0.disablesAnimations = true }
            )
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let preview = try capture(window)
            let above = try pixel(preview, at: CGPoint(x: 20, y: 178))
            let below = try pixel(preview, at: CGPoint(x: 20, y: 182))
            XCTAssertGreaterThan(zip(above, below).map { abs($0 - $1) }.reduce(0, +), 6)
            let attachment = XCTAttachment(image: preview)
            attachment.name = "detail-information-page-\(theme.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

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
