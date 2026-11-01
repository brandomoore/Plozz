import XCTest

@MainActor
final class PosterZoomInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var motionSettings: XCUIApplication?
    private var originalReduceMotion: String?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 { capture("zoom-failure") }
        app.terminate()
        app = nil
        if let motionSettings, let originalReduceMotion {
            motionSettings.activate()
            let toggle = motionSettings.switches["Reduce Motion"]
            if toggle.value as? String != originalReduceMotion {
                let control = toggle.switches.firstMatch
                if control.exists { control.tap() } else { toggle.tap() }
            }
            motionSettings.terminate()
        }
        try await super.tearDown()
    }

    func testNativeSwipeCanCancelAndComplete() {
        launch()
        let card = app.buttons["zoom-card-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        card.tap()
        XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
        swipeBack(to: 0.13)
        XCTAssertTrue(app.staticTexts["zoom-detail"].wait(for: \.isHittable, toEqual: true, timeout: 5))
        capture("native-zoom-cancelled")
        swipeBack(to: 0.9)
        XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5))
    }

    func testCustomizedCardShapesAndSizesReturnToTheTappedOccurrence() throws {
        let shapes = ["portrait", "landscape", "series-landscape", "series-portrait", "series-progress", "portrait"]
        let densities = ["micro", "extraCompact", "compact", "standard", "spacious", "extraLarge"]
        for framed in [false, true] {
            for (index, shape) in shapes.enumerated() {
                launch(
                    shape: shape, density: densities[index], framed: framed,
                    extra: index == 5 ? ["--large-text", "--no-captions"] : []
                )
                let card = app.buttons["zoom-card-1"]
                reveal(card)
                let before = card.frame
                let offset = try XCTUnwrap(Double(app.staticTexts["zoom-scroll-offset"].label))
                card.tap()
                XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["zoom-detail"].label, "row-1")
                swipeBack(to: 0.9)
                XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
                XCTAssertEqual(card.frame.minX, before.minX, accuracy: 2)
                let returnedOffset = try XCTUnwrap(Double(app.staticTexts["zoom-scroll-offset"].label))
                XCTAssertEqual(returnedOffset, offset, accuracy: 2, "\(shape), \(densities[index]), framed: \(framed)")
                XCTAssertEqual(card.frame.width, before.width, accuracy: 2)
                XCTAssertEqual(card.frame.height, before.height, accuracy: 2)
                card.tap()
                XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["zoom-detail"].label, "row-1")
                tapBack()
                XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5))
            }
        }
    }

    func testProductionHomeCardOpensProviderDetailAndReturns() {
        app.launchArguments = ["--home-hero-fixture", "--poster-home-card"]
        app.launch()
        let card = app.buttons["home-poster"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        let before = card.frame
        card.tap()
        XCTAssertTrue(app.staticTexts["Details for movie from jellyfin"].waitForExistence(timeout: 10), app.debugDescription)
        swipeBack(to: 0.9)
        XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(card.frame.minY, before.minY, accuracy: 2)
    }

    func testFeaturedAndFilmographyArtworkUseNativeZoomAndReturn() {
        for surface in ["featured", "filmography"] {
            launch(extra: ["--\(surface)"])
            let card = app.scrollViews.matching(identifier: "zoom-\(surface)-row").firstMatch.buttons.firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
            card.tap()
            XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["zoom-detail"].label, surface)
            swipeBack(to: 0.9)
            XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5))
        }
    }

    func testNestedValueProgrammaticAndPlainNavigation() {
        launch()
        let first = app.buttons["zoom-card-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let nested = app.buttons["zoom-nested"]
        XCTAssertTrue(nested.waitForExistence(timeout: 5))
        nested.tap()
        XCTAssertTrue(app.staticTexts["zoom-nested-detail"].waitForExistence(timeout: 5))
        swipeBack(to: 0.9)
        XCTAssertTrue(app.staticTexts["zoom-detail"].wait(for: \.isHittable, toEqual: true, timeout: 5))
        swipeBack(to: 0.9)
        XCTAssertTrue(first.wait(for: \.isHittable, toEqual: true, timeout: 5))
        for (identifier, expected) in [("zoom-programmatic", "programmatic"), ("zoom-value", "value"), ("Plain entry", "plain")] {
            let link = app.buttons[identifier]
            reveal(link)
            link.tap()
            XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["zoom-detail"].label, expected)
            tapBack()
            XCTAssertTrue(link.wait(for: \.isHittable, toEqual: true, timeout: 5))
        }
    }

    func testReduceMotionKeepsNavigationAndReturnUsable() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let accessibility = settings.buttons["Accessibility"]
        for _ in 0..<8 where !accessibility.isHittable { settings.swipeUp() }
        XCTAssertTrue(accessibility.isHittable, settings.debugDescription)
        accessibility.tap()
        settings.buttons["Motion"].tap()
        let reduceMotion = settings.switches["Reduce Motion"]
        XCTAssertTrue(reduceMotion.waitForExistence(timeout: 5), settings.debugDescription)
        motionSettings = settings
        originalReduceMotion = reduceMotion.value as? String
        if originalReduceMotion != "1" {
            let toggle = reduceMotion.switches.firstMatch
            if toggle.exists { toggle.tap() } else { reduceMotion.tap() }
        }
        XCTAssertEqual(reduceMotion.value as? String, "1", settings.debugDescription)
        launch()
        XCTAssertTrue(app.staticTexts["zoom-motion-preference"].wait(for: \.label, toEqual: "reduced", timeout: 5))
        let card = app.buttons["zoom-card-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let before = card.frame
        card.tap()
        XCTAssertTrue(app.staticTexts["zoom-detail"].waitForExistence(timeout: 5))
        tapBack()
        XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(card.frame.minY, before.minY, accuracy: 2)
    }

    private func launch(shape: String = "portrait", density: String = "standard", framed: Bool = false, extra: [String] = []) {
        app.terminate()
        app.launchArguments = ["--poster-zoom-fixture", "--shape=\(shape)", "--density=\(density)"]
            + (framed ? ["--framed"] : []) + extra
        app.launch()
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            let frame = element.frame
            let top: CGFloat = 90
            let bottom = app.frame.height - 50
            if element.isHittable, frame.minY >= top, frame.maxY <= bottom { return }
            let delta = min(0.25, max(-0.25, ((top + bottom) / 2 - frame.midY) / app.frame.height))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55 + delta))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func swipeBack(to x: CGFloat) {
        let y = 220 / app.frame.height
        // A proportional start can miss iPadOS 18's narrow edge recognizer.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: y))
            .withOffset(CGVector(dx: 1, dy: 0))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func tapBack() {
        let verticalBack = app.buttons["BackButton"]
        if verticalBack.exists {
            verticalBack.tap()
        } else {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
