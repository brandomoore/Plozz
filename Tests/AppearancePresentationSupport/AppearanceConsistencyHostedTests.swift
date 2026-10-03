import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class AppearanceConsistencyHostedTests: XCTestCase {
    func testContinueWatchingLogosStayTheSameAcrossThemesWhileHeroInkAdapts() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for monochrome in [true, false] {
            let url = try seedLogo(monochrome: monochrome)
            defer { ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url)) }
            let references = [ArtworkReference.remote(url)]
            let key = HeroLogoMemo.key(for: references)
            var baseline: [UInt8]?
            for theme in [AppTheme.dark, .light, .pureBlack] {
                let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
                fixture.host.rootView = AnyView(LogoFixture(
                    references: references, palette: palette, isCard: true,
                    width: fixture.window.bounds.width, height: fixture.window.bounds.height
                ))
                fixture.window.layoutIfNeeded()
                try await waitUntil { HeroLogoMemo.value(for: key) != nil }
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(try XCTUnwrap(HeroLogoMemo.value(for: key)).isMonochrome, monochrome)
                let image = try capture(fixture.window)
                let pixels = try rgba(image)
                if let baseline {
                    XCTAssertEqual(pixels.count, baseline.count)
                    let averageDifference = zip(pixels, baseline).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                        / Double(pixels.count)
                    XCTAssertLessThan(averageDifference, 0.5, "The artwork-card logo must not follow the page theme.")
                } else {
                    baseline = pixels
                }
                if monochrome {
                    XCTAssertGreaterThan(countPixels(pixels) { $0 > 235 && $1 > 235 && $2 > 235 }, 100,
                                         "A missing or blackened wordmark is not a theme-independent logo.")
                } else {
                    XCTAssertGreaterThan(countPixels(pixels) { $0 > 170 && $1 < 100 && $2 < 100 }, 100)
                }
                attach(image, name: "\(theme.rawValue)-continue-watching-\(monochrome ? "monochrome" : "colour")")
            }

            if monochrome {
                for theme in [AppTheme.dark, .light] {
                    let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
                    fixture.host.rootView = AnyView(LogoFixture(
                        references: references, palette: palette, isCard: false,
                        width: fixture.window.bounds.width, height: fixture.window.bounds.height
                    ))
                    fixture.window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(350))
                    let image = try capture(fixture.window)
                    let pixels = try rgba(image)
                    if theme == .light {
                        XCTAssertGreaterThan(countPixels(pixels) { $0 < 15 && $1 < 15 && $2 < 15 }, 100,
                                             "Light heroes must keep their dark monochrome wordmarks.")
                    } else {
                        XCTAssertGreaterThan(countPixels(pixels) { $0 > 235 && $1 > 235 && $2 > 235 }, 100)
                    }
                    attach(image, name: "\(theme.rawValue)-hero-logo")
                }
            }
        }
    }

    func testSettingsPanelsRevealTheGradientAndRestoreSolidAccessibilitySurfaces() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        for theme in [AppTheme.dark, .pureBlack, .light] {
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            let state = SurfaceFixtureState()
            fixture.host.rootView = AnyView(SurfaceFixture(state: state, palette: palette))
            fixture.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let translucent = try capture(fixture.window)
            let points: [(CGFloat, CGFloat)] = [
                (0.2, 0.2), (0.4, 0.2), (0.6, 0.2), (0.8, 0.2),
                (0.2, 0.45), (0.4, 0.45), (0.6, 0.45), (0.8, 0.45)
            ]
            let samples = try points.map { try pixel(translucent, x: $0.0, y: $0.1) }
            let variation = try (0..<3).reduce(0) { total, channel in
                let values = samples.map { $0[channel] }
                return total + (try XCTUnwrap(values.max()) - XCTUnwrap(values.min()))
            }
            XCTAssertGreaterThan(variation, 2, "The gradient must remain visible across the panel in \(theme.rawValue).")
            attach(translucent, name: "\(theme.rawValue)-translucent-settings")

            state.reduceTransparency = true
            try await Task.sleep(for: .milliseconds(150))
            let solid = try capture(fixture.window)
            let solidSamples = try points.map { try pixel(solid, x: $0.0, y: $0.1) }
            XCTAssertTrue(solidSamples.allSatisfy { $0 == solidSamples[0] },
                          "Reduce Transparency restores an opaque panel without a residual gradient.")

            state.gradient = false
            state.reduceTransparency = false
            try await Task.sleep(for: .milliseconds(150))
            let disabled = try capture(fixture.window)
            XCTAssertEqual(try pixel(disabled, x: 0.3, y: 0.3), try pixel(solid, x: 0.3, y: 0.3))
        }
    }

    @MainActor @Observable
    final class SurfaceFixtureState {
        var gradient = true
        var reduceTransparency = false
    }

    private struct SurfaceFixture: View {
        let state: SurfaceFixtureState
        let palette: ThemePalette

        var body: some View {
            GeometryReader { geometry in
                ZStack {
                    SettingsPageBackground()
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Profile").font(.title2.bold())
                        PlozzDivider()
                        Text("Appearance").font(.headline)
                        Text("Theme, navigation, and cards").foregroundStyle(palette.secondaryText)
                    }
                    .foregroundStyle(palette.primaryText)
                    .padding(28)
                    .frame(width: geometry.size.width * 0.84, height: geometry.size.height * 0.84, alignment: .bottomLeading)
                    .settingsGroupSurface(cornerRadius: 24)
                }
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .environment(\.gradientBackgroundsEnabled, state.gradient)
            .environment(\.plozzReduceTransparency, state.reduceTransparency)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea()
        }
    }

    private struct LogoFixture: View {
        let references: [ArtworkReference]
        let palette: ThemePalette
        let isCard: Bool
        let width: CGFloat
        let height: CGFloat

        var body: some View {
            Group {
                if isCard {
                    Color(red: 0.20, green: 0.13, blue: 0.10)
                        .overlay {
                            ContinueWatchingSeriesLogo(
                                title: Text(verbatim: ""), logoReferences: references,
                                artworkReferences: [], artworkVariant: .landscapeCard, asyncFallbackURL: nil
                            )
                        }
                } else {
                    palette.backgroundBase.overlay {
                        HeroLogoArtwork(
                            references: references, maxWidth: width * 0.75, maxHeight: height * 0.4,
                            constrainsToBounds: true, alignment: .center
                        ) { EmptyView() }
                    }
                }
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea()
        }
    }

    private func seedLogo(monochrome: Bool) throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://appearance-fixture.example.test/\(UUID()).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 100), format: format).image { context in
            (monochrome ? UIColor.white : UIColor.red).setFill()
            context.fill(CGRect(x: 20, y: 15, width: 25, height: 70))
            context.fill(CGRect(x: 20, y: 60, width: 140, height: 25))
            if !monochrome {
                UIColor.blue.setFill()
                context.fill(CGRect(x: 120, y: 15, width: 40, height: 30))
            }
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: URLRequest(url: url)
        )
        return url
    }

    @MainActor
    private struct Fixture {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let previous: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: min(960, scene.coordinateSpace.bounds.width),
                              height: min(640, scene.coordinateSpace.bounds.height))
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        return Fixture(window: window, host: host, previous: previous)
    }

    private func capture(_ window: UIWindow) throws -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage)
        let offset = (Int(CGFloat(cg.height) * y) * cg.width + Int(CGFloat(cg.width) * x)) * 4
        let bytes = try rgba(image)
        return bytes[offset..<(offset + 3)].map(Int.init)
    }

    private func countPixels(_ bytes: [UInt8], matching predicate: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).reduce(0) { total, offset in
            total + (predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2]) ? 1 : 0)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Appearance fixture did not finish resolving.")
    }
}
