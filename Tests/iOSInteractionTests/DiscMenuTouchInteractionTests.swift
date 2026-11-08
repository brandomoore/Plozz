import UIKit
import XCTest

@MainActor
final class DiscMenuTouchInteractionTests: XCTestCase {
    func testArtworkReceivesTapsWithoutToolbarDuplicatesInBothOrientations() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--disc-touch-fixture", "--disc-touch-loading"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.activityIndicators["disc-fixture-loading"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.count, 0, "Loading must not expose the disc action or navigation")
        app.terminate()
        app.launchArguments = ["--disc-touch-fixture"]
        app.launch()
        let menu = app.buttons["disc-menu-control-opticaldisc"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertFalse(app.activityIndicators["disc-fixture-loading"].exists)
        let select = app.buttons["disc-menu-control-circle"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        let events = app.staticTexts["disc-touch-events"]
        var taps = 0
        var keys = 0
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let rotated = NSPredicate { _, _ in
                let viewport = app.frame
                return (viewport.width > viewport.height) == orientation.isLandscape
                    && viewport.contains(select.frame) && select.frame.minY > viewport.midY
            }
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: rotated, object: nil)
            ], timeout: 5), .completed)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            taps += 1
            XCTAssertEqual(events.label, "Disc touch fixture: \(taps) taps, \(keys) keys")
            select.tap()
            keys += 1
            XCTAssertEqual(events.label, "Disc touch fixture: \(taps) taps, \(keys) keys")
            for symbol in ["arrow.up", "arrow.down", "arrow.left", "arrow.right", "circle", "opticaldisc"] {
                XCTAssertEqual(app.buttons.matching(identifier: "disc-menu-control-\(symbol)").count, 1)
            }
            XCTAssertGreaterThanOrEqual(select.frame.width, 44)
            XCTAssertGreaterThanOrEqual(select.frame.height, 44)
            let up = app.buttons["disc-menu-control-arrow.up"]
            XCTAssertEqual((up.frame.minX + select.frame.maxX) / 2, app.frame.midX, accuracy: 3)
            XCTAssertGreaterThan(menu.frame.minX, select.frame.maxX)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Disc glass controls \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        menu.tap()
        XCTAssertTrue(app.buttons["Toggle menu visibility"].waitForExistence(timeout: 5))
        app.buttons["Toggle menu visibility"].tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5), "A temporary clear must not remove the navigation controls")
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: select)
        ], timeout: 5), .completed)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["Toggle menu visibility"].waitForExistence(timeout: 5))
        app.buttons["Toggle menu visibility"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: select)
        ], timeout: 5), .completed)
    }
}
