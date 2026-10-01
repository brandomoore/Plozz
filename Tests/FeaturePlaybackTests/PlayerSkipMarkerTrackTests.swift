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

    func testCutoutIsCenteredAndExactlyThreeQuartersOfTheTrackHeight() throws {
        XCTAssertEqual(PlayerSkipMarkerTrack.cutoutHeightFraction, 0.75)
        for height in [CGFloat(12), 20] {
            let mask = try pixels(
                PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: height)
                    .frame(width: 320, height: 44)
                    .background(.black)
            )
            let missingHeight = (0..<44).reduce(0.0) { total, y in
                let insideTrack = CGFloat(y) >= (44 - height) / 2 && CGFloat(y) < (44 + height) / 2
                return total + (insideTrack ? 1 - Double(mask.red(x: 80, y: y)) / 255 : 0)
            }
            XCTAssertEqual(missingHeight, Double(height * 0.75), accuracy: 0.05)
            for y in 0..<22 {
                XCTAssertEqual(mask.red(x: 80, y: y), mask.red(x: 80, y: 43 - y),
                               "The cutout must leave equal rails above and below.")
            }
        }
    }

    func testComparisonTreatmentsKeepTheirSizeAndFaintFillSeparate() throws {
        let open = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20)
                .frame(width: 320, height: 44).background(.black)
        )
        let half = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20, treatment: .halfCutout)
                .frame(width: 320, height: 44).background(.black)
        )
        let hatched = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20, treatment: .hatchedCutout)
                .frame(width: 320, height: 44).background(.black)
        )
        let halfHatched = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20, treatment: .halfHatchedCutout)
                .frame(width: 320, height: 44).background(.black)
        )
        XCTAssertEqual(PlayerSkipMarkerTreatment.halfCutout.heightFraction, 0.5)
        XCTAssertEqual(PlayerSkipMarkerTreatment.halfHatchedCutout.heightFraction, 0.5)
        XCTAssertEqual(PlayerSkipMarkerTreatment.hatchedCutout.heightFraction, 0.75)
        XCTAssertEqual(open.red(x: 80, y: 16), 0)
        XCTAssertEqual(half.red(x: 80, y: 16), 255, "The 50% variation has thicker remaining rails.")
        XCTAssertEqual(half.red(x: 80, y: 22), 0)
        XCTAssertEqual(halfHatched.red(x: 80, y: 16), 255, "The 50% patterned option keeps the thicker rails.")
        XCTAssertEqual((64..<112).map { halfHatched.red(x: $0, y: 22) },
                       (64..<112).map { hatched.red(x: $0, y: 22) },
                       "Changing slot height must not change the static pattern's opacity or phase.")
        let hatchPixels = (64..<112).map { hatched.red(x: $0, y: 22) }
        XCTAssertEqual(Double(try XCTUnwrap(hatchPixels.min())) / 255, 0.06, accuracy: 0.01)
        XCTAssertEqual(hatchPixels.max(), 255,
                       "Opaque mask strokes retain the exact bar material, without dimming or recoloring it.")
        XCTAssertEqual(hatched.red(x: 80, y: 12), 255, "The original progress rails are unchanged.")
        XCTAssertEqual(PlayerSkipMarkerTrack.cutoutHeightFraction, 0.75, "The preview must not change the deployed default.")
    }

    func testFlatPerformanceTrackUsesLightTranslucencyWithoutChangingProgressLayers() throws {
        XCTAssertEqual(PlayerScrubTrackSurface.flatFillOpacity, 0.22)
        for height in [CGFloat(12), 20] {
            for background in [Color.black, .gray, .cyan] {
                let actual = try pixels(
                    PlayerScrubTrackSurface(height: height)
                        .frame(width: 320, height: 44)
                        .environment(\.plozzReducePanelGlass, true)
                        .background(background)
                )
                let reference = try pixels(
                    Capsule().fill(.white.opacity(0.22)).frame(height: height)
                        .frame(width: 320, height: 44)
                        .background(background)
                )
                XCTAssertEqual(actual.bytes, reference.bytes,
                               "The performance track is a static white tint, not the dark panel fill or a blur.")
            }
        }
    }

    func testDiagonalsMatchTheUnderlyingPlayedBufferedAndUnplayedFillsExactly() throws {
        for treatment in [PlayerSkipMarkerTreatment.hatchedCutout, .halfHatchedCutout] {
            for height in [CGFloat(12), 20] {
                let mask = try pixels(
                    PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: height, treatment: treatment)
                        .frame(width: 320, height: 44).background(.black)
                )
                for background in [Color.black, .gray, .cyan] {
                    let baseline = try pixels(track(segments: [], height: height, background: background))
                    let patterned = try pixels(track(
                        segments: [marker], height: height, background: background, treatment: treatment
                    ))
                    for region in [48..<120, 144..<184, 208..<272] {
                        let strokeCenters = region.filter { mask.red(x: $0, y: 22) == 255 }
                        let gaps = region.filter { mask.red(x: $0, y: 22) <= 16 }
                        XCTAssertFalse(strokeCenters.isEmpty)
                        XCTAssertFalse(gaps.isEmpty)
                        for x in strokeCenters {
                            XCTAssertEqual(patterned.rgb(x: x, y: 22), baseline.rgb(x: x, y: 22),
                                           "Every stroke must be the original bar, not a highlight or a dimmer color.")
                        }
                        for x in gaps {
                            XCTAssertNotEqual(patterned.rgb(x: x, y: 22), baseline.rgb(x: x, y: 22))
                        }
                    }
                    for x in 124..<132 {
                        XCTAssertEqual(patterned.rgb(x: x, y: 22), [255, 255, 255])
                    }
                    for x in Array(12..<38) + Array(282..<308) {
                        XCTAssertEqual(patterned.rgb(x: x, y: 22), baseline.rgb(x: x, y: 22))
                    }
                    let railY = Int((44 - height) / 2)
                    for x in 48..<272 {
                        XCTAssertEqual(patterned.rgb(x: x, y: railY), baseline.rgb(x: x, y: railY))
                        XCTAssertEqual(patterned.rgb(x: x, y: 43 - railY), baseline.rgb(x: x, y: 43 - railY))
                    }
                }
            }
        }
    }

    func testDiagonalColorsFollowProgressWithoutChangingPatternPhase() throws {
        let mask = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20, treatment: .halfHatchedCutout)
                .frame(width: 320, height: 44).background(.black)
        )
        let centers = (112..<144).filter { mask.red(x: $0, y: 22) == 255 }
        XCTAssertFalse(centers.isEmpty)
        for (played, buffered) in [(0.2, 0.3), (0.3, 0.5), (0.6, 0.8)] {
            let patterned = try pixels(track(
                segments: [marker], played: played, buffered: buffered, treatment: .halfHatchedCutout
            ))
            let plain = try pixels(track(segments: [], played: played, buffered: buffered))
            for x in centers {
                XCTAssertEqual(patterned.rgb(x: x, y: 22), plain.rgb(x: x, y: 22),
                               "The same stroke location follows unbuffered, buffered, then played colors.")
            }
        }
    }

    func testEveryComparisonPatternKeepsTheOriginalColorsInsideAHalfHeightSlot() throws {
        XCTAssertEqual(PlayerSkipMarkerPattern.allCases, [.diagonal, .denseDots, .mediumHatch, .fineHatch, .mesh])
        for height in [CGFloat(12), 20] {
            var renderedPatterns: [[UInt8]] = []
            for pattern in PlayerSkipMarkerPattern.allCases {
                let mask = try pixels(
                    PlayerSkipMarkerTrack(
                        segments: [marker], duration: 100, height: height,
                        treatment: .halfHatchedCutout, pattern: pattern
                    )
                    .frame(width: 320, height: 44).background(.black)
                )
                renderedPatterns.append(mask.bytes)
                let plain = try pixels(track(segments: [], height: height))
                let patterned = try pixels(track(
                    segments: [marker], height: height, treatment: .halfHatchedCutout, pattern: pattern
                ))
                for region in [48..<120, 144..<184, 208..<272] {
                    let centers = region.filter { mask.red(x: $0, y: 22) == 255 }
                    let gaps = region.filter { mask.red(x: $0, y: 22) <= 16 }
                    XCTAssertFalse(centers.isEmpty, "\(pattern) must have recognizable full-color shapes.")
                    XCTAssertFalse(gaps.isEmpty, "\(pattern) must remain a pattern rather than a solid fill.")
                    for x in centers {
                        XCTAssertEqual(patterned.rgb(x: x, y: 22), plain.rgb(x: x, y: 22),
                                       "\(pattern) must not recolor the track.")
                    }
                }
                let railY = Int((44 - height) / 2)
                for x in 48..<272 {
                    XCTAssertEqual(patterned.rgb(x: x, y: railY), plain.rgb(x: x, y: railY))
                    XCTAssertEqual(patterned.rgb(x: x, y: 43 - railY), plain.rgb(x: x, y: 43 - railY))
                }
                XCTAssertEqual(patterned.rgb(x: 128, y: 22), [255, 255, 255])
            }
            for first in renderedPatterns.indices {
                for second in renderedPatterns.indices where first < second {
                    XCTAssertNotEqual(renderedPatterns[first], renderedPatterns[second],
                                      "Each choice must be visually distinct at \(height)pt.")
                }
            }
        }
    }

    func testNewTexturesAreDenseAndTwoDimensionalWithoutChangingTheReference() throws {
        func mask(_ pattern: PlayerSkipMarkerPattern) throws -> Pixels {
            try pixels(
                PlayerSkipMarkerTrack(
                    segments: [marker], duration: 100, height: 20,
                    treatment: .halfHatchedCutout, pattern: pattern
                )
                .frame(width: 320, height: 44).background(.black)
            )
        }
        let diagonal = try mask(.diagonal)
        let medium = try mask(.mediumHatch)
        let fine = try mask(.fineHatch)
        let dots = try mask(.denseDots)
        let mesh = try mask(.mesh)
        func islands(_ image: Pixels, y: Int) -> Int {
            var count = 0
            var previous = false
            for x in 64..<256 {
                let current = image.red(x: x, y: y) > 100
                if current && !previous { count += 1 }
                previous = current
            }
            return count
        }
        XCTAssertEqual(islands(diagonal, y: 22), 12, "Keep the original 16pt diagonal rhythm.")
        XCTAssertEqual(islands(medium, y: 22), 16, "Medium hatch uses the middle 12pt spacing.")
        XCTAssertEqual(islands(fine, y: 22), 24)
        XCTAssertEqual(islands(dots, y: 22), 32, "Dense dots use 6pt spacing rather than the former 12pt row.")
        XCTAssertGreaterThan(islands(dots, y: 18), 25)
        XCTAssertGreaterThan(islands(dots, y: 26), 25)
        XCTAssertNotEqual((64..<256).map { dots.red(x: $0, y: 18) },
                          (64..<256).map { dots.red(x: $0, y: 22) }, "Neighboring rows must be staggered.")
        XCTAssertGreaterThan((64..<256).filter { mesh.red(x: $0, y: 22) > 100 }.count,
                             (64..<256).filter { diagonal.red(x: $0, y: 22) > 100 }.count)
        XCTAssertEqual(islands(mesh, y: 22), 24, "Tighten the mesh to 8pt without changing its line weight.")

        let dotPath = SkipMarkerTrackLayout.pattern(.denseDots, in: CGSize(width: 18, height: 20), slotHeight: 10)
        XCTAssertTrue(dotPath.contains(CGPoint(x: 1.5, y: 10.5)))
        XCTAssertTrue(dotPath.contains(CGPoint(x: 2.4, y: 10.5)))
        XCTAssertFalse(dotPath.contains(CGPoint(x: 2.6, y: 10.5)), "The dot diameter is 2pt, not 3pt.")
        XCTAssertFalse(dotPath.contains(CGPoint(x: 0.4, y: 10.5)))
    }

    #if DEBUG && os(tvOS)
    func testNativeComparisonRequiresExplicitOptInAndUsesOnlyLocalExampleState() {
        XCTAssertFalse(PlayerSkipMarkerPreview.isRequested(environment: [:]))
        XCTAssertFalse(PlayerSkipMarkerPreview.isRequested(environment: ["PLOZZ_SKIP_MARKER_PREVIEW": "true"]))
        XCTAssertTrue(PlayerSkipMarkerPreview.isRequested(environment: ["PLOZZ_SKIP_MARKER_PREVIEW": "1"]))
        let first = PlayerSkipMarkerPreview.makeModel()
        let second = PlayerSkipMarkerPreview.makeModel()
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.duration, 1_440)
        XCTAssertEqual(first.currentSeconds, 675)
        XCTAssertEqual(first.bufferedSeconds, 700)
        XCTAssertEqual(first.skipSegments.segments.map(\.kind), [.recap, .intro, .commercial, .credits])
        first.currentSeconds = 710
        XCTAssertEqual(second.currentSeconds, 675)
    }
    #endif

    func testCutoutRevealsThePictureThroughEveryFillAndKeepsThePlayheadSolid() throws {
        for height in [CGFloat(12), 20] {
            for background in [Color.black, .red, .cyan] {
                let plain = try pixels(track(segments: [], height: height, background: background))
                let cutout = try pixels(track(segments: [marker], height: height, background: background))
                let backdrop = try pixels(background.frame(width: 320, height: 44))
                let railY = Int((44 - height) / 2)
                for x in [80, 160, 240] {
                    XCTAssertEqual(cutout.rgb(x: x, y: 22), backdrop.rgb(x: x, y: 22),
                                   "The center is transparent across played, buffered, and unbuffered portions.")
                    XCTAssertEqual(cutout.rgb(x: x, y: railY), plain.rgb(x: x, y: railY),
                                   "The remaining rail preserves the existing progress fill.")
                    XCTAssertEqual(cutout.rgb(x: x, y: 43 - railY), plain.rgb(x: x, y: 43 - railY))
                }
                for x in 124..<132 {
                    XCTAssertEqual(cutout.rgb(x: x, y: 22), [255, 255, 255], "The playhead is never masked.")
                }
                for x in Array(12..<38) + Array(282..<308) {
                    XCTAssertEqual(cutout.rgb(x: x, y: 22), plain.rgb(x: x, y: 22),
                                   "No cutout outside the marker.")
                }
            }
        }
    }

    func testOverlappingMarkersCreateOneSlotWithoutFillingTheOverlapBackIn() throws {
        let single: [MediaSegment] = [.init(kind: .intro, start: 20, end: 85)]
        let overlapping: [MediaSegment] = [
            .init(kind: .intro, start: 20, end: 70),
            .init(kind: .recap, start: 40, end: 85),
            .init(kind: .commercial, start: 45, end: 60)
        ]
        for pattern in PlayerSkipMarkerPattern.allCases {
            XCTAssertEqual(
                try pixels(track(segments: single, treatment: .halfHatchedCutout, pattern: pattern)).bytes,
                try pixels(track(segments: overlapping, treatment: .halfHatchedCutout, pattern: pattern)).bytes
            )
        }
    }

    func testTheSlotDoesNotMoveAsProgressOrBufferCrossesIt() throws {
        let early = try pixels(track(segments: [marker], played: 0.3, buffered: 0.5, background: .cyan))
        let late = try pixels(track(segments: [marker], played: 0.6, buffered: 0.8, background: .cyan))
        let backdrop = try pixels(Color.cyan.frame(width: 320, height: 44))
        for x in 112..<144 {
            XCTAssertEqual(early.rgb(x: x, y: 22), late.rgb(x: x, y: 22))
            XCTAssertEqual(late.rgb(x: x, y: 22), backdrop.rgb(x: x, y: 22))
        }
    }

    func testSlotsHaveRoundedEndsAndPreserveTheTimelineEndCaps() throws {
        let mask = try pixels(
            PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: 20)
                .frame(width: 320, height: 44)
                .background(.black)
        )
        XCTAssertEqual(mask.red(x: 41, y: 15), 255, "The capsule corner must stay filled.")
        XCTAssertEqual(mask.red(x: 41, y: 22), 0, "The same x-coordinate is cut through at the center.")
        let full = try pixels(
            PlayerSkipMarkerTrack(segments: [.init(kind: .credits, start: 0, end: 100)],
                                 duration: 100, height: 20)
                .frame(width: 320, height: 44)
                .background(.black)
        )
        XCTAssertEqual(full.red(x: 1, y: 22), 255)
        XCTAssertEqual(full.red(x: 318, y: 22), 255)
        XCTAssertEqual(full.red(x: 20, y: 22), 0)
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
            attachment.name = focused ? "Focused seek bar with skip cutouts" : "Normal seek bar with skip cutouts"
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
        segments: [MediaSegment], height: CGFloat = 20, played: Double = 0.4, buffered: Double = 0.6,
        background: Color = .black, treatment: PlayerSkipMarkerTreatment = .cutout,
        pattern: PlayerSkipMarkerPattern = .diagonal
    ) -> some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: height)
                Capsule().fill(.white.opacity(0.14)).frame(width: 320 * buffered, height: height)
                Rectangle().fill(.white.opacity(0.62)).frame(width: 320 * played, height: height)
            }
            .mask {
                PlayerSkipMarkerTrack(segments: segments, duration: 100, height: height,
                                      treatment: treatment, pattern: pattern)
            }
            Rectangle().fill(.white).frame(width: 8, height: 32).offset(x: 320 * played - 4)
        }
        .frame(width: 320, height: 44)
        .background(background)
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]
        func red(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4] }
        func rgb(x: Int, y: Int) -> [UInt8] {
            let index = (y * width + x) * 4
            return Array(bytes[index..<(index + 3)])
        }
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
