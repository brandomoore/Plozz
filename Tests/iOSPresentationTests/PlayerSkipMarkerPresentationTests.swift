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
            for region in [width / 4..<width * 2 / 5, width * 11 / 20..<width * 13 / 20,
                           width * 18 / 25..<width * 39 / 50] {
                let unchanged = region.filter {
                    let index = (22 * width + $0) * 4
                    return marked.bytes[index] == plain.bytes[index]
                }
                let gaps = region.filter {
                    let index = (22 * width + $0) * 4
                    return Double(marked.bytes[index]) <= Double(plain.bytes[index]) * 0.08 + 1
                }
                XCTAssertGreaterThan(unchanged.count, 1, "Fine-hatch strokes retain the original bar color.")
                XCTAssertGreaterThan(gaps.count, region.count / 3, "Gaps still reveal the underlying picture.")
                for x in gaps {
                    let index = (22 * width + x) * 4
                    XCTAssertEqual(marked.bytes[index + 1], 255)
                    XCTAssertEqual(marked.bytes[index + 2], 255)
                }
            }
            let attachment = XCTAttachment(image: UIImage(cgImage: marked.image))
            attachment.name = "Default fine-hatch touch markers at \(width)pt"
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
