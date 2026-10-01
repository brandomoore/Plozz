import XCTest

@MainActor
final class PlayerSkipMarkerPreviewRemoteTests: XCTestCase {
    func testFourRealBarVariantsAndRemoteControlsFitOnTheTV() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--skip-marker-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["marker-preview-ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["A  ·  50% open cutout"].isHittable)
        XCTAssertTrue(app.staticTexts["B  ·  50% cutout + faint diagonals"].isHittable)
        let position = app.buttons["marker-preview-position"]
        XCTAssertTrue(position.isHittable)
        XCTAssertTrue(isFocused(position))
        XCTAssertEqual(position.value as? String, "11:15")
        attach(app, "Focused Liquid Glass and flat performance comparison")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(position.value as? String, "11:50")

        let buffer = app.buttons["marker-preview-buffer"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(buffer))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(buffer.value as? String, "11:55")

        let size = app.buttons["marker-preview-size"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(size))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(size.label, "Cutout B: 75%")
        XCTAssertTrue(app.staticTexts["B  ·  75% cutout + faint diagonals"].isHittable)
        attach(app, "75 percent patterned cutout comparison")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(size.label, "Cutout B: 50%")
        XCTAssertTrue(app.staticTexts["B  ·  50% cutout + faint diagonals"].isHittable)

        let focus = app.buttons["marker-preview-focus"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(focus))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(focus.label, "Bar: normal")
        attach(app, "Normal Liquid Glass and flat performance comparison")

        let picture = app.buttons["marker-preview-picture"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(picture))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(picture.label, "Picture: bright")
        attach(app, "Bright picture behind both skip marker treatments")

        let done = app.buttons["marker-preview-done"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(done))
        XCTAssertTrue(done.isHittable)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["marker-preview-closed"].waitForExistence(timeout: 5))
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        element.value(forKey: "hasFocus") as? Bool == true
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
