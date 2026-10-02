import XCTest

@MainActor
final class PlayerSkipMarkerPreviewRemoteTests: XCTestCase {
    func testProductionSegmentedExamplesKeepBothMaterialsAndRemoteControlsWithoutStyleOptions() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--skip-marker-preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["marker-preview-ready"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-glass"].firstMatch.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["marker-preview-flat"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["marker-preview-size"].exists)
        XCTAssertFalse(app.buttons["marker-preview-segmented"].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "marker-pattern-")).count, 0,
                       "Segmented markers are the single design, not another user preference.")
        attach(app, "Rounded sections - Liquid Glass and flat")
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
