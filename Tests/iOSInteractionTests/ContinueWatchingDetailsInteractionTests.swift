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

    func testDefaultContinueWatchingOpensSeriesWithCurrentResumeForBothProvidersAndLayouts() {
        for options in [[], ["--portrait"], ["--plex"], ["--plex", "--portrait"]] {
            launch(options)
            openCard("E2")
            XCTAssertTrue(app.staticTexts["Whole-show synopsis."].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["series-season-tabs"].waitForExistence(timeout: 10), app.debugDescription)
            app.terminate()
        }
    }

    func testDefaultContinueWatchingOpensMovieDetails() {
        launch()
        openCard("Continuing movie")
        XCTAssertTrue(app.staticTexts["Movie-specific synopsis."].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testOrdinaryEpisodeBrowsingUsesShowMetadataAndCurrentResume() {
        launch()
        openCard("E3")
        XCTAssertTrue(app.staticTexts["Whole-show synopsis."].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["series-season-tabs"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["detail-hero-play"].label.contains("E2"), app.debugDescription)
    }

    func testSearchAndStaleContinueWatchingShowTheSameFrenchSeriesAndResume() {
        for options in [[], ["--plex"], ["--details-search"], ["--details-search", "--plex"]] {
            app.launchArguments = ["--continue-watching-details-fixture", "--detail-route-parity"] + options
            app.launch()
            if options.contains("--details-search") {
                let search = app.textFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
                search.tap()
                search.typeText("Fixture")
                let result = app.staticTexts["Fixture show"].firstMatch
                XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
                result.tap()
            } else {
                openCard("E3")
            }
            XCTAssertTrue(app.staticTexts["Description FR de la serie."].waitForExistence(timeout: 15), app.debugDescription)
            let play = app.buttons["detail-hero-play"]
            let resumed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in play.exists && play.label.contains("E2") }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 15), .completed, app.debugDescription)
            app.terminate()
        }
    }

    func testMovieRowHeaderRemainsNavigableAcrossRepeatedPushes() {
        executionTimeAllowance = 120
        launch(["--browse-movies"])
        assertMovieRowNavigation(title: "Recently Added")
    }

    func testLibraryMovieRowHeaderRemainsNavigableAcrossRepeatedPushes() {
        executionTimeAllowance = 120
        launch(["--browse-movies", "--browse-library-movies"])
        assertMovieRowNavigation(title: "Recently Added in Movies")
    }

    func testServerFilmsHeaderWithHeroRemainsNavigableAcrossRepeatedPushes() {
        executionTimeAllowance = 180
        launch(["--browse-movies", "--browse-server-films"])
        XCTAssertTrue(app.buttons["home-hero-artwork-detail"].waitForExistence(timeout: 10))
        assertMovieRowNavigation(title: "Films")
    }

    private func assertMovieRowNavigation(title: String) {
        let heading = app.buttons.matching(identifier: "home-row-see-all")
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        for _ in 0..<4 {
            for _ in 0..<4 where !heading.exists { app.swipeUp() }
            XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<3 where !heading.isHittable { app.swipeUp() }
            heading.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Browse movie 0"))
                .firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["home-row-sort-menu"].exists)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(heading.wait(for: \.isHittable, toEqual: true, timeout: 10))
        }
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
