#if canImport(UIKit)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MetadataTextScalingTests: XCTestCase {
    private func size(of view: some View) -> CGSize {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, .large))
            .sizeThatFits(in: CGSize(width: 2000, height: 500))
    }

    func testReviewScoresScaleTheirIconsFontAndGapTogether() {
        #if os(iOS)
        let iconSize: CGFloat = 20
        let fontSize: CGFloat = 15
        #else
        let iconSize: CGFloat = 24
        let fontSize: CGFloat = 23
        #endif
        for scale: CGFloat in [0.75, 1, 1.25, 1.5] {
            for source in RatingSource.allCases {
                let rating = ExternalRating(source: source, value: 84, scale: .percent)
                let actual = size(of: RatingBadge(rating: rating)
                    .environment(\.horizontalSizeClass, .regular)
                    .environment(\.metadataTextScale, scale))
                let expected = size(of: HStack(spacing: 4 * scale) {
                    RatingSourceIcon(rating: rating, size: iconSize * scale)
                    Text(rating.displayValue)
                        .font(.system(size: fontSize * scale, weight: .medium))
                        .monospacedDigit()
                }.fixedSize())
                XCTAssertEqual(actual.width, expected.width, accuracy: 1, "\(source), \(scale)")
                XCTAssertEqual(actual.height, expected.height, accuracy: 1, "\(source), \(scale)")
            }
        }
    }

    func testCertificateBorderThicknessAndHeightTrackItsText() throws {
        #if os(iOS)
        let border: CGFloat = 2
        let height: CGFloat = 32
        #else
        let border: CGFloat = 3
        let height: CGFloat = 36
        #endif
        for scale: CGFloat in [0.75, 1, 1.25, 1.5] {
            let badge = MediaBadgeChip(badge: MediaBadge("PG", style: .rating))
                .environment(\.horizontalSizeClass, .regular)
                .environment(\.dynamicTypeSize, .large)
                .environment(\.metadataTextScale, scale)
            XCTAssertEqual(size(of: badge).height, height * scale, accuracy: 0.5)
            let renderer = ImageRenderer(content: badge)
            renderer.scale = 4
            let image = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let row = image.height / 2
            let thickness = (0..<image.width).prefix {
                pixels[(row * image.width + $0) * 4 + 3] > 100
            }.count
            XCTAssertEqual(CGFloat(thickness), border * scale * renderer.scale, accuracy: 1)
        }
    }

    func testFamilyGuidanceScalesAndCompactBadgeStylingRemainsIndependent() {
        let baseline = size(of: FamilyGuidanceAgeBadge(age: 12))
        for scale: CGFloat in [0.75, 1, 1.25, 1.5] {
            let scaled = size(of: FamilyGuidanceAgeBadge(age: 12).environment(\.metadataTextScale, scale))
            XCTAssertEqual(scaled.height, baseline.height * scale, accuracy: 1)
            XCTAssertEqual(scaled.width, baseline.width * scale, accuracy: 3)
            let badge = MediaBadge("4K", style: .prominent)
            let combined = size(of: MediaBadgeChip(badge: badge)
                .environment(\.mediaBadgeScale, 0.8)
                .environment(\.metadataTextScale, scale))
            // Native hosting rounds to display pixels, not necessarily whole points.
            let expected = size(of: Color.clear.frame(width: 1, height: 22 * 0.8 * scale))
            XCTAssertEqual(combined.height, expected.height, accuracy: 0.01)
        }
    }
}
#endif
