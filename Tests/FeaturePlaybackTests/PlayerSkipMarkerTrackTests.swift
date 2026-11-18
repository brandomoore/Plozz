import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerSkipMarkerTrackTests: XCTestCase {
    private let marker = MediaSegment(id: "intro", kind: .intro, start: 12.5, end: 87.5)

    func testRangesClampSortAndMergeWithoutDuplicateBoundaries() {
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

    func testFlatPerformanceTrackUsesAStaticFillAcrossAppAppearances() throws {
        XCTAssertEqual(PlayerScrubTrackSurface.flatFillOpacity, 0.22)
        for height in [CGFloat(12), 20] {
            for scheme in [ColorScheme.light, .dark] {
                for background in [Color.black, .gray, .cyan] {
                    let actual = try pixels(
                        PlayerScrubTrackSurface(height: height)
                            .frame(width: 320, height: 44)
                            .environment(\.plozzReducePanelGlass, true)
                            .environment(\.colorScheme, scheme)
                            .background(background)
                    )
                    let reference = try pixels(
                        Capsule().fill(.white.opacity(0.22)).frame(height: height)
                            .frame(width: 320, height: 44)
                            .background(background)
                    )
                    XCTAssertTrue(actual.bytes == reference.bytes,
                                  "The fallback track uses the same static fill over video in either app appearance.")
                }
            }
        }
    }

    func testSegmentedSectionsKeepGapsCenteredOnTimingBoundariesAndOuterEndsIntact() {
        let size = CGSize(width: 320, height: 20)
        let expected = [
            CGRect(x: 0, y: 0, width: 38, height: 20),
            CGRect(x: 42, y: 0, width: 236, height: 20),
            CGRect(x: 282, y: 0, width: 38, height: 20)
        ]
        XCTAssertEqual(SkipMarkerTrackLayout.segmentedSections(ranges: [0.125..<0.875], size: size), expected)
        XCTAssertEqual(SkipMarkerTrackLayout.segmentedSections(ranges: [0..<0.125, 0.875..<1], size: size), expected)
        let unbrokenRanges: [[Range<Double>]] = [[], [0..<1]]
        for ranges in unbrokenRanges {
            XCTAssertEqual(SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size),
                           [CGRect(origin: .zero, size: size)])
        }
    }

    func testSegmentedSectionsShrinkGapsInsteadOfErasingOrEnlargingTinyRanges() {
        for width in [CGFloat(360), 960, 1_600] {
            let range = (60.0 / 2_700)..<(68.0 / 2_700)
            let start = width * range.lowerBound
            let end = width * range.upperBound
            let sections = SkipMarkerTrackLayout.segmentedSections(
                ranges: [range], size: CGSize(width: width, height: 20)
            )
            XCTAssertEqual(sections.count, 3)
            XCTAssertEqual(sections[1].midX, (start + end) / 2, accuracy: 0.000001)
            XCTAssertEqual(sections[1].width, (end - start) / 2, accuracy: 0.000001)
            XCTAssertEqual((sections[0].maxX + sections[1].minX) / 2, start, accuracy: 0.000001)
            XCTAssertEqual((sections[1].maxX + sections[2].minX) / 2, end, accuracy: 0.000001)
            XCTAssertEqual(sections[0].minX, 0)
            XCTAssertEqual(sections[2].maxX, width)
        }
    }

    func testBoundaryCornersSoftenTheSliverAndItsNeighborWithoutExceedingTheirBounds() {
        for height in [CGFloat(8), 12, 20] {
            for (widthFraction, radiusFraction) in [
                (CGFloat(0.05), CGFloat(0.0625)), (0.25, 0.3125), (0.5, 0.625),
                (0.75, 0.9375), (1, 1), (2, 1)
            ] {
                let narrowWidth = height * widthFraction
                let narrow = SkipMarkerTrackLayout.cornerSize(
                    sectionWidth: narrowWidth, neighborWidth: 200, height: height
                )
                let wide = SkipMarkerTrackLayout.cornerSize(
                    sectionWidth: 200, neighborWidth: narrowWidth, height: height
                )
                XCTAssertEqual(narrow.height, height / 2 * radiusFraction, accuracy: 0.000001)
                XCTAssertEqual(narrow.width, min(narrowWidth, height) / 2, accuracy: 0.000001)
                XCTAssertEqual(narrow.height, wide.height, "Facing corners meet the gap at the same height.")
                XCTAssertEqual(wide.width, wide.height, "The wider section has room for a circular corner.")
            }
        }
    }

    func testFocusedCornersPreserveSliverProportionsAndRoundTheWiderSideMore() {
        let restingHeight: CGFloat = 12
        for (sectionWidth, neighborWidth) in [(CGFloat(4.8), CGFloat(200)), (200, 4.8), (4.8, 4.8)] {
            let resting = SkipMarkerTrackLayout.cornerSize(
                sectionWidth: sectionWidth, neighborWidth: neighborWidth, height: restingHeight
            )
            for height in [CGFloat(12), 14, 16, 18, 20] {
                let expanded = SkipMarkerTrackLayout.cornerSize(
                    sectionWidth: sectionWidth, neighborWidth: neighborWidth,
                    height: height, referenceHeight: restingHeight
                )
                let extra: CGFloat = sectionWidth > neighborWidth ? (height - restingHeight) * 3 / 16 : 0
                XCTAssertEqual(expanded.width, resting.width + extra)
                XCTAssertEqual(expanded.height, resting.height * height / restingHeight + extra, accuracy: 0.000001)
                XCTAssertLessThanOrEqual(expanded.width, min(sectionWidth, height) / 2)
                XCTAssertLessThanOrEqual(expanded.height, height / 2)
            }
        }
    }

    func testExtraWiderCornerRoundingTapersAtEqualWidthsAndStopsAtFullRounding() {
        XCTAssertEqual(
            SkipMarkerTrackLayout.cornerSize(sectionWidth: 200, neighborWidth: 4.8, height: 20, referenceHeight: 12),
            CGSize(width: 4.5, height: 6.5)
        )
        let almostEqual = SkipMarkerTrackLayout.cornerSize(
            sectionWidth: 5, neighborWidth: 4.8, height: 20, referenceHeight: 12
        )
        XCTAssertEqual(almostEqual.width, 2.5)
        XCTAssertEqual(almostEqual.height, 5.1, accuracy: 0.000001)
        XCTAssertEqual(
            SkipMarkerTrackLayout.cornerSize(sectionWidth: 200, neighborWidth: 40, height: 20, referenceHeight: 12),
            CGSize(width: 10, height: 10)
        )
    }

    func testTightGapsGainOnePointAtRestAndKeepTwoAtFocusFromTheWiderNeighbor() throws {
        for (ranges, narrowIndex) in [
            ([0.02..<0.25], 0), ([0.4..<0.42], 1), ([0.5..<0.98], 2)
        ] {
            for (height, extra) in [
                (CGFloat(12), CGFloat(1)), (14, 1.25), (16, 1.5), (18, 1.75), (20, 2)
            ] {
                let size = CGSize(width: 320, height: height)
                let original = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
                let focused = SkipMarkerTrackLayout.segmentedSections(
                    ranges: ranges, size: size, restingHeight: 12
                )
                var expected = original
                if narrowIndex > 0 {
                    expected[narrowIndex - 1].size.width -= extra
                }
                if narrowIndex < original.count - 1 {
                    expected[narrowIndex + 1].origin.x += extra
                    expected[narrowIndex + 1].size.width -= extra
                }
                XCTAssertEqual(focused, expected)
                XCTAssertEqual(focused[narrowIndex], original[narrowIndex],
                               "The tiny piece must keep its size and position.")
                for index in original.indices.dropLast() {
                    let boundary = (original[index].maxX + original[index + 1].minX) / 2
                    XCTAssertLessThan(focused[index].maxX, boundary)
                    XCTAssertGreaterThan(focused[index + 1].minX, boundary)
                }
            }
        }
    }

    func testFocusedOpticalSpacingPreservesRoomyEqualAndDenselyPackedSections() {
        let size = CGSize(width: 320, height: 20)
        for ranges in [[0.125..<0.875], [0.25..<0.5, 0.75..<1]] {
            XCTAssertEqual(
                SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size, restingHeight: 12),
                SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
            )
        }
        let equalRanges = [0.25..<0.5, 0.75..<1]
        let smallSize = CGSize(width: 16, height: 20)
        let equalOriginal = SkipMarkerTrackLayout.segmentedSections(ranges: equalRanges, size: smallSize)
        let equalFocused = SkipMarkerTrackLayout.segmentedSections(
            ranges: equalRanges, size: smallSize, restingHeight: 12
        )
        XCTAssertEqual(equalFocused[1], equalOriginal[1])
        XCTAssertEqual(equalFocused[2], equalOriginal[2],
                       "Neither equally narrow side should pay for extra spacing.")
        let ranges = [0.4..<0.405, 0.425..<0.43]
        let original = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
        let focused = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size, restingHeight: 12)
        XCTAssertEqual(focused.count, original.count)
        XCTAssertEqual(focused[1], original[1])
        XCTAssertEqual(focused[3], original[3])
        for index in original.indices {
            XCTAssertGreaterThanOrEqual(focused[index].width, original[index].width / 2 - 0.000001,
                                        "Even a section paying for both gaps must retain at least half its width.")
            if index < original.count - 1 {
                XCTAssertLessThan(focused[index].maxX, focused[index + 1].minX)
            }
        }
    }

    func testFocusedOpticalSpacingTapersOutAtFullyRoundedJoins() {
        let size = CGSize(width: 320, height: 20)
        for (start, extra) in [(10.0, 2.0), (14, 2), (16, 1.25), (17, 0.625), (18, 0), (24, 0)] {
            let ranges = [(start / 320)..<0.5]
            let original = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
            let focused = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size, restingHeight: 12)
            XCTAssertEqual(focused[0], original[0])
            XCTAssertEqual(focused[1].minX - original[1].minX, extra, accuracy: 0.000001)
            XCTAssertEqual(focused[1].maxX, original[1].maxX, accuracy: 0.000001)
            XCTAssertEqual(focused[2], original[2])
        }
    }

    func testFocusedNarrowCutsKeepStraightSidesAndPreserveEverySection() throws {
        let size = CGSize(width: 320, height: 20)
        for ranges in [[0.02..<0.25], [0.4..<0.42], [0.5..<0.98]] {
            let sections = SkipMarkerTrackLayout.segmentedSections(
                ranges: ranges, size: size, restingHeight: 12
            )
            let expanded = SkipMarkerTrackLayout.maskPath(
                ranges: ranges, size: size, restingHeight: 12
            )
            let frame = try pixels(
                expanded.fill(.white).frame(width: size.width, height: size.height).background(.black)
            )
            for index in sections.indices {
                let section = sections[index]
                if index > 0 {
                    XCTAssertTrue(expanded.contains(CGPoint(x: section.minX + 0.1, y: 3)))
                    XCTAssertTrue(expanded.contains(CGPoint(x: section.minX + 0.1, y: 17)))
                }
                if index < sections.count - 1 {
                    XCTAssertTrue(expanded.contains(CGPoint(x: section.maxX - 0.1, y: 3)))
                    XCTAssertTrue(expanded.contains(CGPoint(x: section.maxX - 0.1, y: 17)))
                }
            }
            for section in sections {
                XCTAssertEqual(frame.red(x: Int(section.midX), y: 10), 255,
                               "Focus must preserve every section.")
            }
            for index in sections.indices.dropLast() {
                let x = Int((sections[index].maxX + sections[index + 1].minX) / 2)
                for y in 0..<Int(size.height) {
                    XCTAssertEqual(frame.red(x: x, y: y), 0, "The original time boundary must stay fully transparent.")
                }
            }
        }
    }

    func testTVSpacingPreservesMaximumRoomyRoundingAtRestAndFocus() throws {
        for (height, ranges) in [
            (CGFloat(12), [0.125..<0.875]), (20, [0.125..<0.875])
        ] {
            let size = CGSize(width: 320, height: height)
            let original = SkipMarkerTrackLayout.maskPath(ranges: ranges, size: size)
            let referenced = SkipMarkerTrackLayout.maskPath(
                ranges: ranges, size: size, restingHeight: 12
            )
            XCTAssertEqual(
                try pixels(original.fill(.white).frame(width: size.width, height: height).background(.black)).bytes,
                try pixels(referenced.fill(.white).frame(width: size.width, height: height).background(.black)).bytes
            )
        }
    }

    func testRestingSpacingPreservesTheTinyPieceAndItsCornerCurves() throws {
        let size = CGSize(width: 320, height: 12)
        for ranges in [[0.02..<0.25], [0.4..<0.42], [0.5..<0.98]] {
            let sections = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
            let tiny = try XCTUnwrap(sections.first { $0.width < 12 })
            let original = SkipMarkerTrackLayout.maskPath(ranges: ranges, size: size)
            let spaced = SkipMarkerTrackLayout.maskPath(ranges: ranges, size: size, restingHeight: 12)
            let before = try pixels(original.fill(.white).frame(width: 320, height: 12).background(.black))
            let after = try pixels(spaced.fill(.white).frame(width: 320, height: 12).background(.black))
            for x in Int(floor(tiny.minX))..<Int(ceil(tiny.maxX)) {
                for y in 0..<12 {
                    XCTAssertEqual(before.rgb(x: x, y: y), after.rgb(x: x, y: y),
                                   "The wider neighbor pays for resting space without changing the tiny piece.")
                }
            }
        }
    }

    func testNarrowOpeningMiddleAndEndingJoinsStaySoftWithoutMovingTheCuts() throws {
        let height: CGFloat = 20
        for (start, end, filledPixels, gapPixels) in [
            (5.0, 90.0, [7, 8], [4, 5]),
            (230.0, 315.0, [311, 312], [314, 315]),
            (156.0, 164.0, [152, 167], [155, 156, 163, 164])
        ] {
            let range = (start / 320)..<(end / 320)
            let mask = SkipMarkerTrackLayout.maskPath(ranges: [range], size: CGSize(width: 320, height: height))
            let frame = try pixels(
                PlayerSkipMarkerTrack(
                    segments: [.init(kind: .intro, start: start, end: end)], duration: 320, height: height
                )
                .frame(width: 320, height: 44).background(.black)
            )
            for x in filledPixels {
                XCTAssertEqual(frame.red(x: x, y: 13), 255,
                               "A narrow neighboring section must constrain this side of the cut too.")
            }
            for x in gapPixels {
                for y in 12..<32 {
                    XCTAssertEqual(frame.red(x: x, y: y), 0)
                }
            }
            for section in SkipMarkerTrackLayout.segmentedSections(
                ranges: [range], size: CGSize(width: 320, height: height)
            ) {
                XCTAssertTrue(mask.contains(CGPoint(x: section.midX, y: height / 2)),
                              "No short section is erased or shifted.")
            }
        }
    }

    func testShortEndPiecesKeepTopBottomSymmetryWithDifferentInnerAndOuterCorners() throws {
        let size = CGSize(width: 320, height: 20)
        for ranges in [[0.025..<0.5], [0.5..<0.975]] {
            let sections = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
            let section = try XCTUnwrap(sections.first { $0.width < size.height })
            let mask = SkipMarkerTrackLayout.maskPath(ranges: ranges, size: size)
            let actual = try pixels(mask.fill(.white).frame(width: size.width, height: size.height).background(.black))
            for offset in 0..<Int(section.width) {
                let left = Int(section.minX) + offset
                for y in 0..<Int(size.height) {
                    for channel in 0..<3 {
                        XCTAssertEqual(
                            Int(actual.rgb(x: left, y: y)[channel]),
                            Int(actual.rgb(x: left, y: Int(size.height) - 1 - y)[channel]),
                            accuracy: 1, "The short end piece needs symmetric top and bottom corners at \(left),\(y)."
                        )
                    }
                }
            }
        }
        let mask = SkipMarkerTrackLayout.maskPath(ranges: [0.025..<0.5], size: size)
        XCTAssertFalse(mask.contains(CGPoint(x: 10.1, y: 0.1)),
                       "The internal cut retains a small rounded corner.")
        XCTAssertTrue(mask.contains(CGPoint(x: 10.1, y: 4)),
                      "Below the small corner, the cut is vertical rather than a capsule.")
        XCTAssertTrue(mask.contains(CGPoint(x: 10.5, y: 10)))
    }

    func testUnbrokenTracksKeepTheOriginalRoundedMask() throws {
        for height in [CGFloat(8), 12, 20] {
            for (ranges, minimumWidth) in [
                ([Range<Double>](), CGFloat(0)),
                ([0..<1], 0),
                ([0.01..<0.99], 20)
            ] {
                let size = CGSize(width: 320, height: height)
                var reference = Path()
                for section in SkipMarkerTrackLayout.segmentedSections(
                    ranges: ranges, size: size, minimumSectionWidth: minimumWidth
                ) {
                    let radius = min(section.width, section.height) / 2
                    reference.addRoundedRect(in: section, cornerSize: CGSize(width: radius, height: radius))
                }
                let actual = SkipMarkerTrackLayout.maskPath(
                    ranges: ranges, size: size, minimumSectionWidth: minimumWidth
                )
                XCTAssertEqual(
                    try pixels(actual.fill(.white).frame(width: 320, height: height).background(.black)).bytes,
                    try pixels(reference.fill(.white).frame(width: 320, height: height).background(.black)).bytes
                )
            }
        }
        for size in [
            CGSize.zero, CGSize(width: CGFloat.infinity, height: 20), CGSize(width: 320, height: CGFloat.nan)
        ] {
            XCTAssertTrue(SkipMarkerTrackLayout.maskPath(ranges: [0.1..<0.2], size: size).isEmpty)
        }
    }

    func testMultipleMarkersKeepCapsuleOuterEndsAndSoftVerticalInnerCuts() {
        for height in [CGFloat(8), 12, 20] {
            let size = CGSize(width: 320, height: height)
            let ranges = [0.125..<0.375, 0.625..<0.875]
            let sections = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
            let mask = SkipMarkerTrackLayout.maskPath(ranges: ranges, size: size)
            XCTAssertFalse(mask.contains(CGPoint(x: 0.1, y: 0.1)))
            XCTAssertFalse(mask.contains(CGPoint(x: 319.9, y: 0.1)))
            XCTAssertTrue(mask.contains(CGPoint(x: 0.1, y: height / 2)))
            XCTAssertTrue(mask.contains(CGPoint(x: 319.9, y: height / 2)))
            for section in sections.dropFirst() {
                XCTAssertFalse(mask.contains(CGPoint(x: section.minX + 0.1, y: 0.1)))
                XCTAssertFalse(mask.contains(CGPoint(x: section.minX + 0.1, y: 2.1)),
                               "Internal corners have more rounding than the former 2pt radius.")
                XCTAssertFalse(mask.contains(CGPoint(x: section.minX + 0.1, y: height - 2.1)))
                XCTAssertTrue(mask.contains(CGPoint(x: section.minX + 0.1, y: 4)))
                XCTAssertTrue(mask.contains(CGPoint(x: section.minX + 0.1, y: height - 4)))
            }
        }
    }

    func testDefaultMaskHasFullHeightTransparentGapsButNoInternalTexture() throws {
        XCTAssertEqual(PlayerScrubTrackSurface.glassBackingOpacity, 0.10)
        for height in [CGFloat(12), 20] {
            let mask = try pixels(
                PlayerSkipMarkerTrack(segments: [marker], duration: 100, height: height)
                    .frame(width: 320, height: 44).background(.black)
            )
            let top = Int((44 - height) / 2)
            for y in top..<(44 - top) {
                for x in [39, 40, 41, 279, 280, 281] {
                    XCTAssertEqual(mask.red(x: x, y: y), 0, "No rail or backing bridges a segment boundary.")
                }
                for x in [80, 160, 240] {
                    XCTAssertEqual(mask.red(x: x, y: y), 255, "The segment's interior remains solid.")
                }
            }
            XCTAssertLessThan(mask.red(x: 42, y: top), 255, "The internal edge retains a soft corner.")
            XCTAssertGreaterThan(mask.red(x: 43, y: top), 0, "Internal cuts are not full capsule caps.")
            XCTAssertEqual(mask.red(x: 42, y: top + 5), 255, "The cut below its corner stays vertical.")
            for background in [Color.black, .gray, .cyan] {
                let plain = try pixels(track(segments: [], height: height, background: background))
                let divided = try pixels(track(segments: [marker], height: height, background: background))
                let backdrop = try pixels(background.frame(width: 320, height: 44))
                for x in [80, 160, 240] {
                    XCTAssertEqual(divided.rgb(x: x, y: 22), plain.rgb(x: x, y: 22))
                }
                for x in [40, 280] {
                    XCTAssertEqual(divided.rgb(x: x, y: 22), backdrop.rgb(x: x, y: 22))
                }
                XCTAssertEqual(divided.rgb(x: 128, y: 22), [255, 255, 255])
            }
            let crossing = try pixels(track(segments: [marker], height: height, played: 0.125))
            XCTAssertEqual(crossing.rgb(x: 40, y: 22), [255, 255, 255], "The playhead stays solid over a gap.")
        }
    }

    func testOverlappingMarkersCreateOnlyTheMergedSkipBoundaries() throws {
        let single: [MediaSegment] = [.init(kind: .intro, start: 20, end: 85)]
        let overlapping: [MediaSegment] = [
            .init(kind: .intro, start: 20, end: 70),
            .init(kind: .recap, start: 40, end: 85),
            .init(kind: .commercial, start: 45, end: 60)
        ]
        XCTAssertEqual(try pixels(track(segments: single)).bytes, try pixels(track(segments: overlapping)).bytes)
    }

    func testBoundariesDoNotMoveAsProgressOrBufferCrossesThem() throws {
        let backdrop = try pixels(Color.cyan.frame(width: 320, height: 44))
        for (played, buffered) in [(0.1, 0.2), (0.3, 0.5), (0.6, 0.8), (0.9, 1)] {
            let frame = try pixels(track(segments: [marker], played: played, buffered: buffered, background: .cyan))
            for x in [40, 280] {
                XCTAssertEqual(frame.rgb(x: x, y: 22), backdrop.rgb(x: x, y: 22))
            }
        }
    }

    func testNoSegmentsOrOneFullLengthSegmentKeepsOneRoundedTrack() throws {
        let empty = try pixels(track(segments: []))
        XCTAssertEqual(empty.bytes, try pixels(track(segments: [.init(kind: .unknown, start: 0, end: 100)])).bytes)
        XCTAssertEqual(empty.bytes, try pixels(track(segments: [.init(kind: .intro, start: 0, end: 100)])).bytes)
    }

    #if DEBUG && os(tvOS)
    func testManualPreviewRequiresDeveloperModeButNotALaunchFlag() async throws {
        XCTAssertFalse(PlayerMarkerPreviewRequest.isRequested(environment: [:]))
        let suite = "MarkerPreviewDeveloperMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let developerMode = DeveloperModeModel(store: DeveloperModeStore(defaults: defaults))
        let hidden = expectation(description: "marker preview stays hidden without Developer Mode")
        hidden.isInverted = true
        let hiddenObserver = NotificationCenter.default.addObserver(
            forName: PlayerMarkerPreviewRequest.notification, object: nil, queue: .main
        ) { _ in hidden.fulfill() }
        PlayerMarkerPreviewRequest.open(developerMode: developerMode)
        await fulfillment(of: [hidden], timeout: 0.05)
        NotificationCenter.default.removeObserver(hiddenObserver)
        for _ in 0..<DeveloperModeModel.requiredActivations { developerMode.registerUnlockActivation() }
        let opened = expectation(description: "manual marker preview request")
        let observer = NotificationCenter.default.addObserver(
            forName: PlayerMarkerPreviewRequest.notification, object: nil, queue: .main
        ) { _ in opened.fulfill() }
        PlayerMarkerPreviewRequest.open(developerMode: developerMode)
        await fulfillment(of: [opened], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        developerMode.disable()
        let disabled = expectation(description: "disabling Developer Mode revokes marker preview requests")
        disabled.isInverted = true
        let disabledObserver = NotificationCenter.default.addObserver(
            forName: PlayerMarkerPreviewRequest.notification, object: nil, queue: .main
        ) { _ in disabled.fulfill() }
        defer { NotificationCenter.default.removeObserver(disabledObserver) }
        PlayerMarkerPreviewRequest.open(developerMode: developerMode)
        await fulfillment(of: [disabled], timeout: 0.05)
    }

    func testNativeComparisonRequiresExplicitOptInAndUsesOnlyLocalExampleState() {
        XCTAssertTrue(PlayerMarkerPreviewRequest.isAvailable)
        XCTAssertFalse(PlayerSkipMarkerPreview.isRequested(environment: [:]))
        XCTAssertFalse(PlayerSkipMarkerPreview.isRequested(environment: ["PLOZZ_SKIP_MARKER_PREVIEW": "true"]))
        XCTAssertTrue(PlayerSkipMarkerPreview.isRequested(environment: ["PLOZZ_SKIP_MARKER_PREVIEW": "1"]))
        let first = PlayerSkipMarkerPreview.makeModel()
        let second = PlayerSkipMarkerPreview.makeModel()
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.duration, 3_600)
        XCTAssertEqual(first.currentSeconds, 105)
        XCTAssertEqual(first.bufferedSeconds, 115)
        XCTAssertEqual(first.skipSegments.segments.map(\.kind), [.intro, .credits])
        first.currentSeconds = 710
        XCTAssertEqual(second.currentSeconds, 105)
    }

    func testRealisticScenariosUseExactDurationsAndNeverEnlargeShortRanges() {
        let hour = PlayerSkipMarkerScenario.hourEpisode
        let movie = PlayerSkipMarkerScenario.longMovie
        XCTAssertEqual(hour.duration, 3_600)
        XCTAssertEqual(hour.target.end - hour.target.start, 30)
        XCTAssertEqual(movie.duration, 10_800)
        XCTAssertEqual(movie.target.end - movie.target.start, 120)
        for scenario in PlayerSkipMarkerScenario.allCases {
            let model = PlayerSkipMarkerPreview.makeModel()
            scenario.apply(to: model)
            XCTAssertEqual(model.duration, scenario.duration)
            XCTAssertEqual(model.skipSegments.segments, scenario.segments)
            XCTAssertTrue(scenario.target.contains(model.currentSeconds))
            XCTAssertTrue(scenario.positions.allSatisfy { $0 >= 0 && $0 <= scenario.duration })
            XCTAssertEqual(
                SkipMarkerTrackLayout.ranges(segments: [scenario.target], duration: scenario.duration),
                [(scenario.target.start / scenario.duration)..<(scenario.target.end / scenario.duration)]
            )
        }
        let hourRange = SkipMarkerTrackLayout.ranges(segments: [hour.target], duration: hour.duration)[0]
        let movieRange = SkipMarkerTrackLayout.ranges(segments: [movie.target], duration: movie.duration)[0]
        XCTAssertEqual((hourRange.upperBound - hourRange.lowerBound) * 1_600, 13.333333, accuracy: 0.000001)
        XCTAssertEqual((movieRange.upperBound - movieRange.lowerBound) * 1_600, 17.777778, accuracy: 0.000001)
        let hourSections = SkipMarkerTrackLayout.segmentedSections(
            ranges: [hourRange], size: CGSize(width: 1_600, height: 20)
        )
        let movieSections = SkipMarkerTrackLayout.segmentedSections(
            ranges: [movieRange], size: CGSize(width: 1_600, height: 20)
        )
        XCTAssertEqual(hourSections[1].width, 13.333333 - 4, accuracy: 0.000001)
        XCTAssertEqual(movieSections[1].width, 17.777778 - 2, accuracy: 0.000001)
    }
    #endif

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
            attachment.name = focused ? "Focused segmented seek bar" : "Normal segmented seek bar"
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
        background: Color = .black
    ) -> some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: height)
                Capsule().fill(.white.opacity(0.14)).frame(width: 320 * buffered, height: height)
                Rectangle().fill(.white.opacity(0.62)).frame(width: 320 * played, height: height)
            }
            .mask {
                PlayerSkipMarkerTrack(segments: segments, duration: 100, height: height)
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
