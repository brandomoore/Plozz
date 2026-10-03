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
            XCTAssertEqual(mask.red(x: 43, y: top), 0, "Each new section has a rounded corner.")
            XCTAssertEqual(mask.red(x: 43, y: 22), 255, "The rounded cap still reaches the middle of the bar.")
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
