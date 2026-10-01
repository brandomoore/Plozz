import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerSkipMarkerTrackTests: XCTestCase {
    private let marker = MediaSegment(id: "intro", kind: .intro, start: 12.5, end: 87.5)

    func testRangesClampSortAndMergeWithoutDoublePainting() {
        let segments: [MediaSegment] = [
            .init(kind: .credits, start: 80, end: 120),
            .init(kind: .intro, start: -10, end: 20),
            .init(kind: .recap, start: 10, end: 30),
            .init(kind: .commercial, start: 30, end: 40),
            .init(kind: .preview, start: 60, end: 70)
        ]
        XCTAssertEqual(
            SkipMarkerTrackLayout.ranges(segments: segments, duration: 100),
            [0..<0.4, 0.6..<0.7, 0.8..<1]
        )
    }

    func testUnknownDurationAndMalformedOrUnknownMarkersDoNotDraw() {
        for duration in [0, -10, Double.nan, .infinity] {
            XCTAssertTrue(SkipMarkerTrackLayout.ranges(segments: [marker], duration: duration).isEmpty)
        }
        let segments: [MediaSegment] = [
            .init(kind: .intro, start: .nan, end: 40),
            .init(kind: .intro, start: 10, end: .infinity),
            .init(kind: .intro, start: 20, end: 10),
            .init(kind: .intro, start: 20, end: 20),
            .init(kind: .credits, start: 101, end: 120),
            .init(kind: .recap, start: -20, end: -1),
            .init(kind: .unknown, start: 0, end: 100)
        ]
        XCTAssertTrue(SkipMarkerTrackLayout.ranges(segments: segments, duration: 100).isEmpty)
    }

    func testStyleMatchesTheApprovedSubtleStaticPattern() {
        XCTAssertEqual(PlayerSkipMarkerTrack.spacing, 16)
        XCTAssertEqual(PlayerSkipMarkerTrack.lineWidth, 2)
        XCTAssertEqual(PlayerSkipMarkerTrack.opacity, 0.24)
    }

    func testHatchKeepsAllThreeFillsAndTheWhitePlayheadDistinct() throws {
        for height in [CGFloat(12), 20] {
            let plain = try pixels(track(segments: [], height: height))
            let hatched = try pixels(track(segments: [marker], height: height))
            var darkest: [UInt8] = []
            for region in [48..<120, 144..<184, 208..<272] {
                let before = region.map { plain.red(x: $0, y: 22) }
                let after = region.map { hatched.red(x: $0, y: 22) }
                let base = try XCTUnwrap(before.max())
                let low = try XCTUnwrap(after.min())
                XCTAssertEqual(after.max(), before.max(), "The spaces between stripes preserve the existing fill.")
                XCTAssertLessThan(low, base, "Each fill must show the pattern.")
                let darkening = 1 - Double(low) / Double(base)
                XCTAssertGreaterThan(darkening, 0.18)
                XCTAssertLessThan(darkening, 0.28, "Hatching must remain subtle on \(height)pt bars.")
                darkest.append(low)
            }
            XCTAssertGreaterThan(darkest[0], darkest[1])
            XCTAssertGreaterThan(darkest[1], darkest[2])
            for x in 124..<132 {
                XCTAssertEqual(hatched.red(x: x, y: 22), 255, "Never hatch over the playhead.")
            }
            for x in Array(12..<38) + Array(282..<308) {
                XCTAssertEqual(hatched.red(x: x, y: 22), plain.red(x: x, y: 22), "No paint outside the marker.")
            }
        }
    }

    func testOverlappingMarkersRenderExactlyOnceAndDoNotMoveThePattern() throws {
        let single: [MediaSegment] = [.init(kind: .intro, start: 20, end: 85)]
        let overlapping: [MediaSegment] = [
            .init(kind: .intro, start: 20, end: 70),
            .init(kind: .recap, start: 40, end: 85),
            .init(kind: .commercial, start: 45, end: 60)
        ]
        XCTAssertEqual(try pixels(track(segments: single)).bytes,
                       try pixels(track(segments: overlapping)).bytes)
    }

    func testPatternPhaseDoesNotChangeAsProgressOrBufferCrossesIt() throws {
        let early = try pixels(track(segments: [marker], played: 0.3, buffered: 0.5))
        let late = try pixels(track(segments: [marker], played: 0.6, buffered: 0.8))
        let earlyBase = try pixels(track(segments: [], played: 0.3, buffered: 0.5))
        let lateBase = try pixels(track(segments: [], played: 0.6, buffered: 0.8))
        let region = 112..<144
        let earlyStripes = region.map { early.red(x: $0, y: 22) < earlyBase.red(x: $0, y: 22) - 3 }
        let lateStripes = region.map { late.red(x: $0, y: 22) < lateBase.red(x: $0, y: 22) - 3 }
        XCTAssertEqual(earlyStripes, lateStripes)
        XCTAssertTrue(earlyStripes.contains(true))
        XCTAssertTrue(earlyStripes.contains(false))
    }

    func testNoSegmentsPreservesUnmarkedBarAndRoundedEnds() throws {
        let empty = try pixels(track(segments: []))
        XCTAssertEqual(empty.bytes, try pixels(track(segments: [.init(kind: .unknown, start: 0, end: 100)])).bytes)
        let full = try pixels(track(segments: [.init(kind: .intro, start: 0, end: 100)]))
        for (x, y) in [(0, 12), (0, 31), (319, 12), (319, 31)] {
            XCTAssertEqual(full.red(x: x, y: y), empty.red(x: x, y: y), "The pattern must remain inside the capsule.")
        }
    }

    #if os(tvOS)
    func testActualTVScrubBarShowsMarkersWithoutChangingSkipState() throws {
        let model = PlayerControlsModel()
        model.duration = 100
        model.currentSeconds = 40
        model.bufferedSeconds = 60
        model.controlsVisible = true
        model.skipSegments.segments = [marker]
        model.skipSegments.dismissedSegmentID = marker.id
        model.skipModes = .allOff
        for focused in [false, true] {
            model.controlBarVisible = !focused
            let renderer = ImageRenderer(content:
                ScrubBar(model: model, palette: .dark)
                    .frame(width: 1280, height: 44)
                    .environment(\.plozzReducePanelGlass, true)
                    .background(.black)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = focused ? "Focused seek bar with subtle skip markers" : "Normal seek bar with subtle skip markers"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(image.width, 1280)
            XCTAssertEqual(image.height, 44)
        }
        XCTAssertNil(model.activeSkipSegment)
        XCTAssertEqual(model.skipModes, .allOff)
        XCTAssertEqual(model.currentSeconds, 40)
        XCTAssertFalse(model.isScrubbing)
    }
    #endif

    private func track(
        segments: [MediaSegment], height: CGFloat = 20, played: Double = 0.4, buffered: Double = 0.6
    ) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.2)).frame(height: height)
            Capsule().fill(.white.opacity(0.14)).frame(width: 320 * buffered, height: height)
            Rectangle().fill(.white.opacity(0.62)).frame(width: 320 * played, height: height)
            PlayerSkipMarkerTrack(segments: segments, duration: 100, height: height)
            Rectangle().fill(.white).frame(width: 8, height: 32).offset(x: 320 * played - 4)
        }
        .frame(width: 320, height: 44)
        .background(.black)
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func red(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4] }
    }

    private func pixels(_ view: some View) throws -> Pixels {
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
        return Pixels(width: image.width, bytes: bytes)
    }
}
