#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class PINKeySurfaceTests: XCTestCase {
    func testDigitAndDeleteKeysShareTheGradientSurfaceAndOpaqueFallback() throws {
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            for width in [PINMetrics.keyDiameter, PINMetrics.deleteKeyWidth] {
                for gradient in [false, true] {
                    for reduced in [false, true] {
                        let backdrop = LinearGradient(
                            colors: [.red, .blue], startPoint: .top, endPoint: .bottom
                        )
                        let label = Color.white.frame(width: 12, height: 12)
                        let size = CGSize(width: width + 80, height: PINMetrics.keyDiameter + 80)
                        let actual = try render(
                            Button {} label: { label }
                                .buttonStyle(PINKeyStyle(width: width))
                                .frame(width: size.width, height: size.height)
                                .background(backdrop)
                                .environment(\.themePalette, palette)
                                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                                .environment(\.gradientBackgroundsEnabled, gradient)
                                .environment(\.plozzReduceTransparency, reduced)
                        )
                        let expected = try render(
                            label
                                .frame(width: width, height: PINMetrics.keyDiameter)
                                .background {
                                    let surface = surface(palette, gradient: gradient, reduced: reduced)
                                    let shape = RoundedRectangle(
                                        cornerRadius: PINMetrics.keyDiameter / 2, style: .continuous
                                    )
                                    shape.fill(surface.fill)
                                        .overlay {
                                            if let border = surface.border {
                                                shape.strokeBorder(border, lineWidth: surface.borderWidth)
                                            }
                                        }
                                }
                                .frame(width: size.width, height: size.height)
                                .background(backdrop)
                                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        )
                        for point in [
                            CGPoint(x: size.width / 2, y: 40),
                            CGPoint(x: size.width / 2, y: 50),
                            CGPoint(x: size.width / 2, y: size.height - 50)
                        ] {
                            let rendered = try pixel(actual, at: point)
                            let reference = try pixel(expected, at: point)
                            for (actual, expected) in zip(rendered, reference) {
                                XCTAssertEqual(actual, expected, accuracy: 2,
                                               "\(palette), width=\(width), gradient=\(gradient), reduced=\(reduced)")
                            }
                        }
                        XCTAssertEqual(try pixel(actual, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                                       [255, 255, 255], "Surface translucency must not fade key content.")
                    }
                }
            }
        }
    }

    private func surface(_ palette: ThemePalette, gradient: Bool, reduced: Bool) -> SurfaceStyle {
        if reduced { return palette.raised }
        if gradient { return palette.gradientSurface }
        if #available(iOS 26.0, tvOS 26.0, *) { return palette.raised }
        return SurfaceStyle(fill: Color.primary.opacity(0.07), border: Color.primary.opacity(0.10))
    }

    private func render(_ content: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixel(_ image: CGImage, at point: CGPoint) throws -> [Double] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Double.init)
    }
}
#endif
