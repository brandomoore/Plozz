#if canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import SwiftUI
import XCTest

@MainActor
final class DialogSurfaceTests: XCTestCase {
    func testDarkAndBlackBackdropDimsSeventyTwoPercentWhileLightStaysUnchanged() throws {
        for (palette, opacity) in [
            (ThemePalette.dark, 0.72), (.pureBlack, 0.72), (.light, 0.4)
        ] {
            XCTAssertEqual(palette.dialogBackdropOpacity, opacity)
            let pixels = try render(
                PlozzDialogBackdrop()
                    .frame(width: 200, height: 160)
                    .background(.white)
                    .environment(\.themePalette, palette)
            )
            let center = pixel(pixels, x: 100, y: 80)
            for component in center.prefix(3) {
                XCTAssertEqual(Double(component), 255 * (1 - opacity), accuracy: 2)
            }
            XCTAssertEqual(center[3], 255)
        }
    }

    func testAlreadyStrongerBackdropDoesNotBecomeLighter() throws {
        let pixels = try render(
            PlozzDialogBackdrop(minimumOpacity: 0.72)
                .frame(width: 200, height: 160)
                .background(.white)
                .environment(\.themePalette, .light)
        )
        XCTAssertEqual(Double(pixel(pixels, x: 100, y: 80)[0]), 255 * 0.28, accuracy: 2)
    }

    func testBlackDialogHasASubtleSharedBorderWithoutChangingItsLayout() throws {
        let surface = ThemePalette.pureBlack.surface(.overlay)
        XCTAssertNotNil(surface.border)
        XCTAssertEqual(surface.borderWidth, 1)
        let pixels = try render(
            Color.clear
                .frame(width: 120, height: 80)
                .plozzSurface(.overlay, cornerRadius: 16)
                .padding(40)
                .background(.black)
                .environment(\.themePalette, .pureBlack)
        )
        let border = pixel(pixels, x: 100, y: 40)
        let fill = pixel(pixels, x: 100, y: 44)
        XCTAssertGreaterThan(Int(border[0]), Int(fill[0]) + 10)
        XCTAssertLessThan(border[0], 100, "The outline should remain a subtle hairline.")
    }

    private func render(_ content: some View) throws -> [UInt8] {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 160)
        var pixels = [UInt8](repeating: 0, count: 200 * 160 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 200, height: 160,
                bitsPerComponent: 8, bytesPerRow: 200 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 160))
        }
        return pixels
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        let offset = (y * 200 + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }
}
#endif
