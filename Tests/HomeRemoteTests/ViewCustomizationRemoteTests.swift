import XCTest

@MainActor
final class ViewCustomizationRemoteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testArtworkChildPageMenusResetAndBackPreserveSidebarAndFocus() throws {
        let app = launch()
        defer { app.terminate() }
        let sidebar = app.buttons["settings-master-artwork"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { sidebar.hasFocus }, app.debugDescription)
        let originalFrame = sidebar.frame
        XCUIRemote.shared.press(.right)
        let customize = app.buttons["artwork-customization"]
        focus(customize, in: app)
        XCUIRemote.shared.press(.select)

        let browse = app.buttons["artwork-view-browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitUntil { self.hasFocus(app.buttons["artwork-view-home"]) }, app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        XCTAssertFalse(app.buttons["artwork-preset-online"].exists)
        XCTAssertEqual(browse.value as? String, "Metadata providers")
        focus(browse, in: app)
        capture(app, "artwork-flat-child-page")
        XCUIRemote.shared.press(.select)
        let library = menuItem("artwork-view-browse-library", in: app)
        XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(menuItem("artwork-view-browse-reset", in: app).exists)
        capture(app, "artwork-source-chooser")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(browse) }, app.debugDescription)
        XCTAssertEqual(browse.value as? String, "Metadata providers")

        XCUIRemote.shared.press(.select)
        focus(library, in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(browse) && (browse.value as? String) == "Library artwork, customized" },
                      app.debugDescription)
        XCUIRemote.shared.press(.select)
        let providers = menuItem("artwork-view-browse-online", in: app)
        focus(providers, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(browse) && (browse.value as? String) == "Metadata providers, customized" })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(customize) }, app.debugDescription)
        XCTAssertTrue(customize.label.contains("1 customized"))
        let libraryPreset = app.buttons["artwork-preset-library"]
        focus(libraryPreset, in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        focus(customize, in: app)
        XCUIRemote.shared.press(.select)
        focus(browse, in: app)
        XCTAssertEqual(browse.value as? String, "Metadata providers, customized")

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitUntil { sidebar.hasFocus }, app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        XCUIRemote.shared.press(.right)
        focus(browse, in: app)
        XCUIRemote.shared.press(.select)
        let reset = menuItem("artwork-view-browse-reset", in: app)
        focus(reset, in: app)
        capture(app, "artwork-separated-customization-reset")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(browse) && (browse.value as? String) == "Library artwork" },
                      app.debugDescription)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil {
            customize.exists && app.buttons["artwork-preset-online"].isEnabled
        }, app.debugDescription)
        XCTAssertFalse(customize.label.contains("customized"))
        XCTAssertFalse(customize.label.contains("defaults"))
        capture(app, "artwork-return-focus")
        // Removing the count changes the accessible focus wrapper. Prove return
        // focus through activation without a directional move, not its AX flag.
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testLabelChildPageUsesTheSameFlatChooserAndReturnPath() {
        let app = launch(labels: true)
        defer { app.terminate() }
        let sidebar = app.buttons["settings-master-cards"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { sidebar.hasFocus })
        let originalFrame = sidebar.frame
        XCUIRemote.shared.press(.right)
        let customize = app.buttons["card-label-customization"]
        focus(customize, in: app)
        XCUIRemote.shared.press(.select)
        let home = app.buttons["card-label-view-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        XCTAssertEqual(home.value as? String, "App default")
        XCTAssertTrue(waitUntil { self.hasFocus(home) }, app.debugDescription)
        XCUIRemote.shared.press(.select)
        let hidden = menuItem("card-label-view-home-hide", in: app)
        focus(hidden, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(home) && (home.value as? String) == "No labels, customized" })
        capture(app, "labels-flat-child-page")
        XCUIRemote.shared.press(.select)
        focus(menuItem("card-label-view-home-reset", in: app), in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(home) && (home.value as? String) == "App default" })
        focus(app.buttons["view-customization-back"], in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil {
            customize.exists && app.buttons["card-labels-recommended"].isEnabled
        }, app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        capture(app, "labels-return-focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(home.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testBackAndSidebarChangesResetOnlyNavigation() {
        let app = launch()
        defer { app.terminate() }
        let artwork = app.buttons["settings-master-artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { artwork.hasFocus })
        XCUIRemote.shared.press(.right)
        focus(app.buttons["artwork-customization"], in: app)
        XCUIRemote.shared.press(.select)
        let home = app.buttons["artwork-view-home"]
        XCTAssertTrue(waitUntil { self.hasFocus(home) }, app.debugDescription)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(app.buttons["artwork-customization"]) }, app.debugDescription)
        XCTAssertTrue(app.buttons["artwork-preset-online"].isSelected)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(home) }, app.debugDescription)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitUntil { artwork.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { app.buttons["settings-master-cards"].hasFocus })
        XCTAssertFalse(home.exists)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitUntil { artwork.hasFocus })
        XCTAssertTrue(app.buttons["artwork-customization"].exists)
        XCTAssertFalse(home.exists)
    }

    private func launch(labels: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--view-customization-fixture"]
        if labels { app.launchArguments.append("--labels") }
        app.launch()
        return app
    }

    private func focus(_ target: XCUIElement, in app: XCUIApplication,
                       direction: XCUIRemote.Button = .down) {
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<14 {
            if hasFocus(target) { return }
            XCUIRemote.shared.press(direction)
        }
        XCTAssertTrue(hasFocus(target), app.debugDescription)
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .allElementsBoundByIndex.contains(where: \.hasFocus))
    }

    private func menuItem(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.any, identifier: id).firstMatch
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        ], timeout: 5) == .completed
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
