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

    func testNativeCollectionBitmapPreservesBothEdgesOfWideArtwork() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 90))
            UIColor.green.setFill()
            context.fill(CGRect(x: 80, y: 0, width: 80, height: 90))
        }
        let environment = EnvironmentValues()
        let presentation = NativeLibraryPosterBitmap.Presentation(
            item: MediaItem(id: "collection", title: "Collection", kind: .collection),
            spoilerSettings: .default, environment: environment
        )
        XCTAssertTrue(presentation.preservesArtwork)
        let bitmap = try XCTUnwrap(NativeLibraryPosterBitmap.image(
            source: source,
            key: .init(image: source, presentation: presentation, size: CGSize(width: 100, height: 150), scale: 1),
            environment: environment
        )?.cgImage)
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
            bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let left = (75 * bitmap.width + 2) * 4
        let right = (75 * bitmap.width + 97) * 4
        let margin = (10 * bitmap.width + 50) * 4
        XCTAssertGreaterThan(pixels[left], 220)
        XCTAssertLessThan(pixels[left + 1], 30)
        XCTAssertGreaterThan(pixels[right + 1], 220)
        XCTAssertLessThan(pixels[right], 30)
        XCTAssertLessThan(pixels[margin], 100)
        XCTAssertLessThan(pixels[margin + 1], 100)
    }
}
#endif
