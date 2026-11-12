import XCTest

#if os(iOS)
import UIKit
#endif

@MainActor
final class LiveTVCategorySearchInteractionTests: XCTestCase {
    #if os(tvOS)
    func testPinnedNavigationWaitsForCategoryEntryAndStillAcceptsBack() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--navigation-fixture", "--navigation-live-tv", "--navigation-short", "--navigation-guide",
            "--category-search-guide-first", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        defer { app.terminate() }
        let categories = app.buttons["live-tv-sidebar-category-all"]
        let navigation = app.buttons["Navigation"]
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 15))

        for _ in 0..<3 {
            let guide = NSPredicate { _, _ in
                self.containsFocus(self.channel("Arena One", in: app))
                    || self.containsFocus(app.buttons["Matchday Live"].firstMatch)
            }
            XCTAssertEqual(XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: guide, object: nil)], timeout: 5
            ), .completed, app.debugDescription)
            // Move from programme content to the channel's leading control first.
            if containsFocus(app.buttons["Matchday Live"].firstMatch) {
                XCUIRemote.shared.press(.left)
            }
            XCUIRemote.shared.press(.left, forDuration: 0.4)
            XCTAssertTrue(categories.wait(for: \.hasFocus, toEqual: true, timeout: 5), app.debugDescription)
            XCTAssertFalse(navigation.isEnabled, "Opening categories must not expand pinned navigation.")
            capture("pinned-navigation-stays-collapsed-at-categories", in: app)
            XCUIRemote.shared.press(.left)
            XCTAssertTrue(navigation.wait(for: \.isEnabled, toEqual: true, timeout: 5))
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(categories.wait(for: \.hasFocus, toEqual: true, timeout: 5))
            XCUIRemote.shared.press(.right)
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-tv-search"].wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(navigation.wait(for: \.isEnabled, toEqual: true, timeout: 5),
                      "Back must retain the guide-to-controls-to-navigation path.")
    }
    #endif

    #if os(iOS)
    func testToolbarSearchSpansCategoriesAndRestoresThePreviousCategory() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let search = app.navigationBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(searchField(in: app).exists)
        capture("live-tv-collapsed-toolbar-search", in: app)
        let sidebar = app.buttons["live-tv-sidebar-category-Sports"]
        if sidebar.exists { sidebar.tap() }
        else { app.buttons["live-tv-browse-category-Sports"].tap() }
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(channel("Daily News", in: app).exists)
        search.tap()
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("News\n")
        let program = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "News Today")).firstMatch
        XCTAssertTrue(program.waitForExistence(timeout: 10))
        XCTAssertTrue(channel("Daily News", in: app).exists)
        XCTAssertFalse(sidebar.exists)
        XCTAssertFalse(app.buttons["live-tv-category"].exists)
        XCTAssertFalse(app.buttons["live-tv-search-filter"].exists)
        capture("live-tv-expanded-toolbar-search", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue((field.value as? String)?.contains("News") == true)
        XCTAssertTrue(program.waitForExistence(timeout: 5))
        XCTAssertFalse(sidebar.exists)
        capture("live-tv-expanded-toolbar-search-landscape", in: app)
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(channel("Daily News", in: app).exists)
        if sidebar.exists { XCTAssertTrue(sidebar.isSelected) }
        else { XCTAssertEqual(app.buttons["live-tv-category"].value as? String, "Sports") }
        capture("live-tv-restored-category-guide", in: app)
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("News\n")
        XCTAssertTrue(program.waitForExistence(timeout: 10))
        channel("Daily News", in: app).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(channel("Daily News", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Arena One", in: app).exists)
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, "Preview")
    }

    func testSearchCombinesChannelsAndProgramsWithoutExtraControls() {
        let app = launchSearch(guideFirst: true)
        defer { app.terminate() }
        let field = searchField(in: app)
        field.typeText("News\n")
        let news = channel("Daily News", in: app)
        let program = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "News Today")).firstMatch
        XCTAssertTrue(news.waitForExistence(timeout: 10))
        XCTAssertTrue(program.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["live-tv-search-filter"].exists)
        XCTAssertFalse(app.segmentedControls["live-tv-search-scope"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@", "^[0-9]+ channels?$"
        )).firstMatch.exists)
        capture("live-tv-search-all-results", in: app)

        XCTAssertTrue((field.value as? String)?.contains("News") == true)
        news.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.label, "Daily News")
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    func testSearchClearKeepsEditingAndSeparateCloseRestoresBrowsing() {
        let app = launch(lightAppearance: true)
        defer { app.terminate() }
        let search = app.navigationBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("News")
        let close = app.navigationBars.buttons["Close"]
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(app.navigationBars.buttons.matching(identifier: "Close").count, 1)
        XCTAssertGreaterThanOrEqual(close.frame.minX - field.frame.maxX, 8)
        XCTAssertEqual(close.frame.midY, field.frame.midY, accuracy: 2)
        capture("live-tv-search-separate-close", in: app)
        let clear = field.buttons["Clear search"]
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        capture("live-tv-search-after-clear", in: app)
        XCTAssertTrue(field.exists, "Clearing text must not close search. \(app.debugDescription)")
        XCTAssertEqual(field.value as? String, "Search")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        close.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(app.navigationBars.buttons["live-tv-more"].isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "An empty search must still close.")
    }

    func testUnifiedSearchFindsProgramsWithoutChannelNameMatches() {
        let app = launchSearch(guideFirst: true)
        defer { app.terminate() }
        let field = searchField(in: app)
        field.typeText("Championship\n")
        let program = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Championship Highlights"
        )).firstMatch
        XCTAssertTrue(program.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["No matching channels"].exists)
        program.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Program details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stadium Live"].exists)
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
        capture("live-tv-search-program-details", in: app)
    }

    func testUnifiedSearchKeepsTheSelectedSourceBoundary() {
        let app = launch(multipleSources: true)
        defer { app.terminate() }
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        source.tap()
        app.buttons["Local TV"].tap()
        app.navigationBars.buttons["Search"].tap()
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("News\n")
        XCTAssertTrue(app.staticTexts["No matching channels"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No matching programs in the retained guide."].waitForExistence(timeout: 10))
        XCTAssertFalse(channel("Daily News", in: app).exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "News Today")).firstMatch.exists)
    }

    func testDirectoryProgramSearchPlaybackRestoresUnfilteredGuide() {
        let app = launchSearch()
        defer { app.terminate() }
        searchField(in: app).typeText("Championship\n")
        let program = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Championship Highlights"
        )).firstMatch
        XCTAssertTrue(program.waitForExistence(timeout: 10))
        program.tap()
        let watch = app.buttons["Watch channel"]
        XCTAssertTrue(watch.waitForExistence(timeout: 5))
        watch.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(preview.label, "Stadium Live")
        XCTAssertEqual(preview.value as? String, "Fullscreen")
        let next = app.buttons["live-channel-next"]
        if !next.isHittable {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)).tap()
        }
        next.tap()
        XCTAssertTrue(preview.wait(for: \.label, toEqual: "World Arena", timeout: 10))
        let close = app.buttons["live-channel-exit-fullscreen"]
        if !close.isHittable {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)).tap()
        }
        close.tap()
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Daily News", in: app).exists)
        XCTAssertFalse(searchField(in: app).exists)
    }

    func testCategoryContentScrollsBehindTheNativeHeader() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native scroll-edge underlap requires iOS 26.") }
        let app = launch(scrollContent: true)
        defer { app.terminate() }
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        let grid = app.scrollViews["live-tv-category-grid"]
        guard grid.exists else { throw XCTSkip("The category directory requires a narrow layout.") }
        let scroll = grid
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        capture("live-tv-categories-before-scroll", in: app)
        XCTAssertLessThan(scroll.frame.minY, source.frame.minY,
                          "The scroll viewport must extend behind the toolbar, not stop below it.")
        let sourceFrame = source.frame
        let before = app.screenshot()
        scroll.swipeUp()
        capture("live-tv-categories-behind-header", in: app)
        try assertHeaderBackdropChanges(in: app, scroll: scroll, header: source, before: before)
        XCTAssertEqual(source.frame, sourceFrame)
        XCTAssertTrue(source.isHittable)
        let rows = scroll.buttons.allElementsBoundByIndex
        XCTAssertTrue(rows.contains { $0.frame.intersects(source.frame) },
                      "Scrolled category content must reach the header, not just report a larger viewport.")
        source.tap()
        XCTAssertTrue(app.buttons["live-tv-add-source"].waitForExistence(timeout: 5))
    }

    func testSearchResultsScrollBehindTheNativeHeader() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native scroll-edge underlap requires iOS 26.") }
        let app = launch(guideFirst: true, scrollContent: true)
        defer { app.terminate() }
        XCTAssertTrue(channel("Channel 01", in: app).waitForExistence(timeout: 15))
        app.navigationBars.buttons["Search"].tap()
        let field = searchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Channel\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let scroll = app.scrollViews["live-tv-search-results"]
        let close = app.navigationBars.buttons["Close"]
        XCTAssertLessThan(scroll.frame.minY, close.frame.minY)
        let before = app.screenshot()
        scroll.swipeUp()
        capture("live-tv-search-behind-header", in: app)
        try assertHeaderBackdropChanges(in: app, scroll: scroll, header: close, before: before)
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(field.isHittable)
        close.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live-tv-category"].isHittable
                      || app.buttons["live-tv-sidebar-category-all"].isHittable)
    }

    func testChannelAndProgrammeTapsStartTheTopPreviewWithoutOpeningFullscreen() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(guideFirst: true)
        defer { app.terminate() }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15), app.debugDescription)
        let preview = app.otherElements["category-search-playback"]
        XCTAssertFalse(preview.exists)
        arena.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(preview.label, "Arena One")
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ), app.staticTexts["category-preview-frame"].label)
        XCTAssertTrue(channel("Daily News", in: app).exists, "The guide must stay mounted below the preview.")
        let filters = app.buttons["live-tv-more"].frame
        capture("live-tv-preview-toolbar-clearance", in: app)
        let frame = videoFrame(in: app)
        XCTAssertTrue(
            abs(frame.minY - filters.maxY - 8) <= 2 || frame.maxX <= filters.minX,
            "The video must sit 8 pt below a horizontal toolbar or clear a vertical toolbar. "
                + "Video: \(frame); More: \(filters); "
                + "Category: \(app.buttons["live-tv-category"].frame)"
        )
        XCTAssertFalse(app.buttons["Watch channel"].exists)
        let programme = app.buttons["Championship Highlights"].firstMatch
        XCTAssertTrue(programme.waitForExistence(timeout: 5))
        programme.tap()
        let tuned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Stadium Live"), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [tuned], timeout: 10), .completed)
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertTrue(channel("Arena One", in: app).isHittable)
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ), app.staticTexts["category-preview-frame"].label)
        let fullscreen = app.buttons["live-channel-fullscreen"]
        if !fullscreen.isHittable {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)).tap()
        }
        let playPause = app.buttons["live-channel-play-pause"]
        XCTAssertTrue(playPause.exists)
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        capture("channel-tap-starts-top-preview", in: app)
        let loads = app.staticTexts["category-preview-loads"].label
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["category-preview-expands"].wait(for: \.label, toEqual: "Expands: 1", timeout: 5))
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Fullscreen"), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads, "Fullscreen must not reload the stream.")
        XCTAssertFalse(channel("Arena One", in: app).isHittable)
        capture("live-preview-fullscreen", in: app)
        let collapse = app.buttons["live-channel-exit-fullscreen"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live-channel-close"].exists, "Keep the top-left close action too.")
        collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Preview", preview: preview)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)
    }

    func testPreviewFullscreenRoundTripWithAutomaticRotation() {
        verifyFullscreenRoundTrip(orientation: "auto")
    }

    func testLightPreviewReflectionKeepsDarkPlayerControlsAndContinuousPlayback() {
        let app = launch(guideFirst: true, lightAppearance: true)
        defer { app.terminate() }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ))
        let playPause = app.buttons["live-channel-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        capture("light-preview-reflection", in: app)
        let loads = app.staticTexts["category-preview-loads"].label
        let fullscreen = app.buttons["live-channel-fullscreen"]
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Fullscreen", preview: preview)
        capture("light-preview-fullscreen", in: app)
        let close = app.buttons["live-channel-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Preview", preview: preview)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)
        XCTAssertTrue(arena.isHittable)
        channel("Daily News", in: app).tap()
        XCTAssertTrue(app.staticTexts["category-preview-loads"].wait(
            for: \.label, toEqual: "Loads: 2", timeout: 10
        ))
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ))
        XCTAssertEqual(preview.label, "Daily News")
        XCTAssertEqual(preview.value as? String, "Preview")
        capture("light-preview-retuned", in: app)
    }

    func testLightPreviewReflectionWithDarkVideo() {
        let app = launch(guideFirst: true, lightAppearance: true, dimVideo: true)
        defer { app.terminate() }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        arena.tap()
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ))
        let playPause = app.buttons["live-channel-play-pause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        playPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        capture("light-preview-dark-video", in: app)
    }

    func testFullscreenControlsAndStatusBarAutoHideAndReturnTogether() {
        let app = launch(guideFirst: true)
        defer { app.terminate() }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(
            for: \.label, toEqual: "Frame: ready", timeout: 10
        ))
        let fullscreen = app.buttons["live-channel-fullscreen"]
        if !fullscreen.isHittable {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)).tap()
        }
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Fullscreen", preview: preview)
        let loads = app.staticTexts["category-preview-loads"].label
        let close = app.buttons["live-channel-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture("fullscreen-controls-visible", in: app)
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.statusBars.firstMatch.waitForNonExistence(timeout: 5))
        capture("fullscreen-controls-hidden", in: app)
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture("fullscreen-controls-revealed", in: app)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Preview", preview: preview)
        XCTAssertTrue(arena.isHittable)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)
        capture("fullscreen-returned-to-preview", in: app)
    }

    func testPhoneAutoRotationExpandsPreviewAndClosingRequiresUprightBeforeReopening() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        XCUIDevice.shared.orientation = .portrait
        let app = launch(guideFirst: true)
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        let browsingRotates = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        browsingRotates.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [browsingRotates], timeout: 1), .completed)
        XCUIDevice.shared.orientation = .portrait
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let engineID = app.staticTexts["category-preview-engine"].label
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForPresentation("Fullscreen", preview: preview)
        XCTAssertGreaterThan(preview.frame.width, preview.frame.height)
        XCUIDevice.shared.orientation = .portrait
        waitForPresentation("Preview", preview: preview)
        XCTAssertTrue(arena.isHittable)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForPresentation("Fullscreen", preview: preview)
        let close = app.buttons["live-channel-close"]
        if !close.exists { preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Preview", preview: preview)
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        XCUIDevice.shared.orientation = .landscapeRight
        let reopens = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Fullscreen"), object: preview
        )
        reopens.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopens], timeout: 1), .completed)
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForPresentation("Fullscreen", preview: preview)
        XCTAssertEqual(app.staticTexts["category-preview-engine"].label, engineID)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, "Loads: 1")
        capture("iphone-automatic-live-fullscreen", in: app)
    }

    func testWideSidebarStaysFullHeightBesideVideoPreview() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "Requires a wide iPad sidebar.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(guideFirst: true)
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let search = app.navigationBars.buttons["Search"]
        let category = app.buttons["live-tv-sidebar-category-all"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        let categoryFrame = category.frame
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 5))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(category.frame.minY - categoryFrame.minY) < 1
                && arena.frame.minY >= self.videoFrame(in: app).maxY
                && self.videoFrame(in: app).minX >= category.frame.maxX
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        XCTAssertEqual(category.frame.minY, categoryFrame.minY, accuracy: 1)
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(category.isHittable)
        capture("ipad-full-height-sidebar-preview", in: app)
        search.tap()
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 5))
    }

    func testPreviewFullscreenRoundTripWithPortraitPreference() {
        verifyFullscreenRoundTrip(orientation: "portrait")
    }

    func testPreviewFullscreenRoundTripWithLandscapePreference() {
        verifyFullscreenRoundTrip(orientation: "landscape")
    }

    private func verifyFullscreenRoundTrip(orientation: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(guideFirst: true, orientation: orientation)
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let engineID = app.staticTexts["category-preview-engine"].label
        let fullscreen = app.buttons["live-channel-fullscreen"]
        if !fullscreen.exists {
            preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)).tap()
        }
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Fullscreen", preview: preview)
        assertLandscape(orientation == "landscape", preview: preview)
        XCTAssertEqual(app.staticTexts["category-preview-engine"].label, engineID)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, "Loads: 1")
        capture("fullscreen-\(orientation)", in: app)

        if orientation != "landscape" {
            XCUIDevice.shared.orientation = .landscapeLeft
            assertLandscape(orientation == "auto", preview: preview)
            XCTAssertEqual(app.staticTexts["category-preview-engine"].label, engineID)
            XCTAssertEqual(app.staticTexts["category-preview-loads"].label, "Loads: 1")
            XCUIDevice.shared.orientation = .portrait
            assertLandscape(false, preview: preview)
        }

        let close = app.buttons["live-channel-close"]
        let background = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        if close.exists {
            background.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        }
        background.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForPresentation("Preview", preview: preview)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
                && abs(self.videoFrame(in: app).minY - app.buttons["live-tv-more"].frame.maxY - 8) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["category-preview-engine"].label, engineID)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, "Loads: 1")
        XCTAssertTrue(arena.isHittable)
        capture("returned-preview-\(orientation)", in: app)
    }

    private func assertLandscape(_ landscape: Bool, preview: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            landscape ? preview.frame.width > preview.frame.height : preview.frame.height > preview.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func waitForPresentation(_ value: String, preview: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    func testChannelSearchSelectionClosesSearchAndStartsVisiblePreview() {
        let app = launchSearch(guideFirst: true)
        defer { app.terminate() }
        let field = searchField(in: app)
        field.typeText("Daily")
        let news = channel("Daily News", in: app)
        XCTAssertTrue(news.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
        field.typeText("\n")
        news.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(preview.label, "Daily News")
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertEqual(videoFrame(in: app).minY - app.buttons["live-tv-more"].frame.maxY, 8, accuracy: 2)
        XCTAssertTrue(channel("Arena One", in: app).isHittable)
        capture("channel-search-starts-top-preview", in: app)
    }

    func testTopPreviewTogglesSharedControlsAndPausesWithoutOpeningFullscreen() {
        let app = launch(guideFirst: true)
        defer { app.terminate() }
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 15))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        let fullscreen = app.buttons["live-channel-fullscreen"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let background = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65))
        if !fullscreen.isHittable { background.tap() }
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        app.buttons["live-channel-play-pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Preview")
        let play = app.buttons["live-channel-play-pause"]
        let previous = app.buttons["live-channel-previous"]
        let next = app.buttons["live-channel-next"]
        XCTAssertGreaterThan(play.frame.height, previous.frame.height)
        for control in [play, previous, next] {
            XCTAssertEqual(control.frame.midY, videoFrame(in: app).midY, accuracy: 2)
        }
        background.tap()
        XCTAssertTrue(fullscreen.waitForNonExistence(timeout: 5))
        background.tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertTrue(channel("Daily News", in: app).isHittable)
    }

    func testNativeToolbarGroupsSearchBeforeMoreAndMovesSettingsIntoTheMenu() {
        let app = launch()
        defer { app.terminate() }
        let profile = app.navigationBars.buttons["live-tv-profile"]
        let more = app.navigationBars.buttons["live-tv-more"]
        let search = app.navigationBars.buttons["Search"]
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(profile.exists)
        XCTAssertTrue(more.exists, app.debugDescription)
        XCTAssertTrue(source.isHittable)
        XCTAssertEqual(source.value as? String, "All")
        XCTAssertEqual(more.frame.midY, search.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(search.frame.maxX, more.frame.minX)
        XCTAssertLessThanOrEqual(more.frame.minX - search.frame.maxX, 16)
        for button in [search, more] {
            XCTAssertGreaterThanOrEqual(button.frame.height, 32)
            XCTAssertLessThanOrEqual(button.frame.height, 48)
        }
        XCTAssertFalse(app.navigationBars.buttons["live-tv-filters"].exists)
        capture("live-tv-grouped-root-header", in: app)
        openBrowseAction("live-tv-filters", in: app)
        let close = app.buttons["live-tv-close-sheet"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        openBrowseAction("live-tv-settings", in: app)
        XCTAssertTrue(app.staticTexts["category-search-profile-settings"].waitForExistence(timeout: 5))
    }

    func testGuideSeparatesBackAndCategoryAndRepeatsGroupedActions() {
        let app = launch(guideFirst: true)
        defer { app.terminate() }
        let more = app.navigationBars.buttons["live-tv-more"]
        let search = app.navigationBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        let back = app.buttons["live-tv-categories"]
        let category = app.buttons["live-tv-category"]
        if back.exists {
            XCTAssertTrue(category.isHittable)
            XCTAssertGreaterThanOrEqual(category.frame.minX - back.frame.maxX, 8)
            XCTAssertLessThanOrEqual(category.frame.minX - back.frame.maxX, 24)
            XCTAssertGreaterThan(search.frame.minX - category.frame.maxX,
                                 category.frame.minX - back.frame.maxX)
        }
        XCTAssertLessThanOrEqual(search.frame.maxX, more.frame.minX)
        XCTAssertLessThanOrEqual(more.frame.minX - search.frame.maxX, 16)
        XCTAssertFalse(app.buttons["live-tv-profile"].exists)
        capture("live-tv-grouped-guide-header", in: app)
        openBrowseAction("live-tv-settings", in: app)
        XCTAssertTrue(app.staticTexts["category-search-profile-settings"].waitForExistence(timeout: 5))
    }

    func testSourceAndCategoryMenusFilterWithoutChangingPlaybackOrConnectedSources() {
        let app = launch(guideFirst: true, multipleSources: true)
        defer { app.terminate() }
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(channel("Local Music", in: app).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(channel("Arena One", in: app).exists)
        if app.buttons["live-tv-categories"].exists {
            XCTAssertFalse(source.exists)
        } else {
            XCTAssertEqual(source.label, "Source")
            XCTAssertEqual(source.value as? String, "All")
        }
        assertBrowseCategory(nil, in: app)
        channel("Arena One", in: app).tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["category-preview-frame"].wait(for: \.label, toEqual: "Frame: ready", timeout: 10))
        let engine = app.staticTexts["category-preview-engine"].label
        let loads = app.staticTexts["category-preview-loads"].label

        selectBrowseSource("Sample TV", in: app)
        XCTAssertTrue(channel("Local Music", in: app).waitForNonExistence(timeout: 5))
        selectBrowseCategory("Sports", in: app)
        assertBrowseCategory("Sports", in: app)
        XCTAssertTrue(channel("Daily News", in: app).waitForNonExistence(timeout: 5))
        selectBrowseSource("Local TV", in: app)
        assertBrowseCategory("Sports", in: app)
        XCTAssertTrue(channel("Local Sport", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(channel("Arena One", in: app).exists)
        XCTAssertEqual(preview.label, "Arena One")
        XCTAssertEqual(app.staticTexts["category-preview-engine"].label, engine)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)

        selectBrowseCategory("Music", in: app)
        XCTAssertTrue(channel("Local Music", in: app).waitForExistence(timeout: 5))
        selectBrowseSource("Sample TV", in: app)
        assertBrowseCategory(nil, in: app)
        XCTAssertTrue(channel("Daily News", in: app).waitForExistence(timeout: 5))
        selectBrowseSource("All", in: app)
        XCTAssertTrue(channel("Local Music", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Arena One", in: app).exists)
        XCTAssertEqual(app.staticTexts["category-preview-loads"].label, loads)
        capture("live-tv-contextual-source-and-category", in: app)
    }

    func testLongSourceAndCategoryNamesKeepNavigationAccessible() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(longSourceName: true)
        defer { app.terminate() }
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        source.tap()
        app.buttons["Sample Television International Network"].tap()
        XCTAssertEqual(source.value as? String, "Sample Television International Network")
        let more = app.navigationBars.buttons["live-tv-more"]
        XCTAssertTrue(source.isHittable)
        XCTAssertLessThanOrEqual(source.frame.maxX, more.frame.minX)
        capture("live-tv-root-long-source-title", in: app)
        let tile = app.buttons["live-tv-browse-category-International Sports"]
        if tile.exists { tile.tap() }
        let category = app.navigationBars.buttons["live-tv-category"]
        if app.buttons["live-tv-sidebar-category-International Sports"].exists {
            XCTAssertFalse(category.exists)
            selectBrowseCategory("International Sports", in: app)
            assertBrowseCategory("International Sports", in: app)
            XCTAssertTrue(source.isHittable)
            XCTAssertTrue(more.isHittable)
            capture("live-tv-long-navigation-labels", in: app)
            return
        }
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        selectBrowseCategory("International Sports", in: app)
        assertBrowseCategory("International Sports", in: app)
        for control in [category, more] {
            XCTAssertTrue(control.isHittable, app.debugDescription)
        }
        capture("live-tv-long-navigation-labels", in: app)
        XCTAssertGreaterThanOrEqual(category.frame.width, 44)
        XCTAssertLessThanOrEqual(category.frame.maxX, more.frame.minX)
        let back = app.buttons["live-tv-categories"]
        if back.exists {
            XCTAssertFalse(source.exists)
            XCTAssertTrue(back.isHittable)
            XCTAssertLessThanOrEqual(back.frame.maxX, category.frame.minX)
            back.tap()
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertEqual(source.value as? String, "Sample Television International Network")
        } else {
            XCTAssertTrue(source.isHittable)
            XCTAssertLessThanOrEqual(source.frame.maxX, category.frame.minX)
        }
    }

    func testSourceMenuUpdatesCategoryCountsWhenPlaybackUnavailable() {
        let app = launch(multipleSources: true, playbackUnavailable: true)
        defer { app.terminate() }
        let sidebar = app.buttons["live-tv-sidebar-category-Sports"]
        let tile = app.buttons["live-tv-browse-category-Sports"]
        let ready = NSPredicate { _, _ in sidebar.exists || tile.exists }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15
        ), .completed)
        let sports = sidebar.exists ? sidebar : tile
        XCTAssertEqual(sports.value as? String, "3 channels")
        let source = app.buttons["live-tv-source"]
        source.tap()
        capture("live-tv-source-options", in: app)
        app.buttons["Local TV"].tap()
        XCTAssertEqual(source.value as? String, "Local TV")
        XCTAssertTrue((sports.value as? String)?.hasPrefix("1 ") == true, sports.debugDescription)
        source.tap()
        app.buttons["Sample TV"].tap()
        XCTAssertEqual(sports.value as? String, "2 channels")
        source.tap()
        app.buttons["All"].tap()
        XCTAssertEqual(sports.value as? String, "3 channels")
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
    }

    func testSourceDropdownOpensTheExistingAddSourceChoices() {
        let app = launch(guideFirst: true, multipleSources: true, managedSourceSetup: true)
        defer { app.terminate() }
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 15))
        selectBrowseCategory(nil, in: app)
        let back = app.buttons["live-tv-categories"]
        if back.exists {
            XCTAssertFalse(app.buttons["live-tv-source"].exists)
            back.tap()
        }
        app.buttons["live-tv-source"].tap()
        XCTAssertTrue(app.buttons["live-tv-add-source"].waitForExistence(timeout: 5))
        capture("live-tv-source-dropdown", in: app)
        app.buttons["live-tv-add-source"].tap()
        let playlist = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["live-tv-add-server"].exists)
        XCTAssertTrue(app.buttons["live-tv-import-playlist"].exists)
        XCTAssertFalse(app.staticTexts["Your sources"].exists)
        capture("live-tv-add-source-choices", in: app)
        playlist.tap()
        XCTAssertTrue(app.staticTexts["category-source-setup-request"].wait(
            for: \.label, toEqual: "playlist", timeout: 5
        ), app.debugDescription)
    }

    func testCategoryGridRetainsKeylinesAndEqualGapsAfterSearch() {
        let app = launch()
        defer { app.terminate() }
        let first = app.buttons["live-tv-category-all"]
        if !first.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["live-tv-sidebar-category-all"].waitForExistence(timeout: 10))
            return
        }
        let second = app.buttons["live-tv-browse-category-Entertainment"]
        let third = app.buttons["live-tv-browse-category-International Sports"]
        let originalFrame = first.frame
        let field = searchField(in: app)
        XCTAssertFalse(field.exists)
        XCTAssertEqual(app.staticTexts["Categories"].frame.minX, first.frame.minX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(first.frame.height, 44)
        XCTAssertLessThanOrEqual(first.frame.height, 70, "Default category tiles should be compact.")
        let horizontalGap = second.frame.minX - first.frame.maxX
        let verticalGap = third.frame.minY - first.frame.maxY
        XCTAssertGreaterThanOrEqual(horizontalGap, 8)
        XCTAssertEqual(horizontalGap, verticalGap, accuracy: 1)
        app.navigationBars.buttons["Search"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("sports")
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame, originalFrame)
        capture("category-browser-aligned", in: app)
    }
    #endif

    func testCategoryEntryRetainsConnectionRecoveryActions() {
        let app = launch(failsLoading: true)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Channels unavailable"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["TV Sources"].exists)
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
        XCTAssertFalse(app.buttons["live-tv-category-all"].exists)
    }

    func testCategoryFirstBrowsingUsesGridOrSidebarAndShowsChannelCounts() {
        let app = launch()
        defer { app.terminate() }
        let sidebar = app.buttons["live-tv-sidebar-category-Sports"]
        let tile = app.buttons["live-tv-browse-category-Sports"]
        let ready = NSPredicate { _, _ in sidebar.exists || tile.exists }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 15
        ), .completed, app.debugDescription)
        let usesSidebar = sidebar.exists
        #if os(iOS)
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(source.isHittable)
        #endif
        let sports = usesSidebar ? sidebar : tile
        XCTAssertEqual(sports.value as? String, "2 channels")
        let originalX = usesSidebar ? sidebar.frame.minX : 0
        if !usesSidebar {
            XCTAssertFalse(channel("Arena One", in: app).exists)
            #if os(iOS)
            XCTAssertFalse(searchField(in: app).exists)
            XCTAssertTrue(app.navigationBars.buttons["Search"].isHittable)
            #endif
        }
        capture("category-browser", in: app)
        activate(sports, in: app)
        XCTAssertTrue(channel("World Arena", in: app).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Stadium Live", in: app).exists)
        XCTAssertFalse(channel("Daily News", in: app).exists)
        capture("category-browser-guide", in: app)
        #if os(iOS)
        XCTAssertEqual(source.exists, usesSidebar, "Only the root directory or split view owns the source title.")
        #endif
        if usesSidebar {
            XCTAssertTrue(sidebar.exists)
            XCTAssertEqual(sidebar.frame.minX, originalX, accuracy: 1)
            XCTAssertLessThan(sidebar.frame.maxX, channel("Arena One", in: app).frame.minX)
            #if os(iOS)
            XCTAssertFalse(app.navigationBars.buttons["live-tv-profile"].exists)
            #endif
        } else {
            #if os(iOS)
            let profile = app.navigationBars.buttons["live-tv-profile"]
            XCTAssertFalse(profile.exists, app.debugDescription)
            XCTAssertFalse(app.buttons["live-tv-guide-actions"].exists)
            XCTAssertFalse(app.buttons["live-tv-guide-now"].exists)
            openBrowseAction("live-tv-multiview-favorites", in: app)
            let close = app.buttons["live-tv-close-sheet"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            app.buttons["live-tv-categories"].tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable)
            XCTAssertFalse(profile.exists)
            XCTAssertFalse(channel("Arena One", in: app).exists)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            #endif
        }
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
    }

    func testCategoryAndChannelResultsOpenTheSelectedCategoryWithoutPlayback() {
        let app = launchSearch()
        defer { app.terminate() }
        let field = searchField(in: app)
        field.typeText("sports")
        let category = app.buttons["live-tv-search-category-International Sports"]
        XCTAssertTrue(category.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["live-tv-search-category-Sports"].exists)
        XCTAssertFalse(app.buttons["live-tv-search-category-Entertainment"].exists)
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Sports Report", in: app).exists)
        #if os(tvOS)
        focus(category, in: app)
        XCUIRemote.shared.press(.down)
        let firstRowFocused = NSPredicate { _, _ in
            self.containsFocus(self.channel("Arena One", in: app))
                || self.containsFocus(app.buttons["Matchday Live"].firstMatch)
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: firstRowFocused, object: nil)], timeout: 5
        ), .completed, app.debugDescription)
        focus(category, in: app)
        #else
        field.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(category.frame.minX, app.frame.minX + 12)
        #endif
        capture("category-search-results", in: app)
        activate(category, in: app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
        let world = channel("World Arena", in: app)
        XCTAssertTrue(world.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(channel("Arena One", in: app).exists)
        XCTAssertFalse(channel("Sports Report", in: app).exists)
        XCTAssertFalse(app.otherElements["category-search-playback"].exists)
        #if os(tvOS)
        let guideFocused = NSPredicate { _, _ in
            self.containsFocus(world) || self.containsFocus(app.buttons["World Sports"].firstMatch)
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: guideFocused, object: nil)], timeout: 5
        ), .completed, app.debugDescription)
        #endif
        capture("category-search-selected-guide", in: app)
    }

    func testBackFromSearchPreservesTheUnfilteredGuide() {
        let app = launchSearch(guideFirst: true)
        defer { app.terminate() }
        #if os(iOS)
        XCTAssertFalse(app.navigationBars.buttons["live-tv-source"].exists)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.navigationBars.buttons["live-tv-profile"].exists)
        }
        #endif
        let field = searchField(in: app)
        field.typeText("sports")
        XCTAssertTrue(app.buttons["live-tv-search-category-Sports"].waitForExistence(timeout: 5))
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        field.typeText("\n")
        app.navigationBars.buttons["Close"].tap()
        #endif
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(channel("Daily News", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["live-tv-search-category-Sports"].exists)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.navigationBars.buttons["live-tv-profile"].exists)
        }
        #endif
    }

    private func launch(
        guideFirst: Bool = false, failsLoading: Bool = false, orientation: String = "auto",
        lightAppearance: Bool = false, dimVideo: Bool = false, multipleSources: Bool = false,
        longSourceName: Bool = false, playbackUnavailable: Bool = false, managedSourceSetup: Bool = false,
        scrollContent: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
        app.launchArguments = ["--category-search-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments.append("--category-preview-\(orientation)")
        if guideFirst { app.launchArguments.append("--category-search-guide-first") }
        if failsLoading { app.launchArguments.append("--category-search-failure") }
        if lightAppearance { app.launchArguments.append("--category-preview-light") }
        if dimVideo { app.launchArguments.append("--category-preview-dim") }
        if multipleSources { app.launchArguments.append("--category-multiple-sources") }
        if longSourceName { app.launchArguments.append("--category-long-source-name") }
        if playbackUnavailable { app.launchArguments.append("--category-playback-unavailable") }
        if managedSourceSetup { app.launchArguments.append("--category-managed-source-setup") }
        if scrollContent { app.launchArguments.append("--category-scroll-content") }
        app.launch()
        return app
    }

    private func launchSearch(guideFirst: Bool = false) -> XCUIApplication {
        let app = launch(guideFirst: guideFirst)
        #if os(tvOS)
        let search = app.buttons["live-tv-search"]
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 15), app.debugDescription)
        if guideFirst {
            let categories = app.buttons["live-tv-sidebar-category-all"]
            for _ in 0..<3 where !containsFocus(categories) { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(containsFocus(categories), app.debugDescription)
        }
        #else
        let search = app.navigationBars.buttons["Search"]
        #endif
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        activate(search, in: app)
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    #if os(iOS)
    private func assertHeaderBackdropChanges(
        in app: XCUIApplication, scroll: XCUIElement, header: XCUIElement, before: XCUIScreenshot,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let region = CGRect(x: scroll.frame.minX, y: header.frame.minY,
                            width: scroll.frame.width, height: header.frame.height).intersection(app.frame)
        func pixels(_ screenshot: XCUIScreenshot) throws -> [UInt8] {
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            let crop = CGRect(
                x: (region.minX - app.frame.minX) * scale, y: (region.minY - app.frame.minY) * scale,
                width: region.width * scale, height: region.height * scale
            )
            let cropped = try XCTUnwrap(image.cropping(to: crop))
            var bytes = [UInt8](repeating: 0, count: 64 * 16 * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 64, height: 16))
            }
            return bytes
        }
        let initial = try pixels(before)
        let scrolled = try pixels(app.screenshot())
        let difference = sqrt(initial.indices.filter { $0 % 4 != 3 }.reduce(0.0) {
            let delta = Double(initial[$1]) - Double(scrolled[$1])
            return $0 + delta * delta
        } / Double(64 * 16 * 3))
        XCTAssertGreaterThan(difference, 2,
                             "The rendered header backdrop must change, not only the accessibility frames.",
                             file: file, line: line)
    }

    private func selectBrowseSource(_ name: String, in app: XCUIApplication) {
        let category = app.navigationBars.buttons["live-tv-category"]
        let previousCategory = category.exists ? category.value as? String : nil
        let back = app.buttons["live-tv-categories"]
        let returnsToDirectory = back.exists
        if returnsToDirectory { back.tap() }
        let source = app.navigationBars.buttons["live-tv-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Paused TV"].exists)
        app.buttons[name].tap()
        XCTAssertEqual(source.value as? String, name)
        if returnsToDirectory {
            let tile = app.buttons["live-tv-browse-category-\(previousCategory ?? "")"]
            if tile.exists { tile.tap() }
            else { app.buttons["live-tv-category-all"].tap() }
            XCTAssertTrue(category.waitForExistence(timeout: 5))
            XCTAssertFalse(source.exists)
        }
    }

    private func selectBrowseCategory(_ name: String?, in app: XCUIApplication) {
        let sidebar = app.buttons["live-tv-sidebar-category-\(name ?? "all")"]
        if sidebar.exists {
            sidebar.tap()
        } else {
            app.navigationBars.buttons["live-tv-category"].tap()
            capture("live-tv-category-dropdown", in: app)
            app.collectionViews.buttons[name ?? "All channels"].tap()
        }
    }

    private func assertBrowseCategory(
        _ name: String?, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let sidebar = app.buttons["live-tv-sidebar-category-\(name ?? "all")"]
        if sidebar.exists {
            XCTAssertTrue(sidebar.isSelected, file: file, line: line)
            XCTAssertFalse(app.navigationBars.buttons["live-tv-category"].exists, file: file, line: line)
        } else {
            XCTAssertEqual(app.navigationBars.buttons["live-tv-category"].value as? String,
                           name ?? "All channels", file: file, line: line)
        }
    }

    private func videoFrame(in app: XCUIApplication) -> CGRect {
        // The playback accessibility container also includes the decorative top reflection.
        app.otherElements["category-preview-video-bounds"].frame
    }

    private func openBrowseAction(_ identifier: String, in app: XCUIApplication) {
        app.navigationBars.buttons["live-tv-more"].tap()
        capture("live-tv-more-menu", in: app)
        let action = app.buttons[identifier]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
    }
    #endif

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.searchFields.firstMatch
    }

    private func channel(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "live-tv-channel-channels-", name
        )).firstMatch
    }

    private func activate(_ target: XCUIElement, in app: XCUIApplication) {
        #if os(tvOS)
        focus(target, in: app)
        XCUIRemote.shared.press(.select)
        #else
        target.tap()
        #endif
    }

    #if os(tvOS)
    private func containsFocus(_ target: XCUIElement) -> Bool {
        target.exists && (target.hasFocus || target.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
    }

    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 {
            if containsFocus(target) { return }
            let current = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if target.frame.midY > current.frame.maxY {
                XCUIRemote.shared.press(.down)
            } else if target.frame.midY < current.frame.minY {
                XCUIRemote.shared.press(.up)
            } else {
                XCUIRemote.shared.press(target.frame.midX < current.frame.midX ? .left : .right)
            }
        }
        XCTFail("Could not focus \(target.identifier)\n\(app.debugDescription)")
    }
    #endif

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        for (index, screen) in XCUIScreen.screens.enumerated() where index > 0 {
            let display = XCTAttachment(screenshot: screen.screenshot())
            display.name = "\(name)-display-\(index)"
            display.lifetime = .keepAlways
            add(display)
        }
    }
}
