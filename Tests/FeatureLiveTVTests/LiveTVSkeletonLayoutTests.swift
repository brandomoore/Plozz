#if canImport(SwiftUI)
import CoreModels
import SwiftUI
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSkeletonLayoutTests: XCTestCase {
    #if os(tvOS)
    func testPinnedGuideHorizontalGeometryIgnoresTransientTitleSafeInsets() {
        let screen = CGSize(width: 1920, height: 1080)
        for navigationInset: CGFloat in [0, 64] {
            let reference = PrototypePreviewLayout(size: screen, navigationInset: navigationInset)
            for leading: CGFloat in [0, 32, 64, 80, 90] {
                for trailing: CGFloat in [0, 80, 90] {
                    let layout = PrototypePreviewLayout(
                        size: CGSize(width: screen.width - leading - trailing, height: screen.height),
                        safeAreaInsets: EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing),
                        navigationInset: navigationInset
                    )
                    let frame = layout.contentFrame.offsetBy(dx: leading, dy: 0)
                    XCTAssertEqual(frame, reference.contentFrame)
                    XCTAssertEqual(layout.guideWidth, reference.guideWidth)
                    XCTAssertEqual(layout.videoFrame.offsetBy(dx: leading, dy: 0), reference.videoFrame)
                }
            }
        }
    }
    #endif

    func testHeroArtworkGeometryUsesTheSameLayoutAtEveryViewport() {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1024, height: 768),
                     CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            for largeText in [false, true] {
                let layout = PrototypePreviewLayout(size: size, largeText: largeText)
                let expectedHeight = min(layout.heroHeight - PrototypeLayout.smallGap, layout.compact ? 92 : 220)
                XCTAssertEqual(layout.heroArtworkSize.height, expectedHeight.rounded())
                XCTAssertEqual(layout.heroArtworkSize.width, (expectedHeight * 16 / 9).rounded())
                XCTAssertGreaterThan(layout.guideWidth, 0)
            }
        }
    }

    @MainActor
    func testSkeletonAndNativeRowsShareDensityAndColumnMetrics() {
        for width: CGFloat in [320, 600, 1000, 1500] {
            for scale: CGFloat in [1, 1.4, 2] {
                let height = PrototypeLayout.rowHeight(for: width, scaledHeight: PrototypeLayout.rowHeight * scale)
                let base = PrototypeLayout.usesCompactRows(width)
                    ? PrototypeLayout.compactRowHeight : PrototypeLayout.rowHeight
                XCTAssertEqual(height, base * scale, accuracy: 0.001)
                XCTAssertEqual(PrototypeLayout.stationWidth(for: width)
                    + PrototypeLayout.columnGap + PrototypeLayout.timelineWidth(for: width), width, accuracy: 0.001)
                XCTAssertEqual(PrototypeLayout.timelineX(1800, for: width),
                               PrototypeLayout.timelineWidth(for: width) * 1800 / PrototypeLayout.viewportSeconds(for: width))
            }
        }
    }
}
#endif
