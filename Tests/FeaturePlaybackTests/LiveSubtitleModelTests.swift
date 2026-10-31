import CoreGraphics
import CoreModels
import Observation
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveSubtitleModelTests: XCTestCase {
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
