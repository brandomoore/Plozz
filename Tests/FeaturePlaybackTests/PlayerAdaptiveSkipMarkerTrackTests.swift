import CoreGraphics
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerAdaptiveSkipMarkerTrackTests: XCTestCase {
    private let minimumSectionWidth: CGFloat = 20

    func testPortraitTinyMarkerKeepsOneTrackWithoutEnlargingItsTimeRange() {
        let marker = MediaSegment(kind: .intro, start: 60, end: 68)
        let ranges = SkipMarkerTrackLayout.ranges(segments: [marker], duration: 2_700)
        XCTAssertEqual(ranges, [(60.0 / 2_700)..<(68.0 / 2_700)])
        for width in [CGFloat(160), 240, 320, 360, 390, 430] {
            for height in [CGFloat(8), 20] {
                let size = CGSize(width: width, height: height)
                XCTAssertEqual(sections(ranges, size: size), [CGRect(origin: .zero, size: size)])
            }
        }
        XCTAssertEqual(marker.start, 60)
        XCTAssertEqual(marker.end, 68)
    }

    func testMeasuredWidthRestoresCutsWhenEverySectionHasRoom() {
        let ranges = [0.25..<0.275]
        let portrait = CGSize(width: 320, height: 8)
        XCTAssertEqual(sections(ranges, size: portrait), [CGRect(origin: .zero, size: portrait)])
        for width in [CGFloat(960), 1_600] {
            let size = CGSize(width: width, height: 8)
            XCTAssertEqual(sections(ranges, size: size),
                           SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size))
            XCTAssertEqual(sections(ranges, size: size).count, 3)
        }
    }

    func testMinimumAccountsForBothGapsAndIsStableAcrossTouchHeights() throws {
        let ranges = [0.25..<0.375]
        let tooSmall = CGSize(width: 191, height: 8)
        XCTAssertEqual(sections(ranges, size: tooSmall), [CGRect(origin: .zero, size: tooSmall)])
        for height in [CGFloat(8), 20] {
            let result = sections(ranges, size: CGSize(width: 192, height: height))
            XCTAssertEqual(result.count, 3)
            let middle = try XCTUnwrap(result.dropFirst().first)
            XCTAssertEqual(middle.width, minimumSectionWidth)
            XCTAssertEqual(middle.minX, 50)
            XCTAssertEqual(middle.maxX, 70)
        }
    }

    func testTinyUnmarkedNeighborSuppressesBothCutsButKeepsSeparatedOuterBoundaries() {
        let size = CGSize(width: 320, height: 20)
        let result = sections([0.2..<0.4, 0.405..<0.7], size: size)
        XCTAssertEqual(result, [
            CGRect(x: 0, y: 0, width: 62, height: 20),
            CGRect(x: 66, y: 0, width: 156, height: 20),
            CGRect(x: 226, y: 0, width: 94, height: 20)
        ])
        XCTAssertEqual((result[0].maxX + result[1].minX) / 2, 64)
        XCTAssertEqual((result[1].maxX + result[2].minX) / 2, 224)
    }

    func testTinyOuterIntervalsDoNotLeaveDetachedEndCaps() {
        let size = CGSize(width: 320, height: 8)
        XCTAssertEqual(sections([0.01..<0.5], size: size), [
            CGRect(x: 0, y: 0, width: 158, height: 8),
            CGRect(x: 162, y: 0, width: 158, height: 8)
        ])
        XCTAssertEqual(sections([0.5..<0.99], size: size), [
            CGRect(x: 0, y: 0, width: 158, height: 8),
            CGRect(x: 162, y: 0, width: 158, height: 8)
        ])
        XCTAssertEqual(sections([0.01..<0.99], size: size), [CGRect(origin: .zero, size: size)])
    }

    func testDenseMarkersCannotStrandTinySectionsOrShiftRetainedBoundaries() {
        let ranges = [0.001..<0.002, 0.10..<0.30, 0.305..<0.307, 0.31..<0.60, 0.90..<0.999]
        for width in [CGFloat(180), 240, 320, 390, 768, 960, 1_600] {
            let size = CGSize(width: width, height: 20)
            let result = sections(ranges, size: size)
            XCTAssertEqual(result.first?.minX, 0)
            XCTAssertEqual(result.last?.maxX, width)
            XCTAssertTrue(result.allSatisfy { $0.width >= minimumSectionWidth })
            let originalBoundaries = ranges.flatMap { [$0.lowerBound, $0.upperBound] }.map { width * $0 }
            for (left, right) in zip(result, result.dropFirst()) {
                XCTAssertEqual(right.minX - left.maxX, 4, accuracy: 0.000001)
                let boundary = (left.maxX + right.minX) / 2
                XCTAssertTrue(originalBoundaries.contains { abs($0 - boundary) < 0.000001 },
                              "A surviving cut must still represent an exact media boundary.")
            }
        }
    }

    func testRawLayoutCanRetainTinySectionsWithoutAdaptiveSuppression() throws {
        let size = CGSize(width: 360, height: 20)
        let ranges = [(60.0 / 2_700)..<(68.0 / 2_700)]
        let original = SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size)
        XCTAssertEqual(original.count, 3)
        let middle = try XCTUnwrap(original.dropFirst().first)
        XCTAssertEqual(middle.width, 360 * (8.0 / 2_700) / 2, accuracy: 0.000001)
        XCTAssertEqual(sections(ranges, size: size), [CGRect(origin: .zero, size: size)])
    }

    func testDenseMovieEndingDisappearsWithoutRemovingAnIsolatedIntroOrChangingMarkers() {
        let duration = 8_142.656
        let credits: [MediaSegment] = [
            .init(kind: .credits, start: 7_754.39, end: 7_784.39),
            .init(kind: .credits, start: 7_816.39, end: 7_852.39),
            .init(kind: .credits, start: 7_962.39, end: 8_032.39),
            .init(kind: .credits, start: 8_072.39, end: 8_110.39)
        ]
        let intro = MediaSegment(kind: .intro, start: duration * 0.1, end: duration * 0.15)
        let ranges = SkipMarkerTrackLayout.ranges(segments: credits, duration: duration)
        let combined = SkipMarkerTrackLayout.ranges(segments: [intro] + credits, duration: duration)
        for width in [CGFloat(960), 1280, 1760] {
            for height in [CGFloat(12), 14, 16, 18, 20] {
                let size = CGSize(width: width, height: height)
                XCTAssertEqual(
                    SkipMarkerTrackLayout.segmentedSections(
                        ranges: ranges, size: size, minimumSectionWidth: minimumSectionWidth, restingHeight: 12
                    ),
                    [CGRect(origin: .zero, size: size)]
                )
                XCTAssertEqual(sections(combined, size: size), sections([0.1..<0.15], size: size),
                               "Only the crowded tail should lose its cuts.")
            }
        }
        XCTAssertEqual(credits.activeSkippable(at: 7_770)?.start, 7_754.39)
        XCTAssertNil(credits.activeSkippable(at: 7_800),
                     "A visually continuous tail must not turn its unmarked gap into a skip range.")
    }

    func testEmptyFullLengthAndInvalidSizesAreSafe() {
        let size = CGSize(width: 320, height: 8)
        let unbrokenRanges: [[Range<Double>]] = [[], [0..<1]]
        for ranges in unbrokenRanges {
            XCTAssertEqual(sections(ranges, size: size), [CGRect(origin: .zero, size: size)])
        }
        for invalid in [
            CGSize.zero, CGSize(width: -1, height: 8), CGSize(width: CGFloat.infinity, height: 8),
            CGSize(width: 320, height: 0), CGSize(width: 320, height: CGFloat.nan)
        ] {
            XCTAssertTrue(sections([0.2..<0.8], size: invalid).isEmpty)
        }
    }

    private func sections(_ ranges: [Range<Double>], size: CGSize) -> [CGRect] {
        SkipMarkerTrackLayout.segmentedSections(
            ranges: ranges, size: size, minimumSectionWidth: minimumSectionWidth
        )
    }
}
