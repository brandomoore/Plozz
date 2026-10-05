#if os(iOS)
import CoreModels
@testable import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class DetailCardSurfacePresentationTests: XCTestCase {
    func testCompactDetailMetadataDoesNotCoverThePageGradient() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let trailer = HeroTrailerController()
        let settings = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore(
            HeroBackgroundSettings(homeTrailerEnabled: false, detailMode: .off)
        ))
        let item = MediaItem(id: "gradient-fixture", title: "Fixture", kind: .series)
        for width in [CGFloat(390), 507] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            for palette in [ThemePalette.dark, .pureBlack, .light] {
                for gradientEnabled in [false, true] {
                    for reduceTransparency in [false, true] {
                        let background = LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom)
                        let stage = PlozziOSHeroStage(
                            item: item,
                            presentation: HeroPresentation(item: item, artworkStyle: .compactPortrait, surface: .detail),
                            style: .compactPortrait, surfaceRole: .detail, isActive: false,
                            showsBackdrop: false, trailerController: trailer,
                            backgroundSettings: settings, trailerResolver: { _ in nil }
                        ) {
                            Color.white.frame(width: 40, height: 120)
                        }
                        host.rootView = AnyView(
                            ScrollView {
                                stage
                                Color.clear.frame(height: 1000)
                            }
                            .background(background)
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradientEnabled)
                            .environment(\.plozzReduceTransparency, reduceTransparency)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        let attachment = XCTAttachment(image: actual)
                        attachment.name = "detail-band-\(width)-\(palette)-\(gradientEnabled)-\(reduceTransparency)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                        let revealsGradient = gradientEnabled && !reduceTransparency
                        host.rootView = AnyView(
                            Group {
                                if revealsGradient { background }
                                else { palette.backgroundBase }
                            }
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let reference = snapshot(window)
                        for y in [CGFloat(40), 120, 200] {
                            let point = CGPoint(x: 8, y: y)
                            for (rendered, expected) in zip(try pixel(actual, at: point), try pixel(reference, at: point)) {
                                XCTAssertLessThanOrEqual(abs(rendered - expected), 2,
                                                         "The metadata/action band must reveal the same page gradient, without a flat rectangle.")
                            }
                        }
                    }
                }
            }
        }
    }

    func testReadOnlyAndButtonCardsRevealTheirBackdropOnPhoneAndTablet() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            window.frame = CGRect(origin: .zero, size: size)
            for palette in [ThemePalette.dark, .pureBlack, .light] {
                for gradientSurface in [true, false] {
                    for button in [false, true] {
                        let label = Color.white.frame(width: 40, height: 40)
                            .frame(width: 240, height: 120)
                        host.rootView = AnyView(
                            ZStack {
                                Color.blue
                                if button {
                                    Button {} label: { label }.plozzCardButton(cornerRadius: 20)
                                } else {
                                    label.plozzFocusableCard(cornerRadius: 20)
                                }
                            }
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.plozzGradientCardSurface, gradientSurface)
                            .environment(\.plozzReduceTransparency, !gradientSurface)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        XCTAssertEqual(try pixel(actual, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                                       [255, 255, 255], "Surface opacity must not fade card content.")
                        let fill = gradientSurface
                            ? (palette.isLight ? Color.black : .white).opacity(0.05)
                            : palette.raised.fill
                        host.rootView = AnyView(fill.background(.blue)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark))
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let point = CGPoint(x: size.width / 2 + 80, y: size.height / 2)
                        for (rendered, reference) in zip(try pixel(actual, at: point),
                                                         try pixel(snapshot(window), at: point)) {
                            XCTAssertLessThanOrEqual(abs(rendered - reference), 2,
                                                     "\(size), \(palette), gradient=\(gradientSurface), button=\(button)")
                        }
                    }
                }
            }
        }
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
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
#endif
