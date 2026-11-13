#if os(iOS)
import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerSkipMarkerPresentationTests: XCTestCase {
    func testTouchBarPreservesItsHitAreaFillsWithoutAVerticalPlayhead() throws {
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
                for y in 18..<26 {
                    for x in (boundary - 2)..<(boundary + 2) {
                        XCTAssertEqual(color(marked.bytes, x: x, y: y), [0, 255, 255],
                                       "The full-height gap reveals the picture, without backing or surviving rails.")
                    }
                }
                XCTAssertNotEqual(
                    color(marked.bytes, x: boundary + 2, y: 18),
                    color(marked.bytes, x: boundary + 2, y: 22),
                    "The internal cut retains a small corner curve."
                )
                XCTAssertNotEqual(color(marked.bytes, x: boundary + 3, y: 22), [0, 255, 255],
                                 "The body stays filled right up to the narrow cut.")
            }
            for x in (width / 5 + 12)..<(width * 4 / 5 - 12) {
                XCTAssertEqual(color(marked.bytes, x: x, y: 22), color(plain.bytes, x: x, y: 22),
                               "Played, buffered, and unplayed sections have no internal cutout or pattern.")
            }
            XCTAssertEqual(color(marked.bytes, x: width / 2, y: 22), color(marked.bytes, x: width / 2 + 4, y: 22),
                           "The progress edge must not have an extra vertical marker.")
            let crossing = try render(width: width, segments: segments, currentSeconds: 20)
            XCTAssertEqual(color(crossing.bytes, x: width / 5, y: 22), [0, 255, 255],
                           "Advancing progress must not bridge a retained cut with a vertical marker.")
            let attachment = XCTAttachment(image: UIImage(cgImage: marked.image))
            attachment.name = "Segmented touch markers at \(width)pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPortraitTinyMarkersKeepTheContinuousTrackAcrossProgressAndThemes() throws {
        for width in [160, 240, 320, 390, 430] {
            for scheme in [ColorScheme.light, .dark] {
                for position in [10.0, 25, 50, 90] {
                    let plain = try render(width: width, segments: [], currentSeconds: position, colorScheme: scheme)
                    let marked = try render(
                        width: width,
                        segments: [.init(kind: .intro, start: 25, end: 25.5)],
                        currentSeconds: position, colorScheme: scheme
                    )
                    XCTAssertEqual(marked.bytes, plain.bytes,
                                   "Tiny markers must not cut holes in the advancing fill.")
                    XCTAssertEqual(marked.image.height, 44)
                }
            }
        }
    }

    func testMeasuredWidthRestoresTheSameMarkersInWideLayouts() throws {
        let segments = [MediaSegment(kind: .intro, start: 25, end: 28.125)]
        for width in [320, 960] {
            let plain = try render(width: width, segments: [])
            let marked = try render(width: width, segments: segments)
            if width == 320 {
                XCTAssertEqual(marked.bytes, plain.bytes)
            } else {
                XCTAssertNotEqual(marked.bytes, plain.bytes)
                for boundary in [240, 270] {
                    let index = (22 * width + boundary) * 4
                    XCTAssertEqual(Array(marked.bytes[index..<(index + 3)]), [0, 255, 255],
                                   "Widening restores cuts at exact timestamps, without enlarging the marker.")
                }
            }
        }
    }

    func testTinyUnmarkedNeighborDoesNotLeaveAnIsolatedSliver() throws {
        for width in [320, 390] {
            let adjacent = try render(width: width, segments: [
                .init(kind: .intro, start: 20, end: 40),
                .init(kind: .recap, start: 40.5, end: 80)
            ])
            let outerCuts = try render(width: width, segments: [.init(kind: .intro, start: 20, end: 80)])
            XCTAssertEqual(adjacent.bytes, outerCuts.bytes,
                           "Closely spaced cuts are omitted together; distant boundaries stay visible.")
        }
    }

    func testFillOnlyProgressShapesAtZeroMiddleAndEndInBothTouchStates() throws {
        let segments = [
            MediaSegment(kind: .intro, start: 25, end: 28.125),
            MediaSegment(kind: .recap, start: 40, end: 55),
            MediaSegment(kind: .commercial, start: 58.125, end: 75)
        ]
        let layouts: [(CGFloat, [MediaSegment])] = [(240, []), (240, segments), (960, []), (960, segments)]
        for (width, markers) in layouts {
            for touching in [false, true] {
                let height: CGFloat = touching ? 20 : 8
                for progress in [0.0, 0.5, 1.0] {
                    for scheme in [ColorScheme.light, .dark] {
                        let actual = try pixels(
                            PlayerTouchScrubTrack(
                                width: width, progressFraction: progress, bufferedFraction: 0.7,
                                segments: markers, duration: 100, isTouching: touching
                            )
                            .frame(width: width, height: 44)
                            .environment(\.plozzReducePanelGlass, true)
                            .environment(\.colorScheme, scheme)
                            .background(Color(red: 0, green: 1, blue: 1))
                        )
                        let expected = try pixels(
                            ZStack(alignment: .leading) {
                                PlayerScrubTrackSurface(height: height)
                                Capsule().fill(Color.white.opacity(0.14))
                                    .frame(width: width * 0.7, height: height)
                                Rectangle().fill(Color.white.opacity(touching ? 0.9 : 0.62))
                                    .frame(width: width * progress, height: height)
                            }
                            .mask {
                                PlayerSkipMarkerTrack(
                                    segments: markers, duration: 100, height: height, minimumSectionWidth: 20
                                )
                            }
                            .frame(width: width, height: 44)
                            .environment(\.plozzReducePanelGlass, true)
                            .environment(\.colorScheme, scheme)
                            .background(Color(red: 0, green: 1, blue: 1))
                        )
                        XCTAssertTrue(actual.bytes == expected.bytes,
                                      "Progress must remain a masked white fill: width=\(width), touching=\(touching), progress=\(progress), scheme=\(scheme).")
                        if !touching {
                            let control = try render(
                                width: Int(width), segments: markers, currentSeconds: progress * 100, colorScheme: scheme
                            )
                            XCTAssertEqual(control.bytes, actual.bytes,
                                           "The interactive control must not add a marker over the fill-only track.")
                        }
                    }
                }
            }
        }
    }

    private func render(
        width: Int, segments: [MediaSegment], currentSeconds: TimeInterval = 50,
        colorScheme: ColorScheme = .dark
    ) throws -> (image: CGImage, bytes: [UInt8]) {
        try pixels(
            PlayerTouchScrubBar(
                currentSeconds: currentSeconds, duration: 100, bufferedFraction: 0.7, segments: segments,
                onScrub: { _ in XCTFail("Rendering must not seek.") },
                onScrubbingChanged: { _ in XCTFail("Rendering must not begin a gesture.") }
            )
            .frame(width: CGFloat(width), height: 44)
            .environment(\.plozzReducePanelGlass, true)
            .environment(\.colorScheme, colorScheme)
            .background(Color(red: 0, green: 1, blue: 1))
        )
    }

    private func pixels(_ view: some View) throws -> (image: CGImage, bytes: [UInt8]) {
        let renderer = ImageRenderer(content: view)
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
