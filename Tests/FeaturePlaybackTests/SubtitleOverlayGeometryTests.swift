import CoreGraphics
import CoreModels
import XCTest
@testable import FeaturePlayback

final class SubtitleOverlayGeometryTests: XCTestCase {
    func testOnlyTheLowerAuthoredRegionMovesAndRestoresAcrossScreenShapes() throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        for bounds in [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 844, height: 390),
            CGRect(x: 0, y: 0, width: 390, height: 844)
        ] {
            let video = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(in: bounds, aspectRatio: 16.0 / 9))
            let top = SubtitleImage(
                cgImage: bitmap, normalizedRect: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.12),
                canvasSize: CGSize(width: 1920, height: 1080), controlAvoidance: .fixed
            )
            var lower = SubtitleImage(
                cgImage: bitmap, normalizedRect: CGRect(x: 0.1, y: 0.85, width: 0.8, height: 0.1),
                canvasSize: CGSize(width: 1920, height: 1080),
                controlAvoidance: .lowerRegion(
                    envelope: CGRect(x: 0.1, y: 0.83, width: 0.8, height: 0.14), minimumY: 0.21
                )
            )
            let controls = [CGRect(
                x: bounds.minX, y: video.minY + video.height * 0.8,
                width: bounds.width, height: bounds.maxY - (video.minY + video.height * 0.8)
            )]
            let lift = SubtitleOverlayGeometry.bitmapOffset(for: lower, videoRect: video, controls: controls, bounds: bounds)
            XCTAssertLessThan(lift, 0, "bounds=\(bounds) video=\(video)")
            XCTAssertEqual(SubtitleOverlayGeometry.bitmapOffset(for: top, videoRect: video, controls: controls, bounds: bounds), 0)
            XCTAssertEqual(SubtitleOverlayGeometry.bitmapOffset(for: lower, videoRect: video, controls: [], bounds: bounds), 0)
            lower.normalizedRect = lower.normalizedRect.offsetBy(dx: 0, dy: 0.01)
            XCTAssertEqual(SubtitleOverlayGeometry.bitmapOffset(for: lower, videoRect: video, controls: controls, bounds: bounds), lift,
                           "Animated ink must not make the control-clearance offset bounce")
            let raised = SubtitleOverlayGeometry.bitmapRect(
                normalizedRect: lower.normalizedRect, canvasSize: lower.canvasSize, videoRect: video
            ).offsetBy(dx: 0, dy: lift)
            XCTAssertFalse(raised.intersects(controls[0]))
            XCTAssertTrue(bounds.contains(raised))
        }
    }

    func testAuthoredArtworkStaysPutWhenTheOnlyAvailableMoveWouldOverlapTheTop() throws {
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var image = SubtitleImage(
            cgImage: bitmap, normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.15),
            controlAvoidance: .lowerRegion(envelope: CGRect(x: 0.1, y: 0.78, width: 0.8, height: 0.19), minimumY: 0.4)
        )
        let controls = [CGRect(x: 0, y: 450, width: 1920, height: 630)]
        XCTAssertEqual(SubtitleOverlayGeometry.bitmapOffset(for: image, videoRect: bounds, controls: controls, bounds: bounds), 0)
        image.controlAvoidance = .fixed
        XCTAssertEqual(SubtitleOverlayGeometry.bitmapOffset(for: image, videoRect: bounds, controls: controls, bounds: bounds), 0)
        image.controlAvoidance = .automatic
        XCTAssertEqual(
            SubtitleOverlayGeometry.bitmapOffset(for: image, videoRect: bounds, controls: controls, bounds: bounds),
            SubtitleOverlayGeometry.upwardOffset(
                for: SubtitleOverlayGeometry.bitmapRect(normalizedRect: image.normalizedRect, canvasSize: .zero, videoRect: bounds),
                avoiding: controls, in: bounds
            ), "Existing PGS/DVD bitmap behavior is unchanged"
        )
    }

    func testInfoPillAtTheLeftDoesNotRaiseCenteredTextAboveTheCardClearance() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let caption = CGRect(x: 800, y: 950, width: 320, height: 70)
        let card = CGRect(x: 60, y: 720, width: 1800, height: 320)
        let info = CGRect(x: 60, y: 620, width: 140, height: 60)
        for rectangles in [[info, card], [card, info]] {
            let lift = SubtitleOverlayGeometry.upwardOffset(
                for: caption, avoiding: rectangles, in: bounds, clearance: 24
            )
            XCTAssertEqual(caption.maxY + lift, card.minY - 24)
        }
    }

    func testMovingAboveOneControlAlsoChecksControlsAtTheNewPosition() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let caption = CGRect(x: 800, y: 950, width: 320, height: 70)
        let lower = CGRect(x: 60, y: 900, width: 1800, height: 180)
        let higher = CGRect(x: 700, y: 800, width: 500, height: 80)
        for rectangles in [[higher, lower], [lower, higher]] {
            let lift = SubtitleOverlayGeometry.upwardOffset(
                for: caption, avoiding: rectangles, in: bounds, clearance: 24
            )
            XCTAssertEqual(caption.maxY + lift, higher.minY - 24)
        }
    }

    @MainActor
    func testRemovingAnOldRegionOwnerCannotClearItsReplacement() {
        let layout = SubtitleControlsLayout()
        let old = UUID(), current = UUID()
        layout.setFrame(CGRect(x: 0, y: 700, width: 1000, height: 300), for: .card, owner: old)
        let replacement = CGRect(x: 0, y: 750, width: 1000, height: 250)
        layout.setFrame(replacement, for: .card, owner: current)
        layout.setFrame(nil, for: .card, owner: old)
        XCTAssertEqual(layout.frames, [replacement])
        XCTAssertEqual(layout.frame(for: .card), replacement)
        layout.setFrame(nil, for: .card, owner: current)
        XCTAssertTrue(layout.frames.isEmpty)
    }

    func testOnlyAnOverlappingSubtitleMovesAboveTheVisibleControls() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controls = CGRect(x: 60, y: 840, width: 1800, height: 240)
        let subtitle = CGRect(x: 600, y: 940, width: 720, height: 80)
        XCTAssertEqual(SubtitleOverlayGeometry.upwardOffset(
            for: subtitle, avoiding: controls, in: bounds, clearance: 24
        ), -204)
        XCTAssertEqual(SubtitleOverlayGeometry.upwardOffset(
            for: subtitle, avoiding: nil, in: bounds, clearance: 24
        ), 0)
        XCTAssertEqual(SubtitleOverlayGeometry.upwardOffset(
            for: subtitle.offsetBy(dx: 0, dy: -300), avoiding: controls, in: bounds
        ), 0)
        XCTAssertEqual(SubtitleOverlayGeometry.upwardOffset(
            for: CGRect(x: 0, y: 940, width: 40, height: 80), avoiding: controls, in: bounds
        ), 0)
    }

    func testOffscreenHiddenCardAndInvalidGeometryDoNotLiftCaptions() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let subtitle = CGRect(x: 200, y: 300, width: 400, height: 60)
        for controls in [CGRect(x: 0, y: 390, width: 844, height: 200), .null, .zero,
                         CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)] {
            XCTAssertEqual(SubtitleOverlayGeometry.upwardOffset(
                for: subtitle, avoiding: controls, in: bounds
            ), 0)
        }
    }

    func testOversizedCaptionsRemainInsideTheTopEdgeWhenThereIsTooLittleRoom() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let subtitle = CGRect(x: 40, y: 120, width: 760, height: 260)
        let lift = SubtitleOverlayGeometry.upwardOffset(
            for: subtitle, avoiding: CGRect(x: 20, y: 220, width: 800, height: 170),
            in: bounds, clearance: 12
        )
        XCTAssertEqual(lift, -120)
        XCTAssertEqual(subtitle.minY + lift, 0)
    }

    func testLetterboxedBitmapUsesDisplaySpaceForControlIntersection() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let video = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(in: bounds, aspectRatio: 2.4))
        let subtitle = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0.2, y: 0.9, width: 0.6, height: 0.06),
            canvasSize: .zero, videoRect: video
        )
        let controls = CGRect(x: 60, y: 840, width: 1800, height: 240)
        let lift = SubtitleOverlayGeometry.upwardOffset(for: subtitle, avoiding: controls, in: bounds, clearance: 24)
        XCTAssertEqual(subtitle.maxY + lift, controls.minY - 24, accuracy: 0.001)
    }

    func testAnchoredCuePinsTheCornerItsAlignmentNames() {
        let video = CGRect(x: 0, y: 100, width: 1000, height: 500)
        let text = CGSize(width: 200, height: 40)
        func origin(_ alignment: SubtitleAlignment) -> CGPoint {
            SubtitleOverlayGeometry.anchoredOrigin(
                anchor: CGPoint(x: 0.73, y: 0.1), alignment: alignment,
                contentSize: text, videoRect: video, limits: video
            )
        }
        XCTAssertEqual(origin(.topLeft), CGPoint(x: 730, y: 150))
        XCTAssertEqual(origin(.topCenter), CGPoint(x: 630, y: 150))
        XCTAssertEqual(origin(.topRight), CGPoint(x: 530, y: 150))
        XCTAssertEqual(origin(.bottomCenter), CGPoint(x: 630, y: 110))
    }

    func testAnchoredCueStaysInsideTheLimits() {
        let video = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let limits = video.insetBy(dx: 50, dy: 25)
        let origin = SubtitleOverlayGeometry.anchoredOrigin(
            anchor: CGPoint(x: 0.95, y: 0.95), alignment: .topLeft,
            contentSize: CGSize(width: 200, height: 80), videoRect: video, limits: limits
        )
        XCTAssertEqual(origin, CGPoint(x: 750, y: 395))
    }

    func testLeftPinnedRollUpRowsWrapBeforeTheSafeEdgeSoTheLeftEdgeNeverMoves() {
        let video = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let limits = video.insetBy(dx: 50, dy: 25)
        let anchor = CGPoint(x: 0.1, y: 0.1)
        let wrap = SubtitleOverlayGeometry.anchoredWrapWidth(
            anchor: anchor, alignment: .topLeft, preferred: 900,
            videoRect: video, limits: limits, minimum: 250
        )
        XCTAssertEqual(wrap, 850)
        // A short first row and the longest row the wrap allows start at the same x.
        for width in [CGFloat(200), wrap] {
            let origin = SubtitleOverlayGeometry.anchoredOrigin(
                anchor: anchor, alignment: .topLeft,
                contentSize: CGSize(width: width, height: 80), videoRect: video, limits: limits
            )
            XCTAssertEqual(origin.x, 100)
        }
    }

    func testCentredCueWrapsToTwiceItsRoomAndRightPinnedToItsLeftRoom() {
        let video = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let limits = video.insetBy(dx: 50, dy: 25)
        func wrap(_ x: CGFloat, _ alignment: SubtitleAlignment) -> CGFloat {
            SubtitleOverlayGeometry.anchoredWrapWidth(
                anchor: CGPoint(x: x, y: 0.1), alignment: alignment, preferred: 920,
                videoRect: video, limits: limits, minimum: 250
            )
        }
        XCTAssertEqual(wrap(0.73, .topCenter), 440)
        XCTAssertEqual(wrap(0.73, .topRight), 680)
        // Too close to the edge for readable text: keep the minimum and clamp instead.
        XCTAssertEqual(wrap(0.97, .topLeft), 250)
    }

    func testAspectFitVideoRectUsesFullPortraitWidth() throws {
        let rect = try XCTUnwrap(
            SubtitleOverlayGeometry.aspectFitRect(
                in: CGRect(x: 0, y: 0, width: 390, height: 844),
                aspectRatio: 16.0 / 9.0
            )
        )

        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 390, accuracy: 0.001)
        XCTAssertEqual(rect.height, 219.375, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 422, accuracy: 0.001)
    }

    func testBitmapCueMapsAgainstLetterboxedVideoRect() throws {
        let videoRect = try XCTUnwrap(
            SubtitleOverlayGeometry.aspectFitRect(
                in: CGRect(x: 0, y: 0, width: 390, height: 844),
                aspectRatio: 16.0 / 9.0
            )
        )
        let rect = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1),
            canvasSize: .zero,
            videoRect: videoRect
        )

        XCTAssertEqual(rect.minX, 39, accuracy: 0.001)
        XCTAssertEqual(rect.width, 312, accuracy: 0.001)
        XCTAssertEqual(rect.height, 21.9375, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, videoRect.minY + videoRect.height * 0.9, accuracy: 0.001)
    }

    func testSubtitleCanvasStaysWidthAlignedAndCenterAnchored() {
        let videoRect = CGRect(x: 0, y: 100, width: 400, height: 160)
        let rect = SubtitleOverlayGeometry.bitmapRect(
            normalizedRect: CGRect(x: 0, y: 0.8, width: 1, height: 0.1),
            canvasSize: CGSize(width: 1920, height: 1080),
            videoRect: videoRect
        )

        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 247.5, accuracy: 0.001)
        XCTAssertEqual(rect.height, 22.5, accuracy: 0.001)
    }
}
