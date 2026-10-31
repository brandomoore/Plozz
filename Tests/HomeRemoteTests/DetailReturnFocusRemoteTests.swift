import XCTest
import ObjectiveC.runtime

@MainActor
final class DetailReturnFocusRemoteTests: XCTestCase {
    func testSingleRelatedItemCannotBeSkippedForCast() throws {
        try checkRelatedEntry(arguments: ["--related-single"], hasRelated: true)
    }

    func testEmptyRelatedRowDoesNotBlockCastEntry() throws {
        try checkRelatedEntry(arguments: ["--related-empty"], hasRelated: false)
    }

    func testShortRelatedRowCannotBeSkippedForCast() throws {
        try checkRelatedEntry(arguments: [], hasRelated: true)
    }

    func testRapidPassThroughEpisodesPreservesTheBrowsedEpisode() throws {
        try checkRelatedEntry(arguments: [], hasRelated: true, passesThroughHero: true)
    }

    private func checkRelatedEntry(
        arguments: [String], hasRelated: Bool, passesThroughHero: Bool = false
    ) throws {
        continueAfterFailure = false
        for style in ["system", "highlight", "outlined"] {
            let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
            app.launchArguments = ["--episode-breadcrumb-fixture", "--series-navigation", "--\(style)"] + arguments
            app.launch()
            defer { app.terminate() }
            let play = app.buttons["detail-hero-play"]
            XCTAssertTrue(play.waitForExistence(timeout: 20))
            // Row navigation starts after the separately covered cinematic entrance.
            Thread.sleep(forTimeInterval: 2)
            let focus = NSPredicate(format: "hasFocus == true")
            XCTAssertEqual(XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: focus, object: play)], timeout: 10
            ), .completed)
            XCUIRemote.shared.press(.down)
            if app.buttons["Season 2"].hasFocus { XCUIRemote.shared.press(.down) }
            assertSeriesRowFocused("Fixture Episode", in: app)
            let nextRow = hasRelated ? "Related Show" : "Character"
            XCTAssertTrue(app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", nextRow)
            ).firstMatch.waitForExistence(timeout: 10))
            let focused = app.descendants(matching: .any).matching(focus).firstMatch
            let horizontalMoves = passesThroughHero ? [0, 0, 3, 0] : [0, 2, 1, 5]
            for (roundTrip, moves) in horizontalMoves.enumerated() {
                for _ in 0..<moves { XCUIRemote.shared.press(.right) }
                assertSeriesRowFocused("Fixture Episode", in: app)
                let episodeNumber = roundTrip < 2 ? 1 : 4
                let rememberedEpisode = "E\(episodeNumber) · Fixture Episode \(episodeNumber),"
                if passesThroughHero { assertSeriesRowFocused(rememberedEpisode, in: app) }
                XCUIRemote.shared.press(.down)
                assertSeriesRowFocused(nextRow, in: app)
                assertSeriesFocusVisible(focused, in: app)
                if passesThroughHero {
                    for _ in 0..<(roundTrip % 3) { XCUIRemote.shared.press(.right) }
                    XCUIRemote.shared.press(.up)
                    XCUIRemote.shared.press(.up)
                    XCUIRemote.shared.press(.up)
                    XCTAssertTrue(play.hasFocus, "Rapid Up must reach the hero.")
                    XCUIRemote.shared.press(.down)
                    if app.buttons["Season 2"].hasFocus { XCUIRemote.shared.press(.down) }
                    assertSeriesRowFocused(rememberedEpisode, in: app)
                    assertSeriesFocusVisible(focused, in: app)
                    continue
                }
                XCUIRemote.shared.press(.up)
                assertSeriesRowFocused("Fixture Episode", in: app)
                assertSeriesFocusVisible(focused, in: app)
            }
            if hasRelated {
                XCUIRemote.shared.press(.down)
                assertSeriesRowFocused("Related Show", in: app)
                XCUIRemote.shared.press(.down)
                assertSeriesRowFocused("Character", in: app)
                XCUIRemote.shared.press(.up)
                assertSeriesRowFocused("Related Show", in: app)
                assertSeriesFocusVisible(focused, in: app)
            }
        }
    }

    func testEpisodeRelatedDirectionsRevealTheFocusedRow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture", "--series-navigation"]
        app.launch()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2)
        let focus = NSPredicate(format: "hasFocus == true")
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: focus, object: play)], timeout: 10
        ), .completed)
        XCUIRemote.shared.press(.down)
        if app.buttons["Season 2"].hasFocus { XCUIRemote.shared.press(.down) }
        let focused = app.descendants(matching: .any).matching(focus).firstMatch
        assertSeriesRowFocused("Fixture Episode", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Related Show")
        ).firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            XCUIRemote.shared.press(.down)
            assertSeriesRowFocused("Related Show", in: app)
            assertSeriesFocusVisible(focused, in: app)
            XCUIRemote.shared.press(.up)
            assertSeriesRowFocused("Fixture Episode", in: app)
            assertSeriesFocusVisible(focused, in: app)
        }
    }

    private func assertSeriesFocusVisible(
        _ focused: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let visible = NSPredicate { _, _ in focused.exists && app.frame.contains(focused.frame) }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 2
        ), .completed, "The focused row must come fully onscreen.", file: file, line: line)
    }

    private func assertSeriesRowFocused(
        _ label: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label))
        let ownsFocus = matches.allElementsBoundByIndex.contains {
            $0.hasFocus || $0.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
        }
        if !ownsFocus {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "series-navigation-missing-\(label)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(ownsFocus, "Expected native focus in \(label)", file: file, line: line)
    }

    func testSequentialNativeLibraryDetailsNeverRetainADismissedPage() throws {
        try checkSequentialNativeDetails(waitForTrailer: false)
    }

    func testSequentialNativeLibraryTrailersBelongOnlyToTheCurrentDetail() throws {
        try checkSequentialNativeDetails(waitForTrailer: true)
    }

    private func checkSequentialNativeDetails(waitForTrailer: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--native-sidebar-home", "--library-detail-sequence"
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let routeDepth = app.staticTexts["detail-sequence-route-depth"]
        let pageDepth = app.staticTexts["detail-sequence-page-depth"]
        let trailerOwner = app.staticTexts["detail-sequence-trailer-owner"]
        let ready = NSPredicate { _, _ in
            app.descendants(matching: .any).matching(
                NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", "Fixture movie")
            ).firstMatch.exists
        }
        if app.buttons["Home"].firstMatch.hasFocus { XCUIRemote.shared.press(.select) }
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 3) != .completed {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10
        ), .completed)
        for visit in 0..<(waitForTrailer ? 4 : 8) {
            XCTAssertEqual(routeDepth.label, "0", "visit \(visit)")
            XCTAssertEqual(pageDepth.label, "0", "visit \(visit)")
            if visit > 0 { XCUIRemote.shared.press(visit.isMultiple(of: 2) ? .left : .right) }
            let card = app.descendants(matching: .any).matching(
                NSPredicate(format: "hasFocus == true AND label BEGINSWITH %@", "Fixture movie")
            ).firstMatch
            let title = card.label
            XCTAssertFalse(title.isEmpty)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Detail fixture \(title)"].waitForExistence(timeout: 10))
            XCTAssertEqual(routeDepth.label, "1")
            XCTAssertEqual(pageDepth.label, "1")
            if waitForTrailer {
                let index = try XCTUnwrap(title.split(separator: " ").last)
                let playing = NSPredicate { _, _ in trailerOwner.label == "home-movie-\(index)" }
                XCTAssertEqual(XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 8
                ), .completed, "Only the currently opened movie may own the trailer.")
            }
            if visit.isMultiple(of: 2) { Thread.sleep(forTimeInterval: 1.5) }
            XCUIRemote.shared.press(.menu)
            let returned = NSPredicate { _, _ in routeDepth.label == "0" && pageDepth.label == "0" }
            let result = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5
            )
            if result != .completed {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "stale-detail-after-visit-\(visit)"
                tree.lifetime = .keepAlways
                add(tree)
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "detail-return-visit-\(visit)"
                image.lifetime = .keepAlways
                add(image)
            }
            XCTAssertEqual(result, .completed, "Back must remove the real route, not only its picture.")
            XCTAssertEqual(trailerOwner.label, "none", "A library return must not keep the dismissed trailer.")
            assertFocused(title, in: app)
        }
    }

    func testRepeatedDetailVisitsReturnToTheSelectedHomeCard() {
        checkRepeatedDetailVisits(showcase: false)
    }

    func testShowcaseAcceptsDirectionsAfterReturningWithoutLosingPosition() {
        checkRepeatedDetailVisits(showcase: true)
    }

    func testTopTabsShowcaseKeepsRapidReturnLeftPressesInTheSameRow() throws {
        try checkRapidReturn(showcase: true)
    }

    func testTopTabsHeroKeepsRapidReturnLeftPressesInTheSameRow() throws {
        try checkRapidReturn(showcase: false)
    }

    func testPopulatedShowcaseKeepsRapidReturnLeftPressesInTheSameRow() throws {
        try checkRapidReturn(showcase: true, libraryRows: true)
    }

    func testProfilePopulatedShowcaseDetailReturns() throws {
        try checkRapidReturn(showcase: true, libraryRows: true, repetitions: 3)
    }

    private func checkRapidReturn(showcase: Bool, libraryRows: Bool = false, repetitions: Int = 1) throws {
        continueAfterFailure = false
        let attach = ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_ATTACH"] == "1"
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--top-bar-home", "--return-focus-trace"]
        if showcase { app.launchArguments.append("--immersive-home") }
        if libraryRows {
            app.launchArguments += ["--progressive-library-rows", "--populated-home-return"]
        }
        if attach {
            XCTAssertEqual(app.state, .runningForeground, "The profiling runner owns the running fixture.")
        } else {
            app.launch()
        }
        defer { if !attach { app.terminate() } }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let homeTab = app.buttons["top-navigation-home"]
        if homeTab.exists && homeTab.hasFocus { XCUIRemote.shared.press(.down) }
        if !showcase { XCUIRemote.shared.press(.down) }
        for _ in 0..<5 {
            if app.buttons["Fixture movie 0"].hasFocus { break }
            XCUIRemote.shared.press(.left)
        }
        assertFocused("Fixture movie 0", in: app)
        XCUIRemote.shared.press(.down)
        assertFocused("Fixture movie 24", in: app)
        if libraryRows {
            for index in [44, 64] {
                XCUIRemote.shared.press(.down)
                assertFocused("Fixture movie \(index)", in: app)
            }
        }
        let rowStart = libraryRows ? 64 : 24
        for _ in 0..<5 { XCUIRemote.shared.press(.right) }
        assertFocused("Fixture movie \(rowStart + 5)", in: app)
        for delay in libraryRows ? Array(repeating: 0.0, count: repetitions) : [0.15, 0.28, 0.4] {
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let title = focused.label
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Detail fixture \(title)"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            try withImmediateRemoteInput {
                print("PLZRETURN menu.begin epoch=\(Date().timeIntervalSince1970)")
                XCUIRemote.shared.press(.menu)
                print("PLZRETURN menu.end epoch=\(Date().timeIntervalSince1970)")
                Thread.sleep(forTimeInterval: delay)
                let started = ProcessInfo.processInfo.systemUptime
                for index in 0..<3 {
                    print("PLZRETURN left.begin index=\(index) epoch=\(Date().timeIntervalSince1970)")
                    XCUIRemote.shared.press(.left, forDuration: 0.02)
                    print("PLZRETURN left.end index=\(index) epoch=\(Date().timeIntervalSince1970)")
                }
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
            }
            let next = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(next.exists)
            let index = try XCTUnwrap(Int(next.label.split(separator: " ").last ?? ""), app.debugDescription)
            XCTAssertTrue((rowStart..<(rowStart + 20)).contains(index),
                          "Only Left was pressed; native focus must remain in the source row.")
            let sourceIndex = try XCTUnwrap(Int(title.split(separator: " ").last ?? ""))
            XCTAssertLessThanOrEqual(index, sourceIndex, "Return input cannot move focus to the right.")
            XCUIRemote.shared.press(.left)
            assertFocused("Fixture movie \(index - 1)", in: app)
            for _ in 0..<(sourceIndex - index + 1) { XCUIRemote.shared.press(.right) }
            assertFocused(title, in: app)
        }
    }

    private func withImmediateRemoteInput(_ action: () throws -> Void) throws {
        // Runner-only: XCTest's idle wait would turn a rapid burst into settled
        // navigation. Restore the original implementation even if a press fails.
        let process = try XCTUnwrap(NSClassFromString("XCUIApplicationProcess"))
        let selector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        let method = try XCTUnwrap(class_getInstanceMethod(process, selector))
        XCTAssertEqual(method_getNumberOfArguments(method), 4)
        guard method_getNumberOfArguments(method) == 4 else { return }
        let skip: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        let replacement = imp_implementationWithBlock(skip)
        let original = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        try action()
    }

    private func checkRepeatedDetailVisits(showcase: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--pinned-home"]
        if showcase { app.launchArguments.append("--immersive-home") }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        if showcase {
            assertFocused("Fixture movie 0", in: app)
        } else {
            let hero = app.buttons["home-hero-action-row"]
            XCTAssertTrue(hero.waitForExistence(timeout: 20))
            XCTAssertTrue(hero.hasFocus)
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(app.buttons["Navigation"].isEnabled, "Navigation must start closed while Home receives focus.")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 1)
        assertFocused("Fixture movie 24", in: app)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        assertFocused("Fixture movie 26", in: app)
        for visit in 0..<5 {
            if visit == 3 { XCUIRemote.shared.press(.left) }
            let index = visit < 3 ? 26 : 25
            let title = "Fixture movie \(index)"
            assertFocused(title, in: app)
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let before = focused.frame
            XCUIRemote.shared.press(.select)
            let opened = app.staticTexts["Detail fixture \(title)"].waitForExistence(timeout: 10)
            if !opened {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "failed-detail-open"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(opened)
            Thread.sleep(forTimeInterval: 2)
            XCUIRemote.shared.press(.menu)
            assertFocused(title, in: app)
            let returned = focused.frame
            XCTAssertEqual(returned.minX, before.minX, accuracy: 2)
            XCTAssertEqual(returned.minY, before.minY, accuracy: 2)
            XCTAssertEqual(returned.width, before.width, accuracy: 2)
            XCTAssertEqual(returned.height, before.height, accuracy: 2)
            XCUIRemote.shared.press(.right)
            assertFocused("Fixture movie \(index + 1)", in: app)
            XCUIRemote.shared.press(.left)
            assertFocused(title, in: app)
            XCTAssertFalse(app.buttons["Navigation"].isEnabled)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-focus-after-repeated-detail-visits"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertFocused(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let predicate = NSPredicate { _, _ in
            focused.exists && (focused.label == title || focused.staticTexts[title].exists)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "failed-return-focus-\(title)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected focus on \(title)", file: file, line: line)
    }
}
