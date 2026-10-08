import CoreModels
@testable import CoreUI
@testable import FeatureHome
import MetadataKit
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroLogoPresentationHostedTests: XCTestCase {
    func testColdShowcaseLogoAppearsWithoutLeavingAndReturningToTheTitle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 320, height: 100))
        defer { removeSeededLogo(url) }
        let item = MediaItem(id: UUID().uuidString, title: "Cold Showcase title", kind: .movie)
        fixture.window.rootViewController = UIHostingController(rootView:
            Color.black.overlay {
                HeroLogoArtwork(
                    references: [],
                    asyncFallbackURL: HeroLogoFallback(for: item) {
                        try? await Task.sleep(for: .milliseconds(500))
                        return url
                    },
                    maxWidth: FocusHeroLayout.logoBox.width,
                    maxHeight: FocusHeroLayout.logoBox.height,
                    constrainsToBounds: true,
                    presentationPolicy: FocusHeroLayout.logoPresentationPolicy
                ) {
                    Text(verbatim: item.title).foregroundStyle(.green)
                }
            }
            .ignoresSafeArea()
        )
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(try redBounds(in: fixture.window), "This must exercise a genuinely cold lookup.")
        XCTAssertNil(try colorBounds(in: fixture.window, channel: 1),
                     "Showcase must not flash a text title before the logo arrives.")
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
        XCTAssertNotNil(try redBounds(in: fixture.window),
                        "A slow first lookup must not require a focus change to adopt the logo.")
    }

    func testCompactSeriesLogoStaysAboveSeasonsForTallSquareAndWideArtwork() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }

        for size in [CGSize(width: 120, height: 200), CGSize(width: 200, height: 200),
                     CGSize(width: 500, height: 100)] {
            let url = try seedLogo(size: size)
            defer { removeSeededLogo(url) }
            let series = MediaItem(
                id: UUID().uuidString, title: "Series fixture", kind: .series,
                backdropURL: url, logoURL: url
            )
            let model = SeriesHeroRecedeModel()
            model.isReceded = true
            let host = UIHostingController(rootView:
                Color.black.overlay(alignment: .top) {
                    SeriesEpisodeBrowser(
                        series: series, recedeModel: model, showsSeasons: true,
                        focusAnchorID: "logo-fixture",
                        seasonContent: {
                            Color.purple.frame(height: SeriesEpisodeBrowserLayout.seasonBarHeight)
                        },
                        episodeContent: { Color.blue }
                    )
                    .padding(.top, SeriesEpisodeBrowserLayout.browserColumnTopInset)
                }
                .ignoresSafeArea()
            )
            fixture.window.rootViewController = host
            fixture.window.layoutIfNeeded()
            try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
            let bounds = try XCTUnwrap(redBounds(in: fixture.window))
            XCTAssertGreaterThan(bounds.height, 50, "A missing or clipped logo is not a spacing fix.")
            XCTAssertLessThanOrEqual(bounds.height, 201, "Source shape: \(size)")
            XCTAssertGreaterThanOrEqual(
                bounds.minY,
                SeriesEpisodeBrowserLayout.browserColumnTopInset
                    - SeriesEpisodeBrowserLayout.recededLogoHeight - 1
            )
            XCTAssertLessThanOrEqual(
                bounds.maxY, SeriesEpisodeBrowserLayout.browserColumnTopInset + 1,
                "The wordmark must not draw into the Seasons row."
            )
        }
    }

    func testCachedFallbackDoesNotAppearOnADifferentTitleWithoutALogo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let url = try seedLogo(size: CGSize(width: 200, height: 100))
        defer { removeSeededLogo(url) }
        let first = MediaItem(id: UUID().uuidString, title: "First title", kind: .series)
        let second = MediaItem(id: UUID().uuidString, title: "No logo", kind: .series)
        let model = LogoModel(fallback: HeroLogoFallback(for: first) { url })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: model))
        try await waitUntil { model.tone != nil && (try? redBounds(in: fixture.window)) != nil }

        let missing = LookupProbe()
        model.tone = nil
        model.fallback = HeroLogoFallback(for: second) { await missing.resolve(nil) }
        try await waitUntil { missing.calls > 0 }
        XCTAssertNil(try redBounds(in: fixture.window), "A reused view must clear the previous title immediately.")
        XCTAssertNil(model.tone)

        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(
            model: LogoModel(fallback: HeroLogoFallback(for: second) { nil })
        ))
        fixture.window.layoutIfNeeded()
        XCTAssertNil(try redBounds(in: fixture.window), "A new detail/card view must not reuse another title's memo.")

        let returning = LogoModel(fallback: HeroLogoFallback(for: first) { url })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: returning))
        try await waitUntil { (try? redBounds(in: fixture.window)) != nil }
    }

    func testLateCancelledLookupCannotReplaceTheNewTitlesLogo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let oldURL = try seedLogo(size: CGSize(width: 200, height: 100))
        let newURL = try seedLogo(size: CGSize(width: 200, height: 100), color: .blue)
        defer {
            removeSeededLogo(oldURL)
            removeSeededLogo(newURL)
        }
        let first = MediaItem(id: UUID().uuidString, title: "Old title", kind: .series)
        let second = MediaItem(id: UUID().uuidString, title: "Current title", kind: .series)
        let delayed = LookupProbe()
        defer { delayed.release() }
        let model = LogoModel(fallback: HeroLogoFallback(for: first) {
            await delayed.resolve(oldURL, waitsForRelease: true)
        })
        fixture.window.rootViewController = UIHostingController(rootView: LookupFixture(model: model))
        try await waitUntil { delayed.calls > 0 }
        model.fallback = HeroLogoFallback(for: second) { newURL }
        try await waitUntil { model.tone?.blue ?? 0 > 0.9 }
        delayed.release()
        try await waitUntil { delayed.completed }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try redBounds(in: fixture.window))
        XCTAssertNotNil(try colorBounds(in: fixture.window, channel: 2))
        XCTAssertGreaterThan(try XCTUnwrap(model.tone).blue, 0.9)
    }

    @MainActor
    @Observable
    fileprivate final class LogoModel {
        var fallback: HeroLogoFallback
        var tone: ResolvedLogoTone?

        init(fallback: HeroLogoFallback) {
            self.fallback = fallback
        }
    }

    private struct LookupFixture: View {
        let model: LogoModel

        var body: some View {
            Color.black.overlay {
                HeroLogoArtwork(
                    references: [], asyncFallbackURL: model.fallback,
                    maxWidth: 400, maxHeight: 200, constrainsToBounds: true,
                    onResolve: { model.tone = $0 }
                ) {
                    Text("Title without a logo").foregroundStyle(.white)
                }
            }
            .ignoresSafeArea()
        }
    }

    @MainActor
    private final class LookupProbe {
        var calls = 0
        var completed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func resolve(_ url: URL?, waitsForRelease: Bool = false) async -> URL? {
            calls += 1
            if waitsForRelease {
                await withCheckedContinuation { continuation = $0 }
            }
            completed = true
            return url
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func seedLogo(size: CGSize, color: UIColor = .red) throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://logo-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: size.width + 20, height: size.height + 20), format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(origin: CGPoint(x: 10, y: 10), size: size))
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: url)
        )
        return url
    }

    private func removeSeededLogo(_ url: URL) {
        ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
    }

    private func redBounds(in window: UIWindow) throws -> CGRect? {
        try colorBounds(in: window, channel: 0)
    }

    private func colorBounds(in window: UIWindow, channel: Int) throws -> CGRect? {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset + channel] > 150
                    && pixels[offset + (channel + 1) % 3] < 80
                    && pixels[offset + (channel + 2) % 3] < 80 {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return Fixture(scene: scene)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Logo fixture did not settle.")
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
