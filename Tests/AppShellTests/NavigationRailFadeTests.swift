#if os(tvOS)
import CoreGraphics
import SwiftUI
import XCTest
@testable import AppShell

@MainActor
final class NavigationRailFadeTests: XCTestCase {
    func testPartiallyOverflowingGlyphsFadeToTransparentAtTheClipEdge() throws {
        for overflow: CGFloat in [8, 12, 24, 44] {
            for top in [false, true] {
                let height = ListEdgeFade.height(for: overflow)
                let fade = ListEdgeFade(top: top ? height : 0, bottom: top ? 0 : height)
                let pixels = try render(fade)
                XCTAssertLessThan(alpha(pixels, y: top ? 0 : 199), 16,
                                  "Overflow \(overflow) must not end in an opaque cut.")
                XCTAssertGreaterThan(alpha(pixels, y: top ? 199 : 0), 250)
                XCTAssertGreaterThan(alpha(pixels, y: 100), 250)
            }
        }
    }

    func testReachedEdgesRemainReadable() throws {
        let pixels = try render(ListEdgeFade())
        XCTAssertGreaterThan(alpha(pixels, y: 0), 250)
        XCTAssertGreaterThan(alpha(pixels, y: 199), 250)
    }

    func testFeatherHeightIsContinuousAtTheContentBoundary() {
        XCTAssertEqual(ListEdgeFade.height(for: -2), 0)
        XCTAssertEqual(ListEdgeFade.height(for: 0), 0)
        XCTAssertEqual(ListEdgeFade.height(for: 0.25), 0.25)
        XCTAssertEqual(ListEdgeFade.height(for: 12), 12)
        XCTAssertEqual(ListEdgeFade.height(for: 100), NavigationRailMetrics.listEdgeFade)
    }

    private func render(_ fade: ListEdgeFade) throws -> [UInt8] {
        let renderer = ImageRenderer(content: fade.mask.frame(width: 200, height: 200))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 200 * 200 * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 200, height: 200,
                bitsPerComponent: 8, bytesPerRow: 200 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        return pixels
    }

    private func alpha(_ pixels: [UInt8], y: Int) -> Int { Int(pixels[(y * 200 + 100) * 4 + 3]) }
}
#endif
