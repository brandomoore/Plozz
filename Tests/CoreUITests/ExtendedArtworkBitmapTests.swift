#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class ExtendedArtworkBitmapTests: XCTestCase {
    func testRecreatedCardsReuseThePreparedBitmap() throws {
        let source = fixture(size: CGSize(width: 640, height: 360))
        let size = CGSize(width: 320, height: 230)
        let first = try XCTUnwrap(ExtendedArtworkBitmap.render(image: source, size: size, scale: 1))
        let reused = try XCTUnwrap(ExtendedArtworkBitmap.render(image: source, size: size, scale: 1))
        XCTAssertTrue(first === reused)
    }

    func testBitmapReuseIsScopedToSourceSizeAndScale() throws {
        let source = fixture(size: CGSize(width: 640, height: 360))
        let size = CGSize(width: 320, height: 230)
        let first = try XCTUnwrap(ExtendedArtworkBitmap.render(image: source, size: size, scale: 1))
        let otherSource = fixture(size: CGSize(width: 360, height: 640))
        let changedSource = try XCTUnwrap(ExtendedArtworkBitmap.render(image: otherSource, size: size, scale: 1))
        let changedSize = try XCTUnwrap(ExtendedArtworkBitmap.render(
            image: source, size: CGSize(width: 400, height: 280), scale: 1
        ))
        let changedScale = try XCTUnwrap(ExtendedArtworkBitmap.render(image: source, size: size, scale: 2))
        XCTAssertFalse(first === changedSource)
        XCTAssertFalse(first === changedSize)
        XCTAssertFalse(first === changedScale)
        XCTAssertEqual(changedSize.size, CGSize(width: 400, height: 280))
        XCTAssertEqual(changedScale.scale, 2)
        XCTAssertEqual(changedScale.cgImage?.width, 640)
    }

    func testReusingRendererDoesNotChangeAPreviouslyReturnedBitmap() throws {
        let first = try XCTUnwrap(ExtendedArtworkBitmap.render(
            image: fixture(size: CGSize(width: 640, height: 360)),
            size: CGSize(width: 320, height: 230), scale: 1
        ))
        let expected = try pixels(first)
        _ = try XCTUnwrap(ExtendedArtworkBitmap.render(
            image: fixture(size: CGSize(width: 360, height: 640)),
            size: CGSize(width: 400, height: 280), scale: 2
        ))
        XCTAssertEqual(try pixels(first), expected)
    }

    func testBitmapMatchesTheExistingReflectionAndCrop() throws {
        for sourceSize in [CGSize(width: 640, height: 360), CGSize(width: 360, height: 640), CGSize(width: 640, height: 320)] {
            let source = fixture(size: sourceSize)
            for size in [CGSize(width: 320, height: 180), CGSize(width: 320, height: 230)] {
                for scale in [CGFloat(1), 2] {
                    let reference = ImageRenderer(content:
                        ExtendedArtworkFill(image: Image(uiImage: source))
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    )
                    reference.scale = scale
                    reference.isOpaque = true
                    let expected = try XCTUnwrap(reference.uiImage)
                    let actual = try XCTUnwrap(ExtendedArtworkBitmap.render(image: source, size: size, scale: scale))
                    XCTAssertEqual(actual.size, expected.size)
                    let expectedPixels = try pixels(expected)
                    let actualPixels = try pixels(actual)
                    XCTAssertEqual(actualPixels.count, expectedPixels.count)
                    guard actualPixels.count == expectedPixels.count else { continue }
                    let error = zip(actualPixels, expectedPixels).reduce(0.0) {
                        $0 + abs(Double($1.0) - Double($1.1))
                    } / Double(actualPixels.count)
                    XCTAssertLessThanOrEqual(error, 0.8, "source=\(sourceSize) target=\(size) scale=\(scale)")
                }
            }
        }
    }

    private func fixture(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            for index in 0..<24 {
                UIColor(
                    red: CGFloat(index) / 24, green: CGFloat(23 - index) / 24,
                    blue: 0.4, alpha: 1
                ).setFill()
                renderer.fill(CGRect(x: 0, y: CGFloat(index) * size.height / 24,
                                     width: size.width, height: size.height / 24))
            }
            UIColor.blue.setFill()
            renderer.fill(CGRect(x: size.width * 0.35, y: 0,
                                 width: size.width * 0.1, height: size.height))
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }
}
#endif
