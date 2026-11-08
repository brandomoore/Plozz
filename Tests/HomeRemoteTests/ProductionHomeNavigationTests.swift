import XCTest

@MainActor
final class ProductionHomeNavigationTests: XCTestCase {
    func testColdLaunchEntersFirstItemAcrossNavigationStylesAndHomeLayouts() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        for navigation in ["--top-bar-home", "--pinned-home", "--native-sidebar-home"] {
            for layout in [[], ["--hero-showcase-home"], ["--immersive-home"], ["--hero-disabled-home"]] {
                for delayed in [false, true] {
                    let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
                    app.launchArguments = ["--production-home-fixture", navigation] + layout
                        + (delayed ? ["--slow-home-load"] : [])
                    app.launch()
                    defer { app.terminate() }
                    let first = app.buttons[layout.contains("--immersive-home") || layout.contains("--hero-disabled-home")
                        ? "Fixture movie 0" : "home-hero-action-row"]
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in first.exists && first.hasFocus }, object: nil
                    )], timeout: 30), .completed, "\(navigation) \(layout) delayed=\(delayed)\n\(app.debugDescription)")
                }
            }
        }
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    func testShowAllPagesStayNestedAcrossNavigationStyles() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        for navigation in ["--top-bar-home", "--pinned-home", "--native-sidebar-home"] {
            for watchlist in [false, true] {
                let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
                app.launchArguments = [
                    "--production-home-fixture", "--home-browse-fixture",
                    "--hero-disabled-home", "--real-root-pages", "--slow-home-browse", navigation
                ] + (watchlist ? ["--home-browse-watchlist"] : [])
                app.launch()
                defer { app.terminate() }
                XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
                XCTAssertTrue(app.buttons[navigation == "--top-bar-home" ? "top-navigation-home" : "Home"].exists,
                              app.debugDescription)
                let action = app.buttons["See all"].firstMatch
                for _ in 0..<30 {
                    if action.exists && action.hasFocus { break }
                    XCUIRemote.shared.press(.right)
                }
                XCTAssertTrue(action.exists, app.debugDescription)
                XCTAssertTrue(action.hasFocus, app.debugDescription)
                captureNavigation("See all before entry \(navigation) watchlist=\(watchlist)", app: app)
                let sourceFrame = action.frame
                XCTAssertLessThanOrEqual(sourceFrame.maxX, app.frame.maxX - 24,
                                         "The focused See all card needs trailing clearance: \(navigation) \(sourceFrame)")
                XCUIRemote.shared.press(.select)

                let title = app.staticTexts[watchlist ? "watchlist-title" : "home-row-browser-title"]
                let depth = app.staticTexts["home-detail-depth-probe"]
                XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
                waitForLabel("1", on: depth)
                assertGlobalNavigationHidden(app, navigation: navigation)

                let first = app.buttons[watchlist ? "Fixture movie 0" : "Fixture movie 24"]
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in first.exists && first.hasFocus }, object: nil
                )], timeout: 10), .completed, "Entry must focus the first item without a Down press: \(app.debugDescription)")
                XCUIRemote.shared.press(.right)
                let focusedMovie = app.buttons.matching(NSPredicate(
                    format: "label BEGINSWITH %@ AND hasFocus == true", "Fixture movie "
                )).firstMatch
                XCTAssertTrue(focusedMovie.exists, app.debugDescription)
                let movie = focusedMovie.label
                XCTAssertNotEqual(movie, first.label, "Ordinary grid navigation must be available after entry")
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.staticTexts["Detail fixture \(movie)"].waitForExistence(timeout: 15))
                waitForLabel("2", on: depth)
                XCUIRemote.shared.press(.menu)
                XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
                waitForLabel("1", on: depth)
                assertGlobalNavigationHidden(app, navigation: navigation)
                XCTAssertTrue(app.buttons[movie].hasFocus, "Returning from details must not reset grid focus")

                XCUIRemote.shared.press(.up)
                let filter = app.buttons[watchlist ? "watchlist-filter-menu" : "home-row-filter-menu"]
                let sort = app.buttons[watchlist ? "watchlist-sort-menu" : "home-row-sort-menu"]
                XCTAssertTrue(filter.isEnabled && sort.isEnabled)
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        [filter, sort].contains {
                            $0.hasFocus || $0.descendants(matching: .any)
                                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
                        }
                    }, object: nil
                )], timeout: 3), .completed, "Query controls remain reachable after grid entry: \(app.debugDescription)")
                XCUIRemote.shared.press(.select)
                XCUIRemote.shared.press(.menu)
                waitForLabel("1", on: depth)
                XCTAssertTrue(title.exists, "Back dismisses a native menu before popping the browser")

                XCUIRemote.shared.press(.menu)
                waitForLabel("0", on: depth)
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in action.exists && action.hasFocus }, object: nil
                )], timeout: 5), .completed, app.debugDescription)
                captureNavigation("See all after return \(navigation) watchlist=\(watchlist)", app: app)
                let returnedFrame = action.frame
                XCTAssertLessThanOrEqual(returnedFrame.maxX, app.frame.maxX - 24)
                XCTAssertEqual(returnedFrame.minX, sourceFrame.minX, accuracy: 1,
                               "Before \(sourceFrame); after \(returnedFrame)")
                XCTAssertEqual(returnedFrame.minY, sourceFrame.minY, accuracy: 1,
                               "Before \(sourceFrame); after \(returnedFrame)")
                XCTAssertFalse(title.exists)
            }
        }
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    private func assertGlobalNavigationHidden(_ app: XCUIApplication, navigation: String) {
        let controls = navigation == "--top-bar-home"
            ? [app.buttons["top-navigation-home"], app.buttons["top-navigation-search"]]
            : [app.buttons["Home"], app.buttons["Search"], app.buttons["Settings"]]
        XCTAssertFalse(controls.contains(where: \.isHittable),
                       "A nested browser must not expose global navigation: \(app.debugDescription)")
    }

    func testEmptyAndFailedBrowsersKeepControlsAndBackAvailable() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        for outcome in ["--empty-home-browse", "--failed-home-browse"] {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
            app.launchArguments = [
                "--production-home-fixture", "--home-browse-fixture", "--hero-disabled-home",
                "--top-bar-home", "--slow-home-browse", outcome
            ]
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
            let action = app.buttons["See all"].firstMatch
            for _ in 0..<30 {
                if action.exists && action.hasFocus { break }
                XCUIRemote.shared.press(.right)
            }
            XCTAssertTrue(action.hasFocus, app.debugDescription)
            XCUIRemote.shared.press(.select)
            let outcomeView = outcome == "--empty-home-browse"
                ? app.staticTexts["No titles to show"] : app.buttons["Retry"]
            XCTAssertTrue(outcomeView.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.buttons["home-row-filter-menu"].isEnabled)
            XCTAssertTrue(app.buttons["home-row-sort-menu"].isEnabled)
            XCUIRemote.shared.press(.menu)
            waitForLabel("0", on: app.staticTexts["home-detail-depth-probe"])
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in action.exists && action.hasFocus }, object: nil
            )], timeout: 5), .completed, app.debugDescription)
        }
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    func testHorizontalHomeWatchlistAndSearchForegroundClearance() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--top-bar-home", "--real-root-pages"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let bar = app.descendants(matching: .any)["top-navigation"]
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in hero.hasFocus }, object: nil
        )], timeout: 5), .completed, app.debugDescription)
        XCTAssertGreaterThanOrEqual(hero.frame.minY, bar.frame.maxY + 16)
        captureNavigation("Compact navigation over Home", app: app)
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.right)
        let title = app.staticTexts["watchlist-title"]
        XCTAssertFalse(title.exists, "Highlighting Watchlist must leave Home open.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(title.frame.minY, bar.frame.maxY + 16)
        let initialTitleY = title.frame.minY
        XCTAssertTrue(app.buttons["watchlist-filter-menu"].exists)
        XCTAssertTrue(app.buttons["watchlist-sort-menu"].exists)
        let first = app.buttons["Fixture movie 0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(first.frame.minY, bar.frame.maxY + 16)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in first.hasFocus }, object: nil
        )], timeout: 5), .completed, app.debugDescription)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["top-navigation-watchlist"].hasFocus)
        captureNavigation("Watchlist foreground clears navigation", app: app)
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in first.hasFocus }, object: nil
        )], timeout: 5), .completed, app.debugDescription)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !app.buttons["top-navigation-watchlist"].isHittable }, object: nil
        )], timeout: 5), .completed, "Watchlist scrolling must carry the top bar offscreen.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["top-navigation-watchlist"].hasFocus)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(title.frame.minY - initialTitleY) < 1 }, object: nil
        )], timeout: 5), .completed, "Back must restore both Watchlist content and navigation to the top.")
        captureNavigation("Watchlist navigation after scrolling", app: app)
        XCUIRemote.shared.press(.right)
        let search = app.searchFields.firstMatch
        XCTAssertFalse(search.exists, "Highlighting Search must leave Watchlist open.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(search.frame.minY.rounded(), bar.frame.maxY + 16)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !app.buttons["top-navigation-search"].hasFocus }, object: nil
        )], timeout: 5), .completed, app.debugDescription)
        captureNavigation("Search foreground clears navigation", app: app)
        #else
        throw XCTSkip("Uses an owned simulator with local fixture data.")
        #endif
    }

    private func captureNavigation(_ name: String, app: XCUIApplication) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testContinueWatchingPlayPauseAlwaysPlaysWhileSelectFollowsPreference() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let configurations: [[String]] = [
            ["--hero-disabled-home", "--focus-style=outline", "--episode-home-artwork"],
            [],
            ["--immersive-home", "--continue-watching-posters"],
            ["--hero-disabled-home", "--framed-cards", "--focus-style=highlight"]
        ]
        for configuration in configurations {
            for opensDetails in [false, true] {
                let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
                app.launchArguments = [
                    "--production-home-fixture", "--continue-watching-action-probe"
                ] + configuration + (opensDetails ? ["--continue-watching-open-details"] : [])
                app.launch()
                defer { app.terminate() }
                XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
                XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 20))
                let first = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ AND hasFocus == true", "Fixture movie 0")).firstMatch
                if configuration.isEmpty { XCUIRemote.shared.press(.down) }
                XCTAssertTrue(first.waitForExistence(timeout: 10))

                let playback = app.staticTexts["home-playback-probe"]
                let depth = app.staticTexts["home-detail-depth-probe"]
                XCUIRemote.shared.press(.playPause)
                waitForLabel("1:home-movie-0", on: playback)
                XCTAssertEqual(depth.label, "0", "Play/Pause must never push details.")
                XCTAssertTrue(first.hasFocus)

                XCUIRemote.shared.press(.right)
                let second = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ AND hasFocus == true", "Fixture movie 1")).firstMatch
                XCTAssertTrue(second.waitForExistence(timeout: 10))
                XCUIRemote.shared.press(.playPause)
                waitForLabel("2:home-movie-1", on: playback)
                XCTAssertEqual(depth.label, "0", "Play/Pause must use the focused card, not the hero or previous card.")

                XCUIRemote.shared.press(.select)
                if opensDetails {
                    waitForLabel("1", on: depth)
                    XCTAssertTrue(app.staticTexts["Detail fixture Fixture movie 1"].waitForExistence(timeout: 15))
                    XCTAssertEqual(playback.label, "2:home-movie-1", "Opening details must not also play.")
                } else {
                    waitForLabel("3:home-movie-1", on: playback)
                    XCTAssertEqual(depth.label, "0", "The saved Play action must not open details.")
                }
            }
        }
        #else
        throw XCTSkip("Uses an isolated simulator with local fixture data.")
        #endif
    }

    private func waitForLabel(
        _ label: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [updated], timeout: 10)
        if result != .completed {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "continue-watching-command-failure"
            tree.lifetime = .keepAlways
            add(tree)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    func testDefaultContinueWatchingOpensSeriesWithSelectedEpisodeAcrossHomeLayouts() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        for layout in [["--hero-disabled-home"], [], ["--immersive-home"], ["--hero-showcase-home"]] {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
            app.launchArguments = [
                "--production-home-fixture", "--continue-watching-action-probe",
                "--continue-watching-use-default", "--continue-watching-episode"
            ] + layout
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
            let episode = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ AND hasFocus == true", "Fixture show")
            ).firstMatch
            if layout.isEmpty || layout.contains("--hero-showcase-home") {
                for _ in 0..<3 {
                    if episode.waitForExistence(timeout: 3) { break }
                    XCUIRemote.shared.press(.down)
                }
            }
            XCTAssertTrue(episode.waitForExistence(timeout: 10), app.debugDescription)
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.select)
            waitForLabel("browse", on: app.staticTexts["home-detail-route-probe"])
            XCTAssertTrue(app.staticTexts["Episode-specific synopsis for fixture 1."].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["Season 1"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(app.staticTexts["home-playback-probe"].label, "0:")
        }
        #else
        throw XCTSkip("Uses an isolated simulator with local fixture data.")
        #endif
    }

    func testNavigateProductionHomeWithNativeCards() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let attach = ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_ATTACH"] == "1"
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        if attach {
            XCTAssertEqual(app.state, .runningForeground, "The profiling runner must own the already-running fixture.")
        } else {
            app.launchArguments = ["--production-home-fixture"]
            app.launchEnvironment["PLZPERF_ANIMATIONS"] = "1"
            app.launch()
        }
        defer { if !attach { app.terminate() } }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        XCTAssertTrue(hero.hasFocus)
        print("PRODUCTION_HOME_READY \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 8)
        for cycle in 0..<3 {
            print("PRODUCTION_HOME_CYCLE \(cycle) \(Date().timeIntervalSince1970)")
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(hero.hasFocus)
            for _ in 0..<4 {
                XCUIRemote.shared.press(.right)
                Thread.sleep(forTimeInterval: 0.2)
            }
            for _ in 0..<4 {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: 0.2)
            }
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 1)
            XCUIRemote.shared.press(.up)
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(hero.hasFocus)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "production-home-after-navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #else
        throw XCTSkip("This uses an isolated simulator with local fixture data.")
        #endif
    }
}
