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
            let segments = [MediaSegment(kind: .intro, start: 20, end: 80)]
            let marked = try render(width: width, segments: segments)
            func color(_ bytes: [UInt8], x: Int, y: Int) -> [UInt8] {
                let index = (y * width + x) * 4
                return Array(bytes[index..<(index + 3)])
            }
            XCTAssertEqual(marked.image.width, width)
            XCTAssertEqual(marked.image.height, 44, "Segment boundaries must not change the touch target.")
            for boundary in [width / 5, width * 4 / 5] {
                for y in 16..<28 {
                    for x in (boundary - 2)..<(boundary + 2) {
                        XCTAssertEqual(color(marked.bytes, x: x, y: y), [0, 255, 255],
                                       "The full-height gap reveals the picture, without backing or surviving rails.")
                    }
                }
                XCTAssertEqual(color(marked.bytes, x: boundary + 3, y: 16), [0, 255, 255])
                XCTAssertNotEqual(color(marked.bytes, x: boundary + 3, y: 22), [0, 255, 255],
                                 "Each section's end is rounded, not square.")
            }
            for x in (width / 5 + 12)..<(width * 4 / 5 - 12) {
                XCTAssertEqual(color(marked.bytes, x: x, y: 22), color(plain.bytes, x: x, y: 22),
                               "Played, buffered, and unplayed sections have no internal cutout or pattern.")
            }
            XCTAssertEqual(color(marked.bytes, x: width / 2, y: 22), [255, 255, 255])
            let crossing = try render(width: width, segments: segments, currentSeconds: 20)
            XCTAssertEqual(color(crossing.bytes, x: width / 5, y: 22), [255, 255, 255],
                           "The playhead stays solid while crossing a boundary.")
            let attachment = XCTAttachment(image: UIImage(cgImage: marked.image))
            attachment.name = "Segmented touch markers at \(width)pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render(width: Int, segments: [MediaSegment], currentSeconds: TimeInterval = 50) throws -> (image: CGImage, bytes: [UInt8]) {
        let renderer = ImageRenderer(content:
            PlayerTouchScrubBar(
                currentSeconds: currentSeconds, duration: 100, bufferedFraction: 0.7, segments: segments,
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
