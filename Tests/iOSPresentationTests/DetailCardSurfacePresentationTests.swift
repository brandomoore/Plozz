#if os(iOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailCardSurfacePresentationTests: XCTestCase {
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
                for opacity in [0.2, 1.0] {
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
                            .environment(\.plozzCardSurfaceOpacity, opacity)
                            .environment(\.plozzReduceTransparency, opacity == 1)
                        )
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(150))
                        let actual = snapshot(window)
                        XCTAssertEqual(try pixel(actual, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                                       [255, 255, 255], "Surface opacity must not fade card content.")
                        host.rootView = AnyView(palette.raised.fill.opacity(opacity).background(.blue)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark))
                        window.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(100))
                        let point = CGPoint(x: size.width / 2 + 80, y: size.height / 2)
                        for (rendered, reference) in zip(try pixel(actual, at: point),
                                                         try pixel(snapshot(window), at: point)) {
                            XCTAssertLessThanOrEqual(abs(rendered - reference), 2,
                                                     "\(size), \(palette), opacity=\(opacity), button=\(button)")
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
