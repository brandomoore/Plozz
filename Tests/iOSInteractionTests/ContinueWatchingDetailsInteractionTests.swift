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

    func testPreviouslyOpenedMoviesRowRestoresArtworkAfterTermination() throws {
        app.launchEnvironment["PLOZZ_TEST_REVISIT_ID"] = UUID().uuidString
        for seed in [true, false] {
            launch(["--browse-movies"] + (seed ? ["--seed-revisit-bytes"] : []))
            openCard("Browse movie 0")
            XCTAssertTrue(app.staticTexts["Revisited movie synopsis."].waitForExistence(timeout: 10))
            let rendered = XCTestExpectation(description: "Green detail backdrop and red wordmark")
            let end = Date().addingTimeInterval(6)
            repeat {
                let screenshot = app.screenshot()
                let image = try XCTUnwrap(screenshot.image.cgImage)
                var bytes = [UInt8](repeating: 0, count: 64 * 128 * 4)
                let counts = try bytes.withUnsafeMutableBytes { buffer -> (green: Int, red: Int) in
                    let context = try XCTUnwrap(CGContext(
                        data: buffer.baseAddress, width: 64, height: 128, bitsPerComponent: 8, bytesPerRow: 256,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    ))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 128))
                    var green = 0, red = 0
                    for i in stride(from: 0, to: buffer.count, by: 4) {
                        if buffer[i + 1] > 110 && buffer[i] < 55 && buffer[i + 2] < 55 { green += 1 }
                        if buffer[i] > 130 && buffer[i + 1] < 60 && buffer[i + 2] < 60 { red += 1 }
                    }
                    return (green, red)
                }
                if counts.green > 300 && counts.red > 12 {
                    let attachment = XCTAttachment(screenshot: screenshot)
                    attachment.name = seed ? "first-visit" : "fresh-process-reopen"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    rendered.fulfill()
                    break
                }
            } while Date() < end
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 0), .completed)
            app.terminate()
        }
    }

    /// Tapping the same card again after backing out must still open it. A
    /// NavigationLink kept its presented/highlighted state on the source card in
    /// some stacks, leaving that one card inert until a different link activated.
    func testTheSameCardOpensAgainAfterReturning() {
        launch()
        let card = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Continuing movie")
        ).firstMatch
        for attempt in 0..<3 {
            XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<3 where !card.isHittable { app.swipeUp() }
            card.tap()
            XCTAssertTrue(
                app.staticTexts["Movie-specific synopsis."].waitForExistence(timeout: 10),
                "Attempt \(attempt): \(app.debugDescription)"
            )
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(card.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        }
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
