import XCTest

@MainActor
final class NativeSidebarHandoffTests: XCTestCase {
    func testSelectingActiveHomeReturnsFromDeepShowcaseRowsToFeaturedHero() throws {
        try exerciseHomeReselection(layout: ["--hero-showcase-home"], showsHero: true)
    }

    func testSelectingActiveHomeReturnsFromClassicRowsToFeaturedHero() throws {
        try exerciseHomeReselection(layout: [], showsHero: true)
    }

    func testSelectingActiveHomeReturnsToFirstRowWithoutHero() throws {
        for layout in [["--immersive-home"], ["--hero-disabled-home"]] {
            try exerciseHomeReselection(layout: layout, showsHero: false)
        }
    }

    func testRightReturnsToShowcaseWithoutReactivatingHome() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--native-sidebar-home", "--hero-showcase-home"]
        app.launch()
        defer { app.terminate() }
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        if !hasFocus(hero, app: app) { XCUIRemote.shared.press(.right) }
        assertFocused(hero, app: app)
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        for _ in 0..<6 {
            if hasFocus(app.buttons["Home"], app: app) { break }
            XCUIRemote.shared.press(.left)
        }
        assertFocused(app.buttons["Home"], app: app)
        let activations = app.staticTexts["native-production-selection-count"].label
        XCUIRemote.shared.press(.right)
        let focusedRow = NSPredicate { _, _ in
            app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@ AND hasFocus == true", "Fixture movie "
            )).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: focusedRow, object: nil
        )], timeout: 5), .completed, app.debugDescription)
        XCTAssertFalse(hero.isHittable, "Right returns to browsing; only Select resets the featured stage.")
        XCTAssertEqual(app.staticTexts["native-production-selection-count"].label, activations)
    }

    private func exerciseHomeReselection(layout: [String], showsHero: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--native-sidebar-home"] + layout
        app.launch()
        defer { app.terminate() }
        let first = app.buttons[showsHero ? "home-hero-action-row" : "Fixture movie 0"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), app.debugDescription)
        if !hasFocus(first, app: app) { XCUIRemote.shared.press(.right) }
        if !showsHero && !hasFocus(first, app: app) { XCUIRemote.shared.press(.left) }
        assertFocused(first, app: app, timeout: 15)
        let initialFrame = first.frame
        let initialImage = XCTAttachment(screenshot: try topContentScreenshot(app, showsHero: showsHero))
        initialImage.name = "Native Home initial \(layout)"
        initialImage.lifetime = .keepAlways
        add(initialImage)
        let focusedCard = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND hasFocus == true", "Fixture movie "
        )).firstMatch
        for cycle in 0..<2 {
            for _ in 0..<3 { XCUIRemote.shared.press(.down) }
            XCTAssertTrue(focusedCard.exists, app.debugDescription)
            XCTAssertNotEqual(focusedCard.label, "Fixture movie 0")

            for _ in 0..<6 {
                if hasFocus(app.buttons["Home"], app: app) { break }
                XCUIRemote.shared.press(.left)
            }
            assertFocused(app.buttons["Home"], app: app)
            let activations = app.staticTexts["native-production-selection-count"].label
            XCUIRemote.shared.press(.select)
            assertFocused(first, app: app)
            XCTAssertNotEqual(app.staticTexts["native-production-selection-count"].label, activations)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in abs(first.frame.minY - initialFrame.minY) < 1 },
                object: nil
            )], timeout: 5), .completed, "Reselecting Home must reveal its full top content.")
            let attachment = XCTAttachment(screenshot: try topContentScreenshot(app, showsHero: showsHero))
            attachment.name = "Native Home reselection \(layout) cycle=\(cycle)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if layout.contains("--hero-showcase-home") {
                XCUIRemote.shared.press(.down)
                assertFocused(app.buttons["Fixture movie 0"], app: app)
            }
        }
    }

    private func topContentScreenshot(_ app: XCUIApplication, showsHero: Bool) throws -> XCUIScreenshot {
        guard showsHero else { return app.screenshot() }
        let deadline = Date().addingTimeInterval(5)
        var screenshot = app.screenshot()
        repeat {
            let image = try XCTUnwrap(screenshot.image.cgImage)
            // Sample the white focused Play pill, not the title: cached artwork
            // can replace the fixture title with a colored logo.
            let controls = try XCTUnwrap(image.cropping(to: CGRect(
                x: Double(image.width) * 0.03, y: Double(image.height) * 0.72,
                width: Double(image.width) * 0.17, height: Double(image.height) * 0.09
            )))
            var pixels = [UInt8](repeating: 0, count: controls.width * controls.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: controls.width, height: controls.height,
                    bitsPerComponent: 8, bytesPerRow: controls.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(controls, in: CGRect(x: 0, y: 0, width: controls.width, height: controls.height))
            }
            let brightPixels = stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 200 && pixels[$0 + 1] > 200 && pixels[$0 + 2] > 200
            }.count
            if brightPixels > 500 {
                return screenshot
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            screenshot = app.screenshot()
        } while Date() < deadline
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Missing rendered Home hero"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("The hero controls must be visible, not merely a focused transparent action row.")
        return screenshot
    }

    func testProductionHomeDoesNotReclaimFocusDuringNativeSidebarSelection() {
        exerciseProductionHome(enterUsing: .select)
    }

    func testRightReturnsToProductionHomeWithoutSelectingTheHighlightedTab() {
        exerciseProductionHome(enterUsing: .right)
    }

    private func exerciseProductionHome(enterUsing button: XCUIRemote.Button) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--native-sidebar-home"]
        app.launchEnvironment["PLZHFOCUS_STDOUT"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15), app.debugDescription)
        if !hasFocus(hero, app: app) { XCUIRemote.shared.press(.right) }
        assertFocused(hero, app: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(app.staticTexts["native-production-armed"].label, "settings")
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"], app: app)
        XCUIRemote.shared.press(button)
        if button == .right {
            assertFocused(hero, app: app)
            XCTAssertFalse(app.buttons["native-production-settings"].exists)
            XCTAssertEqual(app.staticTexts["native-production-premature-focus"].label, "1",
                           "The recorder must detect the intentional return to Home.")
            return
        }
        let destination = app.buttons["native-production-settings"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10), app.debugDescription)
        assertFocused(destination, app: app)
        XCTAssertEqual(app.staticTexts["native-production-premature-focus"].label, "0", app.debugDescription)
    }

    func testNativeSidebarDoesNotVisitOutgoingContentWhenSelectingAnotherPage() {
        exerciseNativeSidebar(enterUsing: .select)
    }

    func testRightReturnsToCurrentNativePageWithoutSelectingTheHighlightedTab() {
        exerciseNativeSidebar(enterUsing: .right)
    }

    private func exerciseNativeSidebar(enterUsing button: XCUIRemote.Button) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--native-sidebar-handoff-fixture"]
        app.launch()
        defer { app.terminate() }

        let home = app.buttons["native-page-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription)
        if !hasFocus(home, app: app) { XCUIRemote.shared.press(.right) }
        assertFocused(home, app: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"], app: app)
        XCUIRemote.shared.press(button)
        if button == .right {
            assertFocused(home, app: app)
            XCTAssertFalse(app.buttons["native-page-settings"].exists)
            XCTAssertEqual(app.staticTexts["native-premature-focus-home"].label, "1")
            return
        }

        let settings = app.buttons["native-page-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        assertFocused(settings, app: app)
        XCTAssertEqual(app.staticTexts["native-premature-focus-settings"].label, "0", app.debugDescription)
        XCTAssertEqual(app.staticTexts["native-unpresented-focus-settings"].label, "0",
                       "Destination focus must wait for appearance and a rendered frame.")
        XCTAssertEqual(app.staticTexts["native-handoff-status"].label, "ready")

        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Settings"], app: app)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(home, app: app)
        XCTAssertEqual(app.staticTexts["native-premature-focus-home"].label, "0")
        XCTAssertEqual(app.staticTexts["native-unpresented-focus-home"].label, "0")
        XCTAssertEqual(app.staticTexts["native-handoff-status"].label, "ready")

        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(home, app: app)
        XCTAssertEqual(app.staticTexts["native-handoff-status"].label, "ready")
    }

    private func assertFocused(
        _ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(element, app: app) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed,
                       app.debugDescription, file: file, line: line)
    }

    private func hasFocus(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus { return true }
        let identifier = element.identifier.isEmpty ? element.label : element.identifier
        return app.cells.containing(.button, identifier: identifier)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }
}
