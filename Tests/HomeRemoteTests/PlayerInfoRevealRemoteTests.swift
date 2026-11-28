import XCTest

@MainActor
final class PlayerInfoRevealRemoteTests: XCTestCase {
    func testFirstDownWarmRepeatsAndReopenKeepFocusAndRestingGeometry() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--player-presentation-back-fixture", "--player-info-reopen"]
        app.launch()
        defer { app.terminate() }
        expect(app, "player-back-phase", "ready")
        expect(app, "player-back-surface-focus", "true")
        expect(app, "player-back-controls", "false")
        capture(app, name: "fresh-hidden")

        var restingInfo: CGRect?
        func assertInfoFocusAndGeometry() {
            let info = app.buttons["Info"]
            expect(app, "player-back-surface-focus", "false")
            XCTAssertTrue(info.isEnabled)
            XCTAssertTrue(info.isHittable)
            if let first = restingInfo {
                XCTAssertEqual(info.frame.minY, first.minY, accuracy: 1)
                XCTAssertEqual(info.frame.height, first.height, accuracy: 1)
            } else {
                restingInfo = info.frame
            }
            XCTAssertGreaterThan(app.buttons["Restart"].frame.minY, info.frame.maxY)
        }
        for name in ["first", "warm-1", "warm-2"] {
            print("PLAYER_INFO_INPUT \(name) down \(Date().timeIntervalSince1970)")
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))
            capture(app, name: name)
            assertInfoFocusAndGeometry()
            XCUIRemote.shared.press(.menu)
            expect(app, "player-back-surface-focus", "true")
            XCUIRemote.shared.press(.menu)
            expect(app, "player-back-controls", "false")
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["player-info-reopen"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        expect(app, "player-back-make-count", "2")
        expect(app, "player-back-phase", "ready")
        expect(app, "player-back-surface-focus", "true")
        capture(app, name: "reopened-hidden")
        print("PLAYER_INFO_INPUT reopened down \(Date().timeIntervalSince1970)")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))
        capture(app, name: "reopened")
        assertInfoFocusAndGeometry()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "player-info-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "player-info-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let info = app.buttons["Info"]
        let restart = app.buttons["Restart"]
        print("PLAYER_INFO_FRAME \(name) info=\(info.exists ? info.frame : .null) restart=\(restart.exists ? restart.frame : .null)")
    }

    private func expect(_ app: XCUIApplication, _ identifier: String, _ value: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let element = app.staticTexts[identifier]
                    return element.exists && element.label == value
                }, object: nil
            )
        ], timeout: 10), .completed, "\(identifier) should become \(value)")
    }
}
