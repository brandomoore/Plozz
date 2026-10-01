#if os(iOS)
import CoreModels
import CoreUI
import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerPresentationTests: XCTestCase {
    func testTouchBarPreservesItsHitAreaFillsAndPlayheadWithMarkers() throws {
        for width in [360, 960] {
            let plain = try render(width: width, segments: [])
            let marked = try render(width: width, segments: [
                .init(kind: .intro, start: 20, end: 80)
            ])
            XCTAssertEqual(marked.image.width, width)
            XCTAssertEqual(marked.image.height, 44, "Cutouts must not change the touch target.")
            var changed = 0
            for x in 0..<width {
                let index = (22 * width + x) * 4
                if x < width / 5 - 1 || x > width * 4 / 5 + 1 {
                    XCTAssertEqual(marked.bytes[index], plain.bytes[index], "No cutout outside the skip range.")
                } else if marked.bytes[index] < plain.bytes[index] {
                    changed += 1
                }
            }
            XCTAssertGreaterThan(changed, width / 30)
            XCTAssertEqual(marked.bytes[(22 * width + width / 2) * 4], 255,
                           "The playhead must remain outside the cutout mask.")
            for x in [width / 3, width * 3 / 5, width * 3 / 4] {
                let index = (22 * width + x) * 4
                XCTAssertEqual(Array(marked.bytes[index..<(index + 3)]), [0, 255, 255],
                               "The cutout must reveal the actual picture through every fill.")
            }
            let attachment = XCTAttachment(image: UIImage(cgImage: marked.image))
            attachment.name = "Touch skip cutouts at \(width)pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render(width: Int, segments: [MediaSegment]) throws -> (image: CGImage, bytes: [UInt8]) {
        let renderer = ImageRenderer(content:
            PlayerTouchScrubBar(
                currentSeconds: 50, duration: 100, bufferedFraction: 0.7, segments: segments,
                onScrub: { _ in XCTFail("Rendering must not seek.") },
                onScrubbingChanged: { _ in XCTFail("Rendering must not begin a gesture.") }
            )
            .frame(width: CGFloat(width), height: 44)
            .environment(\.plozzReducePanelGlass, true)
            .background(Color(red: 0, green: 1, blue: 1))
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image, bytes)
    }
}
#endif
