import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class DiscMenuTouchTests: XCTestCase {
    func testPendingMenuRequestKeepsTransportHiddenAcrossStartupSceneGaps() {
        let state = DiscMenuPlaybackState()
        state.isActive = true
        state.isOpening = false
        XCTAssertTrue(state.presentsMenu)
        state.isMenuVisible = true
        state.isMenuRequestPending = false
        XCTAssertTrue(state.presentsMenu)
        state.isMenuVisible = false
        XCTAssertFalse(state.presentsMenu)
        state.isMenuRequestPending = true
        XCTAssertTrue(state.presentsMenu)
        state.reset()
        XCTAssertTrue(state.isMenuRequestPending)
    }

    func testLandscapeAndPortraitTapsUsePixelsAndIgnoreLetterboxing() {
        let state = menu()
        var points: [CGPoint] = []
        state.sendPointerClick = { points.append(CGPoint(x: Int($0), y: Int($1))) }
        let landscape = CGRect(x: 0, y: 0, width: 1024, height: 768)
        state.activate(at: CGPoint(x: 512, y: 384), in: landscape)
        state.activate(at: CGPoint(x: 512, y: 30), in: landscape)
        XCTAssertEqual(points, [CGPoint(x: 960, y: 540)])
        let portrait = CGRect(x: 0, y: 0, width: 768, height: 1024)
        state.activate(at: CGPoint(x: 192, y: 404), in: portrait)
        state.activate(at: CGPoint(x: 192, y: 1000), in: portrait)
        XCTAssertEqual(points.last, CGPoint(x: 480, y: 270))
        XCTAssertEqual(points.count, 2)
    }

    func testPillarboxingAndOffsetViewportMapWithoutClampingOutsideTaps() {
        let state = menu()
        var points: [CGPoint] = []
        state.sendPointerClick = { points.append(CGPoint(x: Int($0), y: Int($1))) }
        let bounds = CGRect(x: 20, y: 40, width: 2400, height: 1080)
        state.activate(at: CGPoint(x: 260, y: 40), in: bounds)
        state.activate(at: CGPoint(x: 2179, y: 1119), in: bounds)
        state.activate(at: CGPoint(x: 259, y: 40), in: bounds)
        state.activate(at: CGPoint(x: 2180, y: 1120), in: bounds)
        XCTAssertEqual(points, [.zero, CGPoint(x: 1919, y: 1079)])
    }

    func testUnavailableAndRetiredMenusCannotReceivePointerClicks() {
        let state = menu()
        var count = 0
        state.sendPointerClick = { _, _ in count += 1 }
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        state.isMenuVisible = false
        state.activate(at: CGPoint(x: 100, y: 100), in: bounds)
        state.isMenuVisible = true
        state.failure = "Fixture failure"
        state.activate(at: CGPoint(x: 100, y: 100), in: bounds)
        state.failure = nil
        state.activate(at: CGPoint(x: CGFloat.nan, y: 100), in: bounds)
        state.activate(at: .zero, in: .zero)
        state.reset()
        state.sendPointerClick(100, 100)
        XCTAssertEqual(count, 0)
    }

    private func menu() -> DiscMenuPlaybackState {
        let state = DiscMenuPlaybackState()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        state.image = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 540), format: format).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        }
        state.isActive = true
        state.isMenuVisible = true
        return state
    }
}
