import XCTest

@MainActor
final class LiveTVSettingsInteractionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMediaServerRowsUseCompactSharedBrandsAndNeutralControls() throws {
        for options in [[], ["--light"]] {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
            app.launchArguments = ["--source-settings", "--server-sources"] + options
            app.launch()
            defer { app.terminate() }
            let plex = app.buttons["live-tv-source-details-plex-source"]
            let jellyfin = app.buttons["live-tv-source-details-jellyfin-source"]
            XCTAssertTrue(plex.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(plex.label.contains("Plex"))
            XCTAssertTrue(jellyfin.label.contains("Jellyfin"))
            for source in [plex, jellyfin] {
                XCTAssertGreaterThanOrEqual(source.frame.height, 44)
                XCTAssertLessThanOrEqual(source.frame.height, 72, "A standard two-line source must stay compact.")
            }
            let startView = app.descendants(matching: .any)["live-tv-start-view"].firstMatch
            XCTAssertTrue(app.staticTexts["Live TV opens to"].exists, app.debugDescription)
            try assertNeutralInk(app.buttons["live-tv-add-source"])
            try assertNeutralInk(startView)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "live-tv-compact-shared-logos-\(options.isEmpty ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testBrowsingPreferencesRemainAvailableWhenSourcesAreLockedOrFailToLoad() {
        for condition in ["--source-kids-locked", "--source-load-fails"] {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
            app.launchArguments = ["--source-settings", condition]
            app.launch()
            defer { app.terminate() }
            let guide = app.buttons["live-tv-guide-preferences"]
            XCTAssertTrue(guide.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.buttons["live-tv-add-source"].exists)
            if condition == "--source-kids-locked" {
                XCTAssertTrue(app.buttons["live-tv-unlock-sources"].exists)
            } else {
                XCTAssertTrue(app.buttons["Retry"].exists)
            }
            tapVisible(guide, in: app)
            XCTAssertTrue(app.navigationBars["Guide preferences"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["Recently watched"].exists)
        }
    }

    func testHeaderAddAndSourceRowsOpenOnlyTheirOwnDestinations() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--source-settings", "--configured-sources", "--catalog-sources"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["live-tv-add-source"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["live-tv-source-details-fixture"].exists)
        XCTAssertTrue(app.navigationBars["Live TV"].exists)
        captureSourceEntry("TV-sources-overview", in: app)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add TV Source"].waitForExistence(timeout: 5))
        captureSourceEntry("Add-TV-source", in: app)
        for (identifier, title) in [
            ("live-tv-add-playlist", "IPTV source"),
            ("live-tv-add-server", "Media server"),
            ("live-tv-import-playlist", "Imported playlist")
        ] {
            tapVisible(app.buttons[identifier], in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            if identifier == "live-tv-add-server" {
                captureSourceEntry("TV-media-server-setup", in: app)
            }
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Add TV Source"].waitForExistence(timeout: 5))
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Live TV"].waitForExistence(timeout: 5))
        app.buttons["live-tv-source-details-fixture"].tap()
        XCTAssertTrue(app.navigationBars["Fixture IPTV"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["live-tv-edit-source-fixture"], in: app)
        XCTAssertTrue(app.navigationBars["IPTV source"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Fixture IPTV"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Live TV"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["live-tv-guide-preferences"], in: app)
        XCTAssertTrue(app.navigationBars["Guide preferences"].waitForExistence(timeout: 5))
        app.switches["Recently watched"].tap()
        waitForSavedPreferences("Recent false favorites false", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["live-tv-channel-visibility"], in: app)
        XCTAssertTrue(app.navigationBars["Channel visibility"].waitForExistence(timeout: 5))
        app.switches["Favorites only"].tap()
        waitForSavedPreferences("Recent false favorites true", in: app)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
    }

    private func captureSourceEntry(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBrowsingChoicesChangeInlineAndSaveImmediately() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--source-settings", "--configured-sources"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-add-source"].waitForExistence(timeout: 10))
        for (current, choice, identifier, saved) in [
            ("Channel number", "Name", "fixture-sort-metrics", "Order by name"),
            ("Name", "Channel number", "fixture-sort-metrics", "Order by number"),
            ("Categories", "Guide", "fixture-start-view-metrics", "Start with guide"),
            ("Guide", "Categories", "fixture-start-view-metrics", "Start with categories")
        ] {
            tapVisible(app.buttons[current], in: app)
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 5), app.debugDescription)
            app.buttons[choice].tap()
            let savedOrder = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", saved),
                object: app.staticTexts[identifier]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [savedOrder], timeout: 5), .completed)
            XCTAssertTrue(app.navigationBars["Live TV"].exists)
            XCTAssertFalse(app.navigationBars["Channel order"].exists)
        }
    }

    func testRootAutomaticToggleAndFifthSourceStayIndependent() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--source-settings", "--configured-sources", "--many-sources", "--automatic-channels"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["live-tv-add-source"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(add.frame.height, 64)
        let list = app.scrollViews["live-tv-sources-list"]
        XCTAssertTrue(list.exists)
        let first = app.buttons["live-tv-source-details-fixture"]
        let fifth = app.buttons["live-tv-source-details-fixture-4"]
        let viewport = list.frame.intersection(app.frame)
        XCTAssertGreaterThanOrEqual(first.frame.minY, viewport.minY)
        XCTAssertEqual(viewport.intersection(fifth.frame).height / fifth.frame.height, 0.5, accuracy: 0.08)
        list.swipeUp()
        let last = app.buttons["live-tv-source-details-fixture-5"]
        XCTAssertTrue(last.isHittable)
        last.tap()
        XCTAssertTrue(app.navigationBars["Fixture source 6"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let automatic = app.switches["live-tv-automatic-enabled"]
        tapVisible(automatic, in: app)
        XCTAssertTrue(automatic.label.contains("Auto-create channels from your libraries"))
        XCTAssertFalse(app.staticTexts["Channels made from your movies and shows."].exists)
        XCTAssertEqual(automatic.value as? String, "1")
        XCTAssertEqual(app.staticTexts["fixture-automatic-metrics"].label, "Enabled true changes 1 retries 0")
        automatic.tap()
        XCTAssertEqual(automatic.value as? String, "0")
        XCTAssertEqual(app.staticTexts["fixture-automatic-metrics"].label, "Enabled false changes 2 retries 0")
        XCTAssertTrue(app.buttons["live-tv-manage-library-channels"].label.contains("Manage channels"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "live-tv-overview"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTFail("Missing tappable control: \(element.identifier)\n\(app.debugDescription)")
    }

    private func waitForSavedPreferences(_ value: String, in app: XCUIApplication) {
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", value),
            object: app.staticTexts["fixture-view-settings-metrics"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed,
                       "A child-page change must persist before navigating back.")
    }

    private func assertNeutralInk(_ element: XCUIElement) throws {
        let image = try XCTUnwrap(element.screenshot().image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let bluePixels = stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) - Int(bytes[$0]) > 40
        }.count
        XCTAssertLessThan(bluePixels, 10, "\(element.identifier) must not use system-blue control ink.")
    }
}
