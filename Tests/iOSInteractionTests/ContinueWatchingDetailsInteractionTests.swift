import XCTest

@MainActor
final class ContinueWatchingDetailsInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MainActor.assumeIsolated {
            app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let testRun, testRun.failureCount > 0, app.state == .runningForeground {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.lifetime = .keepAlways
                add(tree)
                let image = XCTAttachment(screenshot: app.screenshot())
                image.lifetime = .keepAlways
                add(image)
            }
            app.terminate()
            app = nil
        }
        super.tearDown()
    }

    func testDefaultContinueWatchingOpensEpisodeDetailsForBothProvidersAndLayouts() {
        for options in [[], ["--portrait"], ["--plex"], ["--plex", "--portrait"]] {
            launch(options)
            openCard("E2")
            XCTAssertTrue(app.staticTexts["Episode-specific synopsis."].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Whole-show synopsis."].exists)
            app.terminate()
        }
    }

    func testDefaultContinueWatchingOpensMovieDetails() {
        launch()
        openCard("Continuing movie")
        XCTAssertTrue(app.staticTexts["Movie-specific synopsis."].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testOrdinaryEpisodeBrowsingStillOpensTheShow() {
        launch()
        openCard("E3")
        XCTAssertTrue(app.staticTexts["Whole-show synopsis."].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func launch(_ options: [String] = []) {
        app.launchArguments = ["--continue-watching-details-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + options
        app.launch()
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 15), app.debugDescription)
    }

    private func openCard(_ labelFragment: String) {
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", labelFragment)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 where !card.isHittable { app.swipeUp() }
        card.tap()
    }
}
