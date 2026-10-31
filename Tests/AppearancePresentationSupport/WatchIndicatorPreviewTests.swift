import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class WatchIndicatorPreviewTests: XCTestCase {
    func testHiddenPreviewRemovesMarksButPreservesCountAndProgressPixels() throws {
        let size = CGSize(width: 412, height: 150)
        let hidden = try render(.hidden, size: size, direction: .leftToRight, showsCount: true)
        for mode in [WatchStatusIndicator.watched, .unwatched] {
            let marked = try render(mode, size: size, direction: .leftToRight, showsCount: true)
            XCTAssertNotEqual(UIImage(cgImage: hidden).pngData(), UIImage(cgImage: marked).pngData())
            let middle = CGRect(x: size.width / 2 - 30, y: 0, width: 60, height: size.height)
            XCTAssertEqual(try pixels(hidden, in: middle), try pixels(marked, in: middle))
            let bottom = CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3)
            XCTAssertEqual(try pixels(hidden, in: bottom), try pixels(marked, in: bottom))
        }
    }

    func testEpisodeCountOnlyChangesTheSeriesCornerInBothPreviewStyles() throws {
        for size in [CGSize(width: 135, height: 112), CGSize(width: 412, height: 150),
                     CGSize(width: 500, height: 248)] {
            for indicator in WatchStatusIndicator.allCases {
                for (style, direction) in EpisodeCountBadgeStyle.allCases.flatMap({ style in
                    [LayoutDirection.leftToRight, .rightToLeft].map { (style, $0) }
                }) {
                    let hidden = try render(
                        indicator, size: size, direction: direction, showsCount: false, countStyle: style
                    )
                    let visible = try render(
                        indicator, size: size, direction: direction, showsCount: true, countStyle: style
                    )
                    let middle = CGRect(x: size.width / 3, y: 0, width: size.width / 3, height: size.height * 0.6)
                    XCTAssertNotEqual(try pixels(hidden, in: middle), try pixels(visible, in: middle),
                                      "The series must show the count in \(indicator) at \(size), \(direction).")
                    for unchanged in [
                        CGRect(x: 0, y: 0, width: size.width / 3, height: size.height),
                        CGRect(x: size.width * 2 / 3, y: 0, width: size.width / 3, height: size.height),
                        CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3)
                    ] {
                        XCTAssertEqual(try pixels(hidden, in: unchanged), try pixels(visible, in: unchanged),
                                       "The count toggle must preserve colored watch marks and progress.")
                    }
                    if direction == .leftToRight {
                        let attachment = XCTAttachment(image: UIImage(cgImage: visible))
                        attachment.name = "count-preview-\(indicator)-\(style)-\(Int(size.width))"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }

    func testCountPlacementChangesOnlyTheSeriesInBothWatchModes() throws {
        let size = CGSize(width: 412, height: 150)
        for indicator in WatchStatusIndicator.allCases {
            let attached = try render(indicator, size: size, direction: .leftToRight, showsCount: true)
            let floating = try render(
                indicator, size: size, direction: .leftToRight, showsCount: true, countStyle: .floating
            )
            let middle = CGRect(x: size.width / 3, y: 0, width: size.width / 3, height: size.height)
            XCTAssertNotEqual(try pixels(attached, in: middle), try pixels(floating, in: middle))
            for x in [CGFloat(0), size.width * 2 / 3] {
                let outside = CGRect(x: x, y: 0, width: size.width / 3, height: size.height)
                XCTAssertEqual(try pixels(attached, in: outside), try pixels(floating, in: outside))
            }
        }
    }

    private func render(
        _ indicator: WatchStatusIndicator, size: CGSize, direction: LayoutDirection, showsCount: Bool,
        countStyle: EpisodeCountBadgeStyle = .attached
    ) throws -> CGImage {
        let renderer = ImageRenderer(content:
            WatchStatusIndicatorSwatch(indicator: indicator)
                .frame(width: size.width, height: size.height)
                .environment(\.layoutDirection, direction)
                .environment(\.plozzWatchIndicatorColor, .purple)
                .environment(\.plozzShowsUnwatchedEpisodeCount, showsCount)
                .environment(\.plozzEpisodeCountBadgeStyle, countStyle)
        )
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    private func pixels(_ image: CGImage, in rect: CGRect) throws -> Data {
        let crop = try XCTUnwrap(image.cropping(to: rect.applying(CGAffineTransform(scaleX: 2, y: 2))))
        return try XCTUnwrap(UIImage(cgImage: crop).pngData())
    }
}
