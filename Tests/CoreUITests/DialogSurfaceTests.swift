#if canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import SwiftUI
import XCTest

@MainActor
final class DialogSurfaceTests: XCTestCase {
    func testGradientSettingsUseFivePercentWhiteEdgesInDarkAndBlack() throws {
        for palette in [ThemePalette.dark, .pureBlack] {
            let pixels = try render(
                Color.clear.frame(width: 120, height: 80)
                    .settingsGroupSurface(cornerRadius: 16)
                    .padding(40).background(.black)
                    .environment(\.themePalette, palette)
                    .environment(\.gradientBackgroundsEnabled, true)
                    .environment(\.plozzReduceTransparency, false)
            )
            let edge = pixel(pixels, x: 100, y: 40)
            let fill = pixel(pixels, x: 100, y: 44)
            for channel in 0..<3 {
                XCTAssertEqual(Double(edge[channel]), Double(fill[channel]) * 0.95 + 255 * 0.05, accuracy: 2)
            }
        }
    }

    func testSolidSettingsFallbackRetainsItsOriginalBorderAndFill() throws {
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            let original = try render(
                Color.clear.frame(width: 120, height: 80)
                    .plozzSurface(.raised, cornerRadius: 16)
                    .padding(40).background(.black)
                    .environment(\.themePalette, palette)
            )
            for (gradient, reduced) in [(false, false), (true, true)] {
                let settings = try render(
                    Color.clear.frame(width: 120, height: 80)
                        .settingsGroupSurface(cornerRadius: 16)
                        .padding(40).background(.black)
                        .environment(\.themePalette, palette)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                        .environment(\.plozzReduceTransparency, reduced)
                )
                XCTAssertEqual(settings, original)
            }
        }
    }

    func testSettingsGroupsBlendOnlyTheirFillWhenGradientsAllowTransparency() throws {
        let backdrop = Color(red: 0.7, green: 0.3, blue: 0.1)
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(palette.raised.fill).getRed(&r, green: &g, blue: &b, alpha: &a))
            let fill = [Double(r), Double(g), Double(b)]
            for gradient in [false, true] {
                for reduced in [false, true] {
                    let pixels = try render(
                        Color.white.frame(width: 20, height: 20)
                            .frame(width: 120, height: 80)
                            .settingsGroupSurface(cornerRadius: 16)
                            .padding(40)
                            .background(backdrop)
                            .environment(\.themePalette, palette)
                            .environment(\.gradientBackgroundsEnabled, gradient)
                            .environment(\.plozzReduceTransparency, reduced)
                    )
                    let opacity = gradient && !reduced ? 0.2 : 1.0
                    let actual = pixel(pixels, x: 60, y: 60)
                    for channel in 0..<3 {
                        let expected = (fill[channel] * opacity + [0.7, 0.3, 0.1][channel] * (1 - opacity)) * 255
                        XCTAssertEqual(Double(actual[channel]), expected, accuracy: 4,
                                       "Only gradient-backed Settings fills should blend; existing shadows remain.")
                    }
                    XCTAssertEqual(pixel(pixels, x: 100, y: 80), [255, 255, 255, 255],
                                   "The surface must not make its content translucent.")
                }
            }
        }
    }

    func testOrdinaryRaisedSurfacesAndDialogsStayOpaqueWithGradientsOn() throws {
        for palette in [ThemePalette.dark, .pureBlack, .light] {
            for level in [SurfaceLevel.raised, .overlay] {
                let pixels = try render(
                    Color.clear.frame(width: 120, height: 80)
                        .plozzSurface(level, cornerRadius: 16)
                        .padding(40).background(.red)
                        .environment(\.themePalette, palette)
                        .environment(\.gradientBackgroundsEnabled, true)
                )
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(UIColor(palette.surface(level).fill).getRed(&r, green: &g, blue: &b, alpha: &a))
                let actual = pixel(pixels, x: 100, y: 80)
                for (channel, value) in [r, g, b].enumerated() {
                    XCTAssertEqual(Double(actual[channel]), Double(value) * 255, accuracy: 2)
                }
            }
        }
    }

    func testDarkAndBlackBackdropDimsEightyFivePercentWhileLightStaysUnchanged() throws {
        for (palette, opacity) in [
            (ThemePalette.dark, 0.85), (.pureBlack, 0.85), (.light, 0.4)
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
        for (palette, opacity) in [
            (ThemePalette.dark, 0.85), (.pureBlack, 0.85), (.light, 0.72)
        ] {
            let pixels = try render(
                PlozzDialogBackdrop(minimumOpacity: 0.72)
                    .frame(width: 200, height: 160)
                    .background(.white)
                    .environment(\.themePalette, palette)
            )
            XCTAssertEqual(Double(pixel(pixels, x: 100, y: 80)[0]), 255 * (1 - opacity), accuracy: 2)
        }
    }

    func testBlackDialogHasASubtleSharedBorderWithoutChangingItsLayout() throws {
        let surface = ThemePalette.pureBlack.surface(.overlay)
        XCTAssertEqual(surface.border, ThemePalette.darkHairline.opacity(0.13))
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
        XCTAssertLessThan(border[0], 35, "The dialog outline should remain subtle.")
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
