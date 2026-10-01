import XCTest

@MainActor
final class PlayerSkipMarkerPreviewRemoteTests: XCTestCase {
    func testSegmentedAndPatternChoicesKeepBothMaterialsAndRemoteControls() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--skip-marker-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["marker-preview-ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-glass"].firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-flat"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["marker-preview-size"].exists, "Patterned alternatives stay fixed at 50%.")
        XCTAssertFalse(app.staticTexts["A  ·  50% open cutout"].exists)
        let segmented = app.buttons["marker-preview-segmented"]
        XCTAssertEqual(segmented.value as? String, "Selected", "The new alternative is shown without changing the real player default.")
        XCTAssertTrue(isFocused(segmented))
        let fine = app.buttons["marker-pattern-fineHatch"]
        XCTAssertEqual(fine.value as? String, "Not selected")
        XCTAssertTrue(fine.isHittable, "The chosen fine hatch remains available for comparison.")
        attach(app, "Rounded sections - Liquid Glass and flat")
        let diagonal = app.buttons["marker-pattern-diagonal"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(diagonal))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(segmented.value as? String, "Not selected")
        XCTAssertEqual(diagonal.value as? String, "Selected")
        attach(app, "Diagonals - Liquid Glass and flat")
        for pattern in ["denseDots", "mediumHatch", "fineHatch", "mesh"] {
            let button = app.buttons["marker-pattern-\(pattern)"]
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(isFocused(button))
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(button.value as? String, "Selected")
            XCTAssertEqual(diagonal.value as? String, "Not selected")
            attach(app, "\(pattern) - Liquid Glass and flat")
        }
        for _ in 0..<4 { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(isFocused(diagonal))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(segmented))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(segmented.value as? String, "Selected")
        XCTAssertEqual(app.buttons["marker-pattern-mesh"].value as? String, "Not selected")
        XCUIRemote.shared.press(.down)
        let scenario = app.buttons["marker-preview-scenario"]
        XCTAssertTrue(isFocused(scenario))
        XCTAssertEqual(scenario.label, "Example: 1h episode")
        for label in ["Example: 24m episode", "Example: 3h movie", "Example: 90m recording",
                      "Example: 45m / tiny recap", "Example: 1h episode"] {
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(scenario.label, label)
            attach(app, label)
        }
        XCUIRemote.shared.press(.down)
        let position = app.buttons["marker-preview-position"]
        XCTAssertTrue(position.isHittable)
        XCTAssertTrue(isFocused(position))
        XCTAssertEqual(position.value as? String, "1:45")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(position.value as? String, "1:58")

        let buffer = app.buttons["marker-preview-buffer"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(buffer))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(buffer.value as? String, "2:15")

        let focus = app.buttons["marker-preview-focus"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(focus))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(focus.label, "Bar: normal")
        attach(app, "Normal segmented Liquid Glass and flat comparison")

        let picture = app.buttons["marker-preview-picture"]
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(picture))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(picture.label, "Picture: bright")
        attach(app, "Bright picture behind both segmented materials")

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
