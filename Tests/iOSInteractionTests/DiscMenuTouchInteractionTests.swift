import UIKit
import XCTest

@MainActor
final class DiscMenuTouchInteractionTests: XCTestCase {
    func testArtworkReceivesTapsWithoutToolbarDuplicatesInBothOrientations() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--disc-touch-fixture"]
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["disc-menu-control-opticaldisc"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.count, 1)
        menu.tap()
        let select = app.buttons["disc-menu-control-checkmark"]
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
            XCTAssertEqual(app.buttons.count, 6)
            XCTAssertGreaterThanOrEqual(select.frame.width, 44)
            XCTAssertGreaterThanOrEqual(select.frame.height, 44)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Disc glass controls \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }
}
