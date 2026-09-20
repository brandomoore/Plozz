#if canImport(SwiftUI)
import SwiftUI
import XCTest
@testable import CoreUI

@MainActor
final class PlozzStartupLogoTests: XCTestCase {
    private var timeline: KeyframeTimeline<PlozzStartupLogoMotion.Pose> {
        KeyframeTimeline(initialValue: .rest) {
            PlozzStartupLogoMotion.keyframes
        }
    }

    func testLoopReturnsToTheSameFaceAndOrientation() {
        XCTAssertEqual(timeline.duration, 8, accuracy: 0.0001)
        let start = timeline.value(time: 0)
        let end = timeline.value(time: timeline.duration)
        XCTAssertEqual(start, .rest)
        XCTAssertEqual(end.wink, start.wink)
        XCTAssertEqual(end.delight, start.delight)
        XCTAssertEqual(end.tilt, start.tilt)
        XCTAssertEqual(end.turn.truncatingRemainder(dividingBy: 360), start.turn)
    }

    func testExpressionsHaveQuietHoldsBeforeAndAfterTheTurn() {
        XCTAssertEqual(timeline.value(time: 0.5), .rest)
        XCTAssertEqual(timeline.value(time: 1.3).wink, 1)
        XCTAssertEqual(timeline.value(time: 2.5).delight, 1)
        XCTAssertEqual(timeline.value(time: 2.5).turn, 0)
        XCTAssertEqual(timeline.value(time: 5).delight, 1)
        XCTAssertEqual(timeline.value(time: 5).turn, 360)
        XCTAssertEqual(timeline.value(time: 7).delight, 0)
    }

    func testMotionStaysBoundedWithoutOpacityOvershoot() {
        for tick in 0...480 {
            let pose = timeline.value(time: Double(tick) / 60)
            XCTAssertTrue((0...1).contains(pose.wink))
            XCTAssertTrue((0...1).contains(pose.delight))
            XCTAssertTrue((-6.0001...0.0001).contains(pose.tilt))
            XCTAssertTrue((-12.0001...360.0001).contains(pose.turn))
        }
    }

    func testReduceMotionAndInactiveScenesDoNotAnimate() {
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertFalse(PlozzStartupLogoMotion.shouldAnimate(reduceMotion: true, scenePhase: phase))
        }
        XCTAssertFalse(PlozzStartupLogoMotion.shouldAnimate(reduceMotion: false, scenePhase: .inactive))
        XCTAssertFalse(PlozzStartupLogoMotion.shouldAnimate(reduceMotion: false, scenePhase: .background))
        XCTAssertTrue(PlozzStartupLogoMotion.shouldAnimate(reduceMotion: false, scenePhase: .active))
    }

    #if canImport(UIKit)
    func testOriginalFacesRenderAtPixelAlignedSizes() throws {
        var previousImage: Data?
        for (name, pose) in [
            ("smile", PlozzStartupLogoMotion.Pose.rest),
            ("wink", .init(wink: 1)),
            ("delight", .init(delight: 1))
        ] {
            let renderer = ImageRenderer(
                content: PlozzStartupLogoArtwork(pose: pose)
                    .frame(width: 192, height: 192)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage, name)
            XCTAssertEqual(image.size.width, 192)
            XCTAssertEqual(image.size.height, 192)
            let data = try XCTUnwrap(image.pngData())
            XCTAssertNotEqual(data, previousImage, "Each expression must render different artwork")
            previousImage = data
            let attachment = XCTAttachment(image: image)
            attachment.name = "Startup logo — \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    #endif
}
#endif
