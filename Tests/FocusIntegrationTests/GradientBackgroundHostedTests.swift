import CoreModels
import Observation
import SwiftUI
import TVUIKit
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class GradientBackgroundHostedTests: XCTestCase {
    func testNativeCardsMatchTheLocalGradientThroughScrollingResizingAndAppearanceChanges() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = GradientSurfaceFixtureState()
        let ambient = AmbientBackdropModel()
        let counter = GradientBodyCounter()
        let colors: [Color] = [.red, .cyan, .indigo, .purple]
        let url = try XCTUnwrap(URL(string: "https://gradient.example.test/spatial-card.png"))
        await ambient.update(owner: UUID(), key: AmbientArtworkKey(id: "spatial", reference: .remote(url)),
                             delay: .zero) { colors }
        let host = UIHostingController(rootView: AnyView(
            GradientSurfaceFixture(state: state, ambient: ambient, counter: counter)
        ))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(ambient.cardSurface.image, "Pages without gradient cards must not rasterize an unused texture.")
        state.showsCards = true
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)] {
            window.frame.size = size
            let viewport = window.bounds.insetBy(dx: 80, dy: 60)
            for palette in [ThemePalette.dark, .pureBlack, .light] {
                state.palette = palette
                state.enabled = true
                state.reduceTransparency = false
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let anchor = try XCTUnwrap(ambient.cardSurface.viewport)
                XCTAssertEqual(anchor.convert(anchor.bounds, to: window), viewport)
                let texture = try XCTUnwrap(ambient.cardSurface.image)
                XCTAssertLessThanOrEqual(max(texture.width, texture.height), 480)
                let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: window).first)
                let referenceRenderer = ImageRenderer(content:
                    AmbientGradientBackground(palette: palette, tint: colors)
                        .overlay(palette.informationSurface.opacity(0.4))
                        .overlay((palette.isLight ? Color.black : .white).opacity(0.05))
                        .frame(width: viewport.width, height: viewport.height)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                )
                referenceRenderer.scale = 1
                let reference = try XCTUnwrap(referenceRenderer.uiImage)
                let evaluations = counter.evaluations
                var actualOffsets: [CGFloat] = []
                for offset in [CGFloat(0), 100, 200] {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    try await Task.sleep(for: .milliseconds(80))
                    actualOffsets.append(scroll.contentOffset.y)
                    let image = try capture(window)
                    var sampled = 0
                    for card in nativeCards(in: window) where !card.isFocused {
                        var values: [[Int]] = []
                        for fraction in [CGPoint(x: 0.15, y: 0.18), CGPoint(x: 0.85, y: 0.18),
                                         CGPoint(x: 0.15, y: 0.82), CGPoint(x: 0.85, y: 0.82)] {
                            let point = card.contentView.convert(CGPoint(
                                x: card.contentView.bounds.width * fraction.x,
                                y: card.contentView.bounds.height * fraction.y
                            ), to: window)
                            guard viewport.insetBy(dx: 4, dy: 4).contains(point) else { continue }
                            let actual = try pixel(image, at: point)
                            let expected = try pixel(reference, at: CGPoint(
                                x: point.x - viewport.minX, y: point.y - viewport.minY
                            ))
                            for channel in 0..<3 {
                                XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 3,
                                    "\(palette), offset=\(offset), \(size), \(point): \(actual) vs \(expected)")
                            }
                            values.append(actual)
                            sampled += 1
                        }
                        if values.count == 4 {
                            let variation = (0..<3).map { channel in
                                let components = values.map { $0[channel] }
                                return (components.max() ?? 0) - (components.min() ?? 0)
                            }.max() ?? 0
                            XCTAssertGreaterThan(variation, 2,
                                "\(palette), \(size): the native card must contain a gradient, not one flat tint.")
                        }
                    }
                    XCTAssertGreaterThanOrEqual(sampled, 4)
                    XCTAssertTrue(ambient.cardSurface.image === texture, "Scrolling must reuse the page texture.")
                    XCTAssertEqual(counter.evaluations, evaluations, "Scrolling must not rebuild card foregrounds.")
                }
                XCTAssertGreaterThan((actualOffsets.max() ?? 0) - (actualOffsets.min() ?? 0), 50,
                                     "Exercise actual scrolling, including native focus adjustments.")
                for (enabled, reduced) in [(false, false), (true, true)] {
                    state.enabled = enabled
                    state.reduceTransparency = reduced
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertTrue(descendants(NativeGradientCardFill.View.self, in: window).allSatisfy(\.isHidden))
                    let reference = ImageRenderer(content: palette.raised.fill.frame(width: 1, height: 1))
                    let expected = try pixel(XCTUnwrap(reference.uiImage), at: .zero)
                    let image = try capture(window)
                    for card in nativeCards(in: window) where !card.isFocused {
                        let point = card.contentView.convert(
                            CGPoint(x: card.contentView.bounds.width * 0.85, y: card.contentView.bounds.height * 0.82),
                            to: window
                        )
                        let actual = try pixel(image, at: point)
                        for channel in 0..<3 {
                            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 2)
                        }
                    }
                }
            }
        }
        state.enabled = true
        state.reduceTransparency = false
        try await Task.sleep(for: .milliseconds(200))
        weak var retiredFill = try XCTUnwrap(descendants(NativeGradientCardFill.View.self, in: window).first)
        XCTAssertFalse(try XCTUnwrap(retiredFill).isHidden)
        host.rootView = AnyView(EmptyView())
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        window.isHidden = true
        window.rootViewController = nil
        XCTAssertNil(retiredFill, "Scroll observations must not retain a removed native card.")
    }

    func testDetailInformationBandAndCardsRevealTintWithoutIgnoringTransparencyPreferences() async throws {
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
        let ambient = AmbientBackdropModel()
        let referenceURL = try XCTUnwrap(URL(string: "https://gradient.example.test/detail-card.png"))
        await ambient.update(owner: UUID(), key: AmbientArtworkKey(
            id: item.id, reference: .remote(referenceURL)
        ), delay: .zero) { [.red] }
        let previewColors: [Color] = [.blue, .cyan, .indigo, .purple]
        let previewAmbient = AmbientBackdropModel()
        await previewAmbient.update(owner: UUID(), key: AmbientArtworkKey(
            id: "\(item.id)-blue", reference: .remote(referenceURL)
        ), delay: .zero) { previewColors }

        for theme in [AppTheme.pureBlack, .dark, .light] {
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            for enabled in [false, true] {
                for reduceTransparency in [false, true] {
                    let opacity = enabled && !reduceTransparency ? 0.4 : 1.0
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
                        .environment(\.ambientBackdropModel, ambient)
                        .transaction { $0.disablesAnimations = true }
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    let image = try capture(window)
                    let cardPoints = nativeCards(in: window).filter { !$0.isFocused }.map {
                        $0.contentView.convert(
                            CGPoint(x: $0.contentView.bounds.maxX - 12, y: $0.contentView.bounds.midY),
                            to: window
                        )
                    }.filter { window.bounds.insetBy(dx: 1, dy: 1).contains($0) }
                    XCTAssertGreaterThanOrEqual(cardPoints.count, 4)
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
                    host.rootView = AnyView(
                        (enabled && !reduceTransparency
                            ? AmbientGradientBackground.meshColors(tint: [.red], palette: palette)[4]
                                .mix(with: palette.informationSurface, by: 0.4)
                                .mix(with: palette.isLight ? .black : .white, by: 0.05)
                            : palette.raised.fill)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                    )
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    let cardReference = try capture(window)
                    for point in cardPoints {
                        let actual = try pixel(image, at: point)
                        let expected = try pixel(cardReference, at: point)
                        for channel in 0..<3 {
                            XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 2,
                                                     "Card at \(point): \(theme), gradient=\(enabled), reduceTransparency=\(reduceTransparency)")
                        }
                    }
                }
            }
            for tinted in [false, true] {
                host.rootView = AnyView(
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 180)
                            DetailInformationSections(item: item, horizontalInset: 60)
                        }
                    }
                    .background { AmbientGradientBackground(palette: palette, tint: tinted ? previewColors : nil) }
                    .environment(\.themePalette, palette)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.plozzNativeFocusSurface, true)
                    .environment(\.colorScheme, palette.isLight ? .light : .dark)
                    .environment(\.gradientBackgroundsEnabled, true)
                    .environment(\.plozzReduceTransparency, false)
                    .environment(\.ambientBackdropModel, tinted ? previewAmbient : nil)
                    .transaction { $0.disablesAnimations = true }
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                let preview = try capture(window)
                let above = try pixel(preview, at: CGPoint(x: 20, y: 178))
                let below = try pixel(preview, at: CGPoint(x: 20, y: 182))
                XCTAssertGreaterThan(zip(above, below).map { abs($0 - $1) }.reduce(0, +), 6)
                if tinted {
                    let points = nativeCards(in: window).filter { !$0.isFocused }.map {
                        $0.contentView.convert(
                            CGPoint(x: $0.contentView.bounds.maxX - 12, y: $0.contentView.bounds.midY),
                            to: window
                        )
                    }.filter { window.bounds.insetBy(dx: 1, dy: 1).contains($0) }
                    XCTAssertGreaterThanOrEqual(points.count, 4)
                    for point in points {
                        let color = try pixel(preview, at: point)
                        XCTAssertGreaterThan(color[2] - color[0], 4, "Native cards must retain the blue artwork tint.")
                    }
                }
                let attachment = XCTAttachment(image: preview)
                attachment.name = "detail-information-page-\(theme.rawValue)-\(tinted ? "blue" : "stock")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
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
        let card = try XCTUnwrap(nativeCards(in: window).first)
        let fill = try XCTUnwrap(descendants(NativeGradientCardFill.View.self, in: card).first)
        XCTAssertFalse(fill.isHidden, "The page background and native card must share the same gradient viewport.")
        XCTAssertNotNil(fill.layer.contents)
        let tintedCard = try XCTUnwrap(card.cardBackgroundColor)
        var cardRed: CGFloat = 0, cardGreen: CGFloat = 0, cardBlue: CGFloat = 0, cardAlpha: CGFloat = 0
        XCTAssertTrue(tintedCard.getRed(&cardRed, green: &cardGreen, blue: &cardBlue, alpha: &cardAlpha))
        XCTAssertGreaterThan(cardRed - cardBlue, 0.025)
        XCTAssertEqual(counter.evaluations, initialEvaluations, "Palette publication must invalidate only the background.")
        state.enabled = false
        try await Task.sleep(for: .milliseconds(200))
        let flat = try capture(window)
        let a = try pixel(flat, at: CGPoint(x: 600, y: 80))
        let b = try pixel(flat, at: CGPoint(x: 600, y: 470))
        XCTAssertEqual(a, b)
        XCTAssertEqual(card.cardBackgroundColor, UIColor(ThemePalette.dark.raised.fill))
        state.enabled = true
        state.visible = false
        try await Task.sleep(for: .seconds(1))
        let inactive = try pixel(capture(window), at: CGPoint(x: 600, y: 400))
        XCTAssertLessThan(abs(inactive[0] - inactive[2]), 15, "Hidden Home must drop its artwork tint.")
        XCTAssertNotEqual(card.cardBackgroundColor, tintedCard)
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func nativeCards(in view: UIView) -> [TVCardView] {
        (view as? TVCardView).map { [$0] } ?? view.subviews.flatMap { nativeCards(in: $0) }
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
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
            .overlay(alignment: .bottomLeading) {
                GradientFixtureCard(counter: counter)
                    .plozzFocusableCard(cornerRadius: 20)
                    .frame(width: 260, height: 120)
                    .environment(\.plozzCardFocusStyle, .system)
                    .environment(\.plozzGradientCardSurface, state.enabled)
            }
            .overlay(alignment: .topLeading) {
                FallbackAsyncImage(references: [.remote(url)], variant: .heroBackdrop, pinIdentity: "artwork") {
                    Color.clear
                }
                .reportingHeroArtwork(id: "artwork")
                .frame(width: 48, height: 48)
            }
            .heroArtworkSource(id: "artwork", isActive: state.visible)
            .artworkGradientBackground(scope: ObjectIdentifier(state), isVisible: state.visible)
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

private struct GradientFixtureCard: View {
    let counter: GradientBodyCounter
    var body: some View {
        let _ = { counter.evaluations += 1 }()
        Text("Information").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor @Observable
private final class GradientSurfaceFixtureState {
    var palette = ThemePalette.dark
    var enabled = true
    var reduceTransparency = false
    var showsCards = false
}

private struct GradientSurfaceFixture: View {
    let state: GradientSurfaceFixtureState
    let ambient: AmbientBackdropModel
    let counter: GradientBodyCounter

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)
                    HStack(spacing: 50) {
                        if state.showsCards {
                            ForEach(0..<3) { _ in
                                GradientFixtureCard(counter: counter)
                                    .plozzFocusableCard(cornerRadius: 20)
                                    .frame(width: (geometry.size.width - 100) / 3, height: 360)
                            }
                        }
                    }
                    Color.clear.frame(height: 900)
                }
                .background(state.palette.informationSurface.opacity(
                    state.enabled && !state.reduceTransparency ? 0.4 : 1
                ))
            }
        }
        .background { GradientSurfaceFixturePaint(state: state, ambient: ambient) }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .environment(\.themePalette, state.palette)
        .environment(\.colorScheme, state.palette.isLight ? .light : .dark)
        .environment(\.ambientBackdropModel, ambient)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzGradientCardSurface, state.enabled && !state.reduceTransparency)
        .environment(\.plozzReduceTransparency, state.reduceTransparency)
        .transaction { $0.disablesAnimations = true }
    }
}

private struct GradientSurfaceFixturePaint: View {
    let state: GradientSurfaceFixtureState
    let ambient: AmbientBackdropModel

    var body: some View {
        if state.enabled {
            AmbientGradientBackground(palette: state.palette, tint: ambient.colors)
        } else {
            state.palette.backgroundBase
        }
    }
}
