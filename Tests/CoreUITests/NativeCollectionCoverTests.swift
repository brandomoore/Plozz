#if os(tvOS)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class NativeCollectionCoverTests: XCTestCase {
    func testNativeLibraryCellMeasuresBothShapesWithoutChangingOrdinaryPosterGeometry() {
        var environment = EnvironmentValues()
        environment.plozzCardCaptionsHidden = true
        let portrait = NativeTVLibraryCell.height(for: 300, environment: environment)
        let landscape = NativeTVLibraryCell.height(for: 300, environment: environment, style: .landscape)
        let inset = environment.plozzCardStyle == .framed
            ? environment.plozzMetrics.cardInset : environment.plozzMetrics.borderlessCardSideMargin
        XCTAssertEqual(portrait - landscape, (300 - inset * 2) * (1.5 - 9.0 / 16), accuracy: 0.01)
    }

    func testNativeCollectionBitmapFillsPortraitAndLandscapeCardsWithoutGaps() async throws {
        let environment = EnvironmentValues()
        let presentation = NativeLibraryPosterBitmap.Presentation(
            item: MediaItem(id: "collection", title: "Collection", kind: .collection),
            spoilerSettings: .default, environment: environment
        )
        for size in [
            CGSize(width: 400, height: 225), CGSize(width: 300, height: 300),
            CGSize(width: 300, height: 420), CGSize(width: 150, height: 450),
        ] {
            let source = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
                UIColor.green.setFill()
                context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
            }
            for outputSize in [CGSize(width: 100, height: 150), CGSize(width: 160, height: 90)] {
                let key = NativeLibraryPosterBitmap.Key(
                    image: source, presentation: presentation, size: outputSize, scale: 1
                )
                let asynchronous = await NativeLibraryPosterBitmap.composite(
                    source: source, key: key, environment: environment
                )
                try assertFilled(try XCTUnwrap(asynchronous?.cgImage))
                // A different scale exercises the synchronous route instead of reusing the cached image.
                let synchronous = NativeLibraryPosterBitmap.image(
                    source: source,
                    key: .init(image: source, presentation: presentation, size: outputSize, scale: 2),
                    environment: environment
                )
                try assertFilled(try XCTUnwrap(synchronous?.cgImage))
            }
        }
    }

    private func assertFilled(_ bitmap: CGImage) throws {
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        for y in [2, bitmap.height / 2, bitmap.height - 3] {
            let left = (y * bitmap.width + 2) * 4
            let right = (y * bitmap.width + bitmap.width - 3) * 4
            XCTAssertGreaterThan(pixels[left], 220)
            XCTAssertLessThan(pixels[left + 1], 30)
            XCTAssertGreaterThan(pixels[right + 1], 220)
            XCTAssertLessThan(pixels[right], 30)
        }
    }
}
#endif
