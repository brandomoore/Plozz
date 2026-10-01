import XCTest

@MainActor
final class PlayerSkipMarkerPreviewRemoteTests: XCTestCase {
    func testPatternChoicesKeepOnlyTwoHalfHeightMaterialComparisonsAndRemoteControls() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--skip-marker-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["marker-preview-ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-glass"].firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-flat"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["marker-preview-size"].exists, "The comparison is fixed at 50%.")
        XCTAssertFalse(app.staticTexts["A  ·  50% open cutout"].exists)
        let diagonal = app.buttons["marker-pattern-diagonal"]
        XCTAssertTrue(isFocused(diagonal))
        XCTAssertEqual(diagonal.value as? String, "Selected")
        attach(app, "Diagonals - Liquid Glass and flat")
        for pattern in ["chevrons", "dashes", "dots"] {
            let button = app.buttons["marker-pattern-\(pattern)"]
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(isFocused(button))
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(button.value as? String, "Selected")
            XCTAssertEqual(diagonal.value as? String, "Not selected")
            attach(app, "\(pattern) - Liquid Glass and flat")
        }
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(isFocused(diagonal))
        XCUIRemote.shared.press(.down)
        let position = app.buttons["marker-preview-position"]
        XCTAssertTrue(position.isHittable)
        XCTAssertTrue(isFocused(position))
        XCTAssertEqual(position.value as? String, "11:15")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(position.value as? String, "11:50")

        let buffer = app.buttons["marker-preview-buffer"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(buffer))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(buffer.value as? String, "11:55")

        let focus = app.buttons["marker-preview-focus"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(focus))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(focus.label, "Bar: normal")
        attach(app, "Normal dotted Liquid Glass and flat comparison")

        let picture = app.buttons["marker-preview-picture"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(picture))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(picture.label, "Picture: bright")
        attach(app, "Bright picture behind both dotted materials")

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
