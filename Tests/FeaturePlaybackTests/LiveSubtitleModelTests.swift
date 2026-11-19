import AVFoundation
import CoreGraphics
import CoreModels
import Observation
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveSubtitleModelTests: XCTestCase {
    func testScheduledArtworkUsesItemIntervalsAndRelayoutsAlreadyQueuedRegions() throws {
        let view = ScheduledASSArtworkView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        var style = SubtitleStyle.default
        style.opacity = 0.6
        style.avoidsPlayerControls = true
        let video = CGRect(x: 0, y: 75, width: 800, height: 450)
        var layout = SubtitleOverlayGeometry.BitmapLayout(
            style: style, videoRect: video, activePictureRect: nil, sourceAspectRatio: nil, controls: []
        )
        view.bitmapLayout = layout
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let sign = SubtitleImage(cgImage: bitmap, normalizedRect: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.25),
                                 controlAvoidance: .fixed)
        let line = SubtitleImage(cgImage: bitmap, normalizedRect: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.25))
        let cues = [sign, line].enumerated().map { SubtitleCue(id: $0.offset, start: 0, end: 100, body: .image($0.element)) }
        let item = AVPlayerItem(asset: AVMutableComposition())
        view.display(cues, at: 7, item: item)
        view.display([], at: 7.25, item: item)

        let timeline = try XCTUnwrap(view.layer.sublayers?.first as? AVSynchronizedLayer)
        let regions = try XCTUnwrap(timeline.sublayers)
        let interval = try XCTUnwrap(regions.first?.animation(forKey: "contents") as? CAKeyframeAnimation)
        XCTAssertTrue(timeline.playerItem === item)
        XCTAssertEqual(interval.beginTime, 7)
        XCTAssertEqual(interval.calculationMode, .discrete)
        XCTAssertEqual(try XCTUnwrap(interval.keyTimes?[1]).doubleValue * interval.duration, 0.25, accuracy: 0.00001)
        let size = try XCTUnwrap(regions.first?.animation(forKey: "bounds") as? CAKeyframeAnimation)
        XCTAssertEqual((size.values?.last as? NSValue)?.cgRectValue, .zero, "Hold the clear after its deadline.")
        func firstRects() throws -> [CGRect] {
            try regions.map { region in
                let position = try XCTUnwrap((region.animation(forKey: "position") as? CAKeyframeAnimation)?.values?.first as? NSValue)
                let bounds = try XCTUnwrap((region.animation(forKey: "bounds") as? CAKeyframeAnimation)?.values?.first as? NSValue)
                return CGRect(origin: position.cgPointValue, size: bounds.cgRectValue.size)
            }
        }
        XCTAssertEqual(try firstRects(), layout.frames(for: [sign, line], in: view.bounds))
        let oldFrames = try firstRects()
        layout.controls = [CGRect(x: 0, y: 480, width: 800, height: 120)]
        view.bitmapLayout = layout
        view.layoutIfNeeded()
        XCTAssertEqual(try firstRects(), layout.frames(for: [sign, line], in: view.bounds))
        XCTAssertEqual(try firstRects().first, oldFrames.first)
        XCTAssertLessThan(try XCTUnwrap(firstRects().last).maxY, 480)
        XCTAssertEqual(view.alpha, 0.6, accuracy: 0.001)
        XCTAssertEqual(regions.first?.animation(forKey: "contents")?.beginTime, 7)
    }

    func testScheduledArtworkBoundsFutureChangesAndDiscardsOldItemAndReplacedTail() throws {
        let view = ScheduledASSArtworkView()
        let first = AVPlayerItem(asset: AVMutableComposition())
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let cues = [SubtitleCue(id: 1, start: 0, end: 200, body: .image(.init(cgImage: bitmap, normalizedRect: .zero)))]
        for n in 1...200 { view.display(cues, at: Double(n), item: first) }
        let old = try XCTUnwrap(view.layer.sublayers?.first as? AVSynchronizedLayer)
        let slot = try XCTUnwrap(old.sublayers?.first)
        let animation = try XCTUnwrap(slot.animation(forKey: "contents") as? CAKeyframeAnimation)
        XCTAssertLessThan(try XCTUnwrap(animation.keyTimes).count, 200)
        XCTAssertEqual(animation.beginTime, 1)
        view.display([], at: 1, item: first)
        XCTAssertEqual(old.sublayers?.count, 1)
        XCTAssertTrue(old.sublayers?.first === slot)

        let next = AVPlayerItem(asset: AVMutableComposition())
        view.display(cues, at: 0, item: next)
        let fresh = try XCTUnwrap(view.layer.sublayers?.first as? AVSynchronizedLayer)
        XCTAssertNil(old.superlayer)
        XCTAssertNil(old.playerItem)
        XCTAssertTrue(fresh.playerItem === next)
        XCTAssertEqual(fresh.sublayers?.last?.animation(forKey: "contents")?.beginTime, AVCoreAnimationBeginTimeAtZero)
        view.reset()
        XCTAssertNil(fresh.playerItem)
        XCTAssertTrue(view.layer.sublayers?.isEmpty ?? true)
    }

    func testOnlyPrimaryLiveFeedWithoutHDRDimmingPermitsScheduledArtwork() {
        let model = LiveSubtitleModel()
        model.beginSecondaryLiveFeed()
        XCTAssertFalse(model.permitsScheduledASSArtwork)
        model.beginLiveFeed()
        model.style.hdrLuminanceScale = 0.75
        XCTAssertTrue(model.permitsScheduledASSArtwork)
        model.isHDR = true
        XCTAssertFalse(model.permitsScheduledASSArtwork)
        model.style.hdrLuminanceScale = 1
        XCTAssertTrue(model.permitsScheduledASSArtwork)
        model.loadPrimary(nil)
        XCTAssertFalse(model.permitsScheduledASSArtwork)
    }

    func testLiveTextReplacementWithTheSameIDReachesBothLanesImmediately() {
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        model.beginSecondaryLiveFeed()
        model.tick(2)
        let empty = cue("")
        model.updateLiveCues([empty])
        model.updateSecondaryLiveCues([empty])

        let replacement = cue("The missing line")
        model.updateLiveCues([replacement])
        model.updateSecondaryLiveCues([replacement])
        XCTAssertEqual(model.primary.first?.text, "The missing line")
        XCTAssertEqual(model.secondary.first?.text, "The missing line")

        var restyled = replacement
        restyled.body = .text(.init("The missing line", isItalic: true, alignment: .topCenter))
        model.updateLiveCues([restyled])
        model.updateSecondaryLiveCues([restyled])
        for active in [model.primary, model.secondary] {
            guard case .text(let text) = active.first?.body else { return XCTFail("Expected text") }
            XCTAssertTrue(text.isItalic)
            XCTAssertEqual(text.alignment, .topCenter)
        }
    }

    func testLiveReplacementRetainsRevisedEndTimeAndClearsAtItsBoundary() {
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        model.beginSecondaryLiveFeed()
        model.tick(2)
        model.updateLiveCues([cue("A line")])
        model.updateSecondaryLiveCues([cue("A line")])
        var shorter = cue("A line")
        shorter.end = 2.5
        model.updateLiveCues([shorter])
        model.updateSecondaryLiveCues([shorter])
        XCTAssertEqual(model.primary.first?.end, 2.5)
        XCTAssertEqual(model.secondary.first?.end, 2.5)
        model.tick(2.5)
        XCTAssertTrue(model.primary.isEmpty)
        XCTAssertTrue(model.secondary.isEmpty)
    }

    func testUnchangedLiveCuesAndTicksDoNotRepublish() {
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        model.beginSecondaryLiveFeed()
        model.tick(2)
        let line = cue("A held line")
        model.updateLiveCues([line])
        model.updateSecondaryLiveCues([line])
        let changes = SubtitleObservationChanges()
        withObservationTracking {
            _ = model.primary
            _ = model.secondary
        } onChange: {
            changes.record()
        }
        for frame in 0..<60 {
            model.updateLiveCues([line])
            model.updateSecondaryLiveCues([line])
            model.tick(2 + Double(frame) / 60)
        }
        XCTAssertEqual(changes.count, 0)
        model.updateLiveCues([cue("A corrected line")])
        XCTAssertEqual(changes.count, 1)
    }

    func testLiveBitmapReplacementWithTheSameIDUpdatesWithoutPixelComparison() throws {
        func image() throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let first = try image()
        let second = try image()
        let original = SubtitleImage(cgImage: first, normalizedRect: .init(x: 0, y: 0, width: 1, height: 1))
        var moved = original
        moved.normalizedRect = .init(x: 0.1, y: 0.8, width: 0.8, height: 0.1)
        var resized = original
        resized.canvasSize = .init(width: 1920, height: 1080)
        var fixed = original
        fixed.controlAvoidance = .fixed
        var repainted = original
        repainted.cgImage = second
        var frame = cue("")
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        model.beginSecondaryLiveFeed()
        model.tick(2)
        for replacement in [moved, resized, fixed, repainted] {
            XCTAssertNotEqual(original, replacement)
            frame.body = .image(original)
            model.updateLiveCues([frame])
            model.updateSecondaryLiveCues([frame])
            frame.body = .image(replacement)
            model.updateLiveCues([frame])
            model.updateSecondaryLiveCues([frame])
            for active in [model.primary, model.secondary] {
                guard case .image(let image) = active.first?.body else { return XCTFail("Expected bitmap") }
                XCTAssertTrue(image.cgImage === replacement.cgImage)
                XCTAssertEqual(image.normalizedRect, replacement.normalizedRect)
                XCTAssertEqual(image.canvasSize, replacement.canvasSize)
                XCTAssertEqual(image.controlAvoidance, replacement.controlAvoidance)
            }
        }
    }

    func testSidecarAndClearedTracksRejectLateLiveReplacements() {
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        model.tick(2)
        model.updateLiveCues([cue("Old live line")])
        model.loadPrimary(.init(id: 1, metadata: .init(format: .srt), cues: [cue("Sidecar")]))
        model.tick(2)
        model.updateLiveCues([cue("Late replacement")])
        XCTAssertEqual(model.primary.first?.text, "Sidecar")
        model.clear()
        model.updateLiveCues([cue("Late replacement")])
        model.updateSecondaryLiveCues([cue("Late replacement")])
        model.tick(2)
        XCTAssertTrue(model.primary.isEmpty)
        XCTAssertTrue(model.secondary.isEmpty)
    }

    private func cue(_ text: String) -> SubtitleCue {
        .init(id: 1, start: 1, end: 4, body: .text(.init(text)))
    }
}

private final class SubtitleObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}
