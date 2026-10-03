import CoreGraphics
import CoreModels
import XCTest
@testable import EnginePlozzigen

final class ASSSubtitleRegionLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)
    private let top = CGRect(x: 300, y: 50, width: 1300, height: 90)
    private let bottom = CGRect(x: 250, y: 920, width: 1400, height: 90)

    func testSeparatedEdgeArtworkKeepsEveryLayerAndItsOriginalOrder() {
        var layout = ASSSubtitleRegionLayout()
        let regions = layout.regions(for: [
            top, bottom, top.insetBy(dx: 5, dy: 5), bottom.insetBy(dx: 8, dy: 8)
        ], canvas: canvas)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions.first?.indices, [0, 2])
        XCTAssertEqual(regions.last?.indices, [1, 3])
        XCTAssertEqual(regions.first?.avoidance, .fixed)
        guard let avoidance = regions.last?.avoidance,
              case let .lowerRegion(envelope, minimumY) = avoidance else {
            return XCTFail("Only the lower region should be movable")
        }
        XCTAssertLessThan(envelope.minY, bottom.minY / canvas.height)
        XCTAssertGreaterThan(minimumY, top.maxY / canvas.height)
        XCTAssertLessThan(minimumY, envelope.minY)
    }

    func testCentralAndCrossingEffectsKeepTheWholeCompositionFixed() {
        for effect in [
            CGRect(x: 400, y: 450, width: 200, height: 180),
            CGRect(x: 0, y: 80, width: 1920, height: 910),
            CGRect(x: 0, y: 0, width: 1920, height: 1080)
        ] {
            var layout = ASSSubtitleRegionLayout()
            let regions = layout.regions(for: [top, bottom, effect], canvas: canvas)
            XCTAssertEqual(regions.count, 1)
            XCTAssertEqual(regions.first?.indices, [0, 1, 2])
            XCTAssertEqual(regions.first?.avoidance, .fixed)
        }
    }

    func testSmallAnimatedBoundsChangesKeepTheSameClearanceEnvelope() {
        var layout = ASSSubtitleRegionLayout()
        let initial = layout.regions(for: [top, bottom], canvas: canvas)
        for delta in [CGFloat(-10), 5, -5, 10, 0] {
            let frame = layout.regions(for: [top, bottom.offsetBy(dx: 0, dy: delta)], canvas: canvas)
            XCTAssertEqual(frame.last?.avoidance, initial.last?.avoidance)
            XCTAssertEqual(frame.first?.avoidance, .fixed)
        }
    }

    func testClassificationHasHysteresisButNeverSplitsACenterCrossingLayer() {
        var layout = ASSSubtitleRegionLayout()
        let nearEdge = CGRect(x: 250, y: 660, width: 1400, height: 90)
        XCTAssertEqual(layout.regions(for: [top, nearEdge], canvas: canvas).count, 2)
        XCTAssertEqual(layout.regions(for: [top, nearEdge.offsetBy(dx: 0, dy: -25)], canvas: canvas).count, 2)
        let crossing = CGRect(x: 400, y: 490, width: 400, height: 100)
        XCTAssertEqual(layout.regions(for: [top, crossing], canvas: canvas).first?.avoidance, .fixed)
    }

    func testBlankFrameResetsProtectedRegionsAndSingleBottomCaptionRemainsMovable() {
        var layout = ASSSubtitleRegionLayout()
        _ = layout.regions(for: [top, bottom], canvas: canvas)
        XCTAssertTrue(layout.regions(for: [], canvas: canvas).isEmpty)
        let single = layout.regions(for: [bottom], canvas: canvas)
        guard let avoidance = single.first?.avoidance,
              case let .lowerRegion(_, minimumY) = avoidance else {
            return XCTFail("A lower caption should still avoid controls")
        }
        XCTAssertEqual(minimumY, 0)
        XCTAssertEqual(layout.regions(for: [top], canvas: canvas).first?.avoidance, .fixed)
    }
}
