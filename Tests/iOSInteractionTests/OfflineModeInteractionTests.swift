import XCTest

@MainActor
final class OfflineModeInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testPickerMovesEditingAndOfflineModeIntoTheMenu() {
        launch(page: "profiles")
        XCTAssertFalse(app.switches["offline-mode-toggle"].exists)
        app.buttons["profile-picker-options"].tap()
        XCTAssertTrue(app.buttons["profile-picker-edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["profile-picker-offline-mode"].exists)
        app.buttons["profile-picker-edit"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Add Profile"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["profile-picker-options"].exists)
    }

    func testNoticeDismissalKeepsTheModeEnabled() {
        launch(page: "home")
        let dismiss = app.buttons["offline-status-dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertFalse(app.buttons["home-add-source"].exists)
        dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
        XCTAssertFalse(app.buttons["offline-status-dismiss"].exists)
        XCTAssertTrue(app.staticTexts["No Downloads"].exists)
        XCTAssertFalse(app.buttons["home-add-source"].exists)
    }

    private func launch(page: String) {
        app.launchArguments = ["--offline-review-fixture", "--offline-page=\(page)"]
        app.launch()
        XCTAssertTrue(app.buttons["offline-status-dismiss"].waitForExistence(timeout: 10), app.debugDescription)
    }
}
