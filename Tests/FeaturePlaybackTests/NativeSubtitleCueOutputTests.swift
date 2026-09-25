import AVFoundation
import CoreMedia
import CoreModels
import XCTest
@testable import FeaturePlayback

final class NativeSubtitleTimelineTests: XCTestCase {
    func testEarlyCallbacksDoNotShowFutureCuesOrEraseTheCurrentLine() {
        var timeline = NativeSubtitleTimeline()
        _ = timeline.receive([.init("First")], at: 1, playhead: 0)
        _ = timeline.receive([], at: 3, playhead: 0)
        let cues = timeline.receive([.init("Next")], at: 6, playhead: 0)
        XCTAssertTrue(cues.active(at: 0.99).isEmpty)
        XCTAssertEqual(cues.active(at: 1).compactMap(\.text), ["First"])
        XCTAssertEqual(cues.active(at: 2.99).compactMap(\.text), ["First"])
        XCTAssertTrue(cues.active(at: 3).isEmpty)
        XCTAssertTrue(cues.active(at: 5.99).isEmpty)
        XCTAssertEqual(cues.active(at: 6).compactMap(\.text), ["Next"])
    }

    func testOverlappingPresentationStatesClearEachLineAtItsOwnBoundary() {
        var timeline = NativeSubtitleTimeline()
        _ = timeline.receive([.init("Alpha")], at: 1, playhead: 0)
        _ = timeline.receive([.init("Alpha"), .init("Bravo")], at: 2, playhead: 0)
        _ = timeline.receive([.init("Bravo")], at: 3, playhead: 0)
        let cues = timeline.receive([], at: 4, playhead: 0)
        XCTAssertEqual(cues.active(at: 1.5).compactMap(\.text), ["Alpha"])
        XCTAssertEqual(cues.active(at: 2.5).compactMap(\.text), ["Alpha", "Bravo"])
        XCTAssertEqual(cues.active(at: 3.5).compactMap(\.text), ["Bravo"])
        XCTAssertTrue(cues.active(at: 4).isEmpty)
    }

    func testDelayAppliesEquallyToStartAndClearEvents() {
        var timeline = NativeSubtitleTimeline()
        _ = timeline.receive([.init("Line")], at: 20, playhead: 10)
        let cues = timeline.receive([], at: 22, playhead: 10)
        for offset in [-10.0, -0.5, 0, 0.5, 10] {
            XCTAssertTrue(cues.active(at: 19.99 + offset, offset: offset).isEmpty)
            XCTAssertEqual(cues.active(at: 20 + offset, offset: offset).compactMap(\.text), ["Line"])
            XCTAssertEqual(cues.active(at: 21.99 + offset, offset: offset).compactMap(\.text), ["Line"])
            XCTAssertTrue(cues.active(at: 22 + offset, offset: offset).isEmpty)
        }
    }

    func testPausedSeekCanReconstructAStateThatBeganBeforeTheLanding() {
        var timeline = NativeSubtitleTimeline()
        let old = timeline.receive([.init("Old")], at: 1, playhead: 0)
        timeline.reset()
        let new = timeline.receive([.init("Held")], at: 6, playhead: 6.5)
        XCTAssertEqual(new.active(at: 6.5).compactMap(\.text), ["Held"])
        XCTAssertNotEqual(old.first?.id, new.first?.id)
        let closed = timeline.receive([], at: 7, playhead: 6.5)
        XCTAssertEqual(closed.active(at: 6.5).compactMap(\.text), ["Held"])
        XCTAssertTrue(closed.active(at: 7).isEmpty)
    }

    func testRepeatedTextAndReplacementAtTheSameTimestampHaveDistinctIdentity() {
        var timeline = NativeSubtitleTimeline()
        _ = timeline.receive([.init("Repeated")], at: 1, playhead: 0)
        _ = timeline.receive([], at: 2, playhead: 0)
        var cues = timeline.receive([.init("Repeated")], at: 3, playhead: 0)
        XCTAssertNotEqual(cues.active(at: 1).first?.id, cues.active(at: 3).first?.id)
        cues = timeline.receive([.init("Corrected")], at: 3, playhead: 0)
        XCTAssertEqual(cues.active(at: 3).compactMap(\.text), ["Corrected"])
        XCTAssertEqual(timeline.events.count, 3)
    }

    func testOutOfOrderEventsAndLongCuesRetainTheSupportedDelayWindow() {
        var timeline = NativeSubtitleTimeline()
        _ = timeline.receive([.init("Long")], at: 1, playhead: 0)
        _ = timeline.receive([.init("Later")], at: 100, playhead: 90)
        let cues = timeline.receive([], at: 95, playhead: 90)
        XCTAssertEqual(cues.active(at: 99, offset: 10).compactMap(\.text), ["Long"])
        XCTAssertTrue(cues.active(at: 96).isEmpty)
        XCTAssertEqual(cues.active(at: 101).compactMap(\.text), ["Later"])
        for time in 101...200 { _ = timeline.receive([], at: Double(time), playhead: Double(time)) }
        XCTAssertLessThanOrEqual(timeline.events.count, 17)
    }

    func testInvalidTimesCannotReplaceAValidState() {
        var timeline = NativeSubtitleTimeline()
        let original = timeline.receive([.init("Valid")], at: 1, playhead: 0)
        XCTAssertEqual(timeline.receive([], at: .nan, playhead: 0), original)
        XCTAssertEqual(timeline.receive([], at: 2, playhead: .infinity), original)
    }
}

@MainActor
final class NativeSubtitleCueOutputTests: XCTestCase {
    func testPresentationEventsDoNotAdvertiseUnprovenSeekSafeManualTimingOffsets() {
        let model = LiveSubtitleModel()
        model.offset = 5
        model.beginLiveFeed(permitsTimingOffsets: false)
        model.updateLiveCues([.init(id: 1, start: 1, end: 3, body: .text(.init("On time")))])
        model.tick(1.5)
        XCTAssertTrue(model.rendersPrimary)
        XCTAssertFalse(model.supportsPrimaryTimingOffset)
        XCTAssertEqual(model.primary.compactMap(\.text), ["On time"])
        XCTAssertEqual(model.offset, 5, "The saved sidecar offset is not erased by a different delivery path")
        model.loadPrimary(SubtitleCueParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nSidecar\n", id: 2))
        XCTAssertTrue(model.supportsPrimaryTimingOffset)
        model.tick(1.5)
        XCTAssertTrue(model.primary.isEmpty)
        model.tick(6.5)
        XCTAssertEqual(model.primary.compactMap(\.text), ["Sidecar"])
        let engine = NativeVideoEngine()
        var track = MediaTrack(id: 1, kind: .subtitle, displayTitle: "Embedded")
        XCTAssertFalse(engine.supportsSubtitleTimingAdjustments(for: track))
        track.deliverySource = .localFile(URL(fileURLWithPath: "/fixture/subtitles.vtt"))
        XCTAssertTrue(engine.supportsSubtitleTimingAdjustments(for: track))
    }

    func testNativeDefaultPlacementDoesNotOverrideTheScreenRelativeUserPosition() {
        let text = NSAttributedString(string: "Dialogue", attributes: [
            .init(kCMTextMarkupAttribute_Alignment as String): kCMTextMarkupAlignmentType_Middle,
            .init(kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection as String): 50,
            .init(kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String): 100,
            .init(kCMTextMarkupAttribute_ForegroundColorARGB as String): [1, 1, 1, 1]
        ])
        let decoded = NativeSubtitleText.decode(text)
        XCTAssertEqual(decoded.string, "Dialogue")
        XCTAssertNil(decoded.layout)
        XCTAssertNil(decoded.runs, "Default tx3g white must not override the user's text color")
    }

    func testAuthoredPositionEmphasisAndMixedColorsSurviveDecoding() throws {
        let text = NSMutableAttributedString(string: "Red white")
        text.addAttributes([
            .init(kCMTextMarkupAttribute_BoldStyle as String): true,
            .init(kCMTextMarkupAttribute_ItalicStyle as String): true,
            .init(kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection as String): 40,
            .init(kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String): 10,
            .init(kCMTextMarkupAttribute_ForegroundColorARGB as String): [1, 1, 0, 0]
        ], range: NSRange(location: 0, length: 4))
        text.addAttribute(.init(kCMTextMarkupAttribute_ForegroundColorARGB as String),
                          value: [1, 1, 1, 1], range: NSRange(location: 4, length: 5))
        let decoded = NativeSubtitleText.decode(text)
        XCTAssertEqual(decoded.string, "Red white")
        XCTAssertTrue(decoded.isBold)
        XCTAssertTrue(decoded.isItalic)
        XCTAssertEqual(decoded.layout?.anchor, CGPoint(x: 0.4, y: 0.1))
        let runs = try XCTUnwrap(decoded.runs)
        XCTAssertEqual(runs.map(\.text), ["Red ", "white"])
        XCTAssertEqual(runs.first?.color, SubtitleColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(runs.last?.color, .white)
    }

    func testOldTrackAndDetachedOutputsCannotPublishOrClearNewCues() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-caption-fixture.mp4"))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        var delivered: [SubtitleCue] = []
        let bridge = NativeSubtitleCueOutput(player: player, item: item, style: .default) { delivered = $0 }
        defer { bridge.detach(); player.pause() }
        bridge.select(enabled: true)
        let old = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first)
        bridge.select(enabled: true)
        let current = try XCTUnwrap(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first)
        XCTAssertTrue(current.suppressesPlayerRendering)
        XCTAssertEqual(item.outputs.count, 1)
        bridge.legibleOutput(current, didOutputAttributedStrings: [.init(string: "New")],
                             nativeSampleBuffers: [], forItemTime: CMTime(seconds: 0, preferredTimescale: 600))
        XCTAssertEqual(delivered.compactMap(\.text), ["New"])
        bridge.legibleOutput(old, didOutputAttributedStrings: [.init(string: "Stale")],
                             nativeSampleBuffers: [], forItemTime: .zero)
        bridge.outputSequenceWasFlushed(old)
        XCTAssertEqual(delivered.compactMap(\.text), ["New"])
        bridge.outputSequenceWasFlushed(current)
        XCTAssertTrue(delivered.isEmpty)
        bridge.detach()
        bridge.legibleOutput(current, didOutputAttributedStrings: [.init(string: "After stop")],
                             nativeSampleBuffers: [], forItemTime: .zero)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(item.outputs.isEmpty)
    }
}
