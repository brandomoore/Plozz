import XCTest

@MainActor
final class PlayerCastColdRenderingTests: XCTestCase {
    func testFirstVisitRealizesOnlyNearbyFacesAndDeepDrillKeepsItsReturnTarget() throws {
        try verifyFirstVisit()
    }

    func testRightToLeftCastKeepsDeepDrillFocusAndBoundedFirstRealization() throws {
        try verifyFirstVisit(rightToLeft: true)
    }

    func testFlatCastKeepsTheSameBoundedFirstRealizationAndFocus() throws {
        try verifyFirstVisit(flat: true)
    }

    private func verifyFirstVisit(rightToLeft: Bool = false, flat: Bool = false) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--player-cast-focus-fixture"] + (rightToLeft ? ["--rtl"] : []) + (flat ? ["--flat"] : [])
        app.launch()
        defer { app.terminate() }
        let realized = app.staticTexts["player-cast-realized"]
        XCTAssertTrue(realized.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["player-cast-browse"].isHittable)
        let count = try XCTUnwrap(Int(realized.label))
        print("PLZCAST_COLD realizedFaces=\(count) totalFaces=20 rtl=\(rightToLeft) flat=\(flat)")
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(count, 12, "A cold visit must not construct all twenty offscreen glass cards.")
        XCUIRemote.shared.press(.down)
        guard waitForFocus(app.buttons["player-cast-face-0"]) else {
            XCTFail("Native entry did not reach the first face: \(app.staticTexts["player-cast-focus"].label)")
            return
        }
        let forward: XCUIRemote.Button = rightToLeft ? .left : .right
        let backward: XCUIRemote.Button = rightToLeft ? .right : .left
        for index in 1...14 {
            XCUIRemote.shared.press(forward)
            guard waitForFocus(app.buttons["player-cast-face-\(index)"]) else {
                XCTFail("Native focus did not reach face \(index): \(app.staticTexts["player-cast-focus"].label)")
                return
            }
        }
        let selected = app.buttons["player-cast-face-14"]
        let frame = settledFrame(selected)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["player-cast-opened"].label == "14" })
        XCTAssertTrue(waitUntil { app.staticTexts["player-cast-focus"].label.contains("castBack") })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { app.staticTexts["player-cast-opened"].label == "none" })
        XCTAssertTrue(waitForFocus(selected))
        XCTAssertEqual(settledFrame(selected).minX, frame.minX, accuracy: 1,
                       "Returning to a late cast member must not reset or nudge the scroll position.")
        XCUIRemote.shared.press(forward)
        XCTAssertTrue(waitForFocus(app.buttons["player-cast-face-15"]))
        XCUIRemote.shared.press(backward)
        XCTAssertTrue(waitForFocus(selected))
    }

    private func waitForFocus(_ element: XCUIElement) -> Bool {
        waitUntil { element.exists && element.value(forKey: "hasFocus") as? Bool == true }
    }

    private func settledFrame(_ element: XCUIElement) -> CGRect {
        var prior = element.frame
        var stableSamples = 0
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let frame = element.frame
            if abs(frame.minX - prior.minX) < 0.1 && abs(frame.width - prior.width) < 0.1 {
                stableSamples += 1
                if stableSamples == 3 { return frame }
            } else {
                stableSamples = 0
            }
            prior = frame
        }
        XCTFail("The focused cast card did not settle.")
        return prior
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        ], timeout: 4) == .completed
    }
}
