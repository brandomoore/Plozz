import XCTest

@MainActor
final class DiscMenuInputRemoteTests: XCTestCase {
    func testOneSelectActivatesAndDirectionsNeverActivate() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--disc-menu-input-fixture"]
        app.launch()
        defer { app.terminate() }
        let keys = app.staticTexts["disc-input-keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        expect(keys, "16")
        XCUIRemote.shared.press(.right)
        expect(keys, "16,15")
        XCUIRemote.shared.press(.left)
        expect(keys, "16,15,14")
        XCUIRemote.shared.press(.down)
        expect(keys, "16,15,14,13")
        XCUIRemote.shared.press(.up)
        expect(keys, "16,15,14,13,12")
        XCUIRemote.shared.press(.select)
        expect(keys, "16,15,14,13,12,16")
    }

    private func expect(_ element: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.label == value }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(value); received \(element.label)")
    }
}
