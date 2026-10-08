import XCTest

@MainActor
final class ViewCustomizationRemoteTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testArtworkScopesAreIndependentAndBottomRowsScrollAboveHelp() {
        let app = launch()
        defer { app.terminate() }
        let sidebar = app.buttons["settings-master-artwork"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { sidebar.hasFocus })
        XCUIRemote.shared.press(.right)
        focus(app.buttons["artwork-customization"], in: app)
        XCUIRemote.shared.press(.select)
        let hero = app.buttons["artwork-view-home"]
        XCTAssertTrue(waitUntil { self.hasFocus(hero) }, app.debugDescription)
        let help = app.descendants(matching: .any)["view-customization-help"]
        let viewport = app.scrollViews["view-customization-scroll"]
        XCTAssertTrue(help.exists, app.debugDescription)
        let initialHelpFrame = help.frame
        let initialViewportFrame = viewport.frame
        capture(app, "artwork-home-context-card")
        XCTAssertEqual(hero.label, "Showcase / hero")
        cycle(hero, expecting: "Library")
        XCTAssertEqual(app.buttons["artwork-view-homeRows"].value as? String, "Metadata providers")
        XCTAssertEqual(app.buttons["artwork-view-recommendedHero"].value as? String, "Metadata providers")
        for area in ["homeRows", "recommendedHero", "recommended", "browse", "collections", "playlists"] {
            let row = app.buttons["artwork-view-\(area)"]
            focus(row, in: app)
            cycle(row, expecting: "Library")
            XCTAssertEqual(app.buttons["artwork-view-watchlist"].value as? String, "Metadata providers")
        }
        capture(app, "artwork-library-scopes")
        for area in ["continueWatching", "search", "watchlist", "details", "episodes", "playback", "music", "topShelf"] {
            let row = app.buttons["artwork-view-\(area)"]
            focus(row, in: app)
            XCTAssertTrue(viewport.exists, app.debugDescription)
            XCTAssertTrue(help.exists, app.debugDescription)
            XCTAssertEqual(viewport.frame, initialViewportFrame)
            XCTAssertEqual(help.frame, initialHelpFrame, "Focus changes must not resize or move the card.")
            XCTAssertLessThan(viewport.frame.maxY, help.frame.minY,
                              "The list and card must occupy separate regions.")
            XCTAssertGreaterThanOrEqual(help.frame.minX - viewport.frame.minX, 46)
            XCTAssertGreaterThanOrEqual(viewport.frame.maxX - help.frame.maxX, 46)
            XCTAssertTrue(waitUntil {
                row.frame.minY >= viewport.frame.minY && row.frame.maxY <= viewport.frame.maxY
            }, "The complete focused row must remain above contextual help: \(row.frame), \(help.frame)")
            if area == "music" { capture(app, "artwork-music-fully-visible") }
        }
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(hasFocus(app.buttons["artwork-view-topShelf"]),
                      "The help card must not create an extra focus stop.")
        capture(app, "artwork-bottom-fully-visible")
    }

    func testArtworkTogglesValuesAndPresetSelectionReplacesCustomizations() throws {
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
        for _ in 0..<3 {
            cycle(browse, expecting: "Library")
            cycle(browse, expecting: "Metadata providers")
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(customize) }, app.debugDescription)
        XCTAssertTrue(customize.label.hasSuffix("Custom"))
        for preset in ["recommended", "library", "online"] {
            XCTAssertFalse(app.buttons["artwork-preset-\(preset)"].isSelected)
        }
        let onlinePreset = app.buttons["artwork-preset-online"]
        focus(onlinePreset, in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(onlinePreset.isSelected)
        XCTAssertFalse(customize.label.hasSuffix("Custom"))
        // Removing the badge can replace the AX focus wrapper. Prove the
        // direct Down/Select path by opening the page, rather than its flag.
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
        focus(browse, in: app)
        cycle(browse, expecting: "Library")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(customize) })
        let libraryPreset = app.buttons["artwork-preset-library"]
        focus(libraryPreset, in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(libraryPreset.isSelected)
        XCTAssertFalse(customize.label.hasSuffix("Custom"))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
        focus(browse, in: app)
        XCTAssertEqual(browse.value as? String, "Library")
        XCTAssertEqual(app.buttons["artwork-view-continueWatching"].value as? String, "Library")

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitUntil { sidebar.hasFocus }, app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        XCUIRemote.shared.press(.right)
        focus(browse, in: app)
        capture(app, "artwork-replaced-by-preset")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil {
            customize.exists && app.buttons["artwork-preset-online"].isEnabled
        }, app.debugDescription)
        XCTAssertFalse(customize.label.hasSuffix("Custom"))
        XCTAssertFalse(customize.label.contains("defaults"))
        capture(app, "artwork-return-focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testLabelsToggleValuesAndReselectingDefaultRestoresMixedBehavior() {
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
        XCTAssertEqual(home.value as? String, "Mixed")
        XCTAssertTrue(waitUntil { self.hasFocus(home) }, app.debugDescription)
        let help = app.descendants(matching: .any)["view-customization-help"]
        let initialHelpFrame = help.frame
        let viewport = app.scrollViews["view-customization-scroll"]
        let initialViewportFrame = viewport.frame
        cycle(home, expecting: "Off")
        XCTAssertEqual(help.frame, initialHelpFrame)
        XCTAssertEqual(viewport.frame, initialViewportFrame)
        capture(app, "labels-flat-child-page")
        cycle(home, expecting: "On")
        XCTAssertEqual(help.frame, initialHelpFrame)
        XCTAssertEqual(viewport.frame, initialViewportFrame)
        cycle(home, expecting: "Off")
        cycle(home, expecting: "On")
        focus(app.buttons["view-customization-back"], in: app, direction: .up)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil {
            customize.exists && app.buttons["card-labels-recommended"].isEnabled
        }, app.debugDescription)
        XCTAssertEqual(sidebar.frame, originalFrame)
        XCTAssertTrue(customize.label.hasSuffix("Custom"))
        for preset in ["recommended", "on", "off"] {
            XCTAssertFalse(app.buttons["card-labels-\(preset)"].isSelected)
        }
        capture(app, "labels-return-focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(home.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(home.value as? String, "On")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(customize) })
        let recommended = app.buttons["card-labels-recommended"]
        XCUIRemote.shared.press(.up)
        focus(recommended, in: app, direction: .left)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(recommended.isSelected)
        XCTAssertFalse(customize.label.hasSuffix("Custom"))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(home) })
        XCTAssertEqual(home.value as? String, "Mixed")
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
        for _ in 0..<24 {
            if hasFocus(target) { return }
            XCUIRemote.shared.press(direction)
        }
        XCTAssertTrue(hasFocus(target), app.debugDescription)
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .allElementsBoundByIndex.contains(where: \.hasFocus))
    }

    private func cycle(_ row: XCUIElement, expecting value: String) {
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { self.hasFocus(row) && (row.value as? String) == value },
                      "Repeated Select must update the same focused row to \(value)")
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
