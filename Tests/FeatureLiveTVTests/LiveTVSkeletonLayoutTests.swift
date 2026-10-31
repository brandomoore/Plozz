#if canImport(SwiftUI)
import CoreModels
import SwiftUI
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSkeletonLayoutTests: XCTestCase {
    #if os(tvOS)
    func testHorizontalNavigationInsetsBrowsingWithoutShrinkingFullscreenBounds() {
        let keylines = EdgeInsets(top: 124, leading: 96, bottom: 0, trailing: 80)
        for safeArea in [
            EdgeInsets(),
            EdgeInsets(top: 60, leading: 80, bottom: 0, trailing: 80),
            EdgeInsets(top: 90, leading: 90, bottom: 0, trailing: 70)
        ] {
            let size = CGSize(
                width: 1920 - safeArea.leading - safeArea.trailing,
                height: 1080 - safeArea.top
            )
            let layout = PrototypePreviewLayout(
                size: size, safeAreaInsets: safeArea,
                nativeNavigation: true, topNavigationInsets: keylines
            )
            let frame = layout.contentFrame.offsetBy(dx: safeArea.leading, dy: safeArea.top)
            XCTAssertEqual(frame.minY, 140)
            XCTAssertEqual(frame.minX, 96)
            XCTAssertEqual(frame.maxX, 1840)
            XCTAssertEqual(layout.bounds.offsetBy(dx: safeArea.leading, dy: safeArea.top),
                           CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let skeleton = PrototypePreviewLayout(
                size: size, safeAreaInsets: safeArea,
                topNavigationInsets: keylines
            )
            XCTAssertEqual(skeleton.contentFrame, layout.contentFrame)
        }
    }

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
                let expectedHeight = max(0, min(layout.heroHeight - PrototypeLayout.smallGap, layout.compact ? 92 : 220))
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
