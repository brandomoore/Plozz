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
    func testInlineMorePreservesEarlierLinesAndClearsBehindLargeLabels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            var images: [[UInt8]] = []
            for stage in 0..<3 {
                host.rootView = AnyView(
                    DetailInlineMoreLabel(isTruncated: stage > 0, fadeWidth: 100, textFont: .body) {
                        Text(verbatim: String(repeating: "gypqy", count: 80))
                            .font(.body)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 400, alignment: .leading)
                            .foregroundStyle(stage == 2 ? .clear : .white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(.black)
                    .dynamicTypeSize(typeSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                )
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                let image = snapshot(window)
                let cgImage = try XCTUnwrap(image.cgImage)
                guard cgImage.width == 400, cgImage.height == 400,
                      cgImage.bitsPerPixel == 32, cgImage.bytesPerRow == 1600 else {
                    XCTFail("The pixel fixture must use a 400pt standard-range surface.")
                    return
                }
                images.append(Array(try XCTUnwrap(cgImage.dataProvider?.data) as Data))
                if stage == 1 {
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "inline-more-\(typeSize)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            let rows = (0..<400).filter { y in
                (0..<400).contains { x in images[0][(y * 400 + x) * 4] > 30 }
            }
            let lineStarts = rows.enumerated().compactMap { index, y in
                index == 0 || y > rows[index - 1] + 1 ? y : nil
            }
            XCTAssertEqual(lineStarts.count, 3, "The fixture must render three lines with descenders.")
            guard lineStarts.count == 3 else { continue }
            let earlierEnd = try XCTUnwrap(rows.last { $0 < lineStarts[2] })
            var earlierChanges = 0
            for y in 0...earlierEnd {
                for x in 0..<400 {
                    let offset = (y * 400 + x) * 4
                    if abs(Int(images[0][offset]) - Int(images[1][offset])) > 3 { earlierChanges += 1 }
                }
            }
            XCTAssertLessThanOrEqual(earlierChanges, 20, "MORE must leave preceding glyphs intact at \(typeSize).")
            let labelPixels = (0..<(400 * 400)).filter { images[2][$0 * 4] > 30 }
            XCTAssertGreaterThan(labelPixels.count, 50, "The reference must contain the visible MORE label.")
            let minX = try XCTUnwrap(labelPixels.map { $0 % 400 }.min())
            let maxX = try XCTUnwrap(labelPixels.map { $0 % 400 }.max())
            let minY = try XCTUnwrap(labelPixels.map { $0 / 400 }.min())
            let maxY = try XCTUnwrap(labelPixels.map { $0 / 400 }.max())
            var labelChanges = 0
            for y in minY...maxY {
                for x in minX...maxX {
                    let offset = (y * 400 + x) * 4
                    if abs(Int(images[1][offset]) - Int(images[2][offset])) > 3 { labelChanges += 1 }
                }
            }
            XCTAssertLessThanOrEqual(labelChanges, 20, "Text must fade completely before the MORE label begins.")
        }
    }

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
                for (gradientEnabled, reduceTransparency) in [(true, false), (false, false), (true, true)] {
                    let gradientSurface = gradientEnabled && !reduceTransparency
                    for style in ["read-only", "button", "settings", "detail"] {
                        let fillOpacity = style == "detail" ? 0.12 : 0.05
                        let label = Color.white.frame(width: 40, height: 40)
                            .frame(width: 240, height: 120)
                        host.rootView = AnyView(
                            ZStack {
                                Color.blue
                                if style == "button" {
                                    Button {} label: { label }.plozzCardButton(cornerRadius: 20)
                                } else if style == "settings" {
                                    Button {} label: { label }.buttonStyle(SettingsCardButtonStyle())
                                } else {
                                    label.plozzFocusableCard(cornerRadius: 20)
                                }
                            }
                            .plozzAdaptiveCardSurface(fillOpacity: style == "detail"
                                ? ThemePalette.detailGradientSurfaceFillOpacity
                                : ThemePalette.gradientSurfaceFillOpacity)
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradientEnabled)
                            .environment(\.plozzReduceTransparency, reduceTransparency)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        XCTAssertEqual(try pixel(actual, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                                       [255, 255, 255], "Surface opacity must not fade card content.")
                        let fill = gradientSurface
                            ? (palette.isLight ? Color.black : .white).opacity(fillOpacity)
                            : palette.raised.fill
                        host.rootView = AnyView(fill.background(.blue)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark))
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let point = CGPoint(x: size.width / 2 + 80, y: size.height / 2)
                        for (rendered, reference) in zip(try pixel(actual, at: point),
                                                         try pixel(snapshot(window), at: point)) {
                            XCTAssertLessThanOrEqual(abs(rendered - reference), 2,
                                                     "\(size), \(palette), gradient=\(gradientEnabled), reduceTransparency=\(reduceTransparency), style=\(style)")
                        }
                    }
                }
            }
        }
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
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
