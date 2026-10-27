import XCTest

#if os(iOS)
import UIKit
#endif

@MainActor
final class LiveTVCategorySearchInteractionTests: XCTestCase {
    #if os(iOS)
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
        let filters = app.buttons["live-tv-category"].frame
        XCTAssertTrue(
            abs(preview.frame.minY - filters.maxY - 8) <= 2 || preview.frame.maxX <= filters.minX,
            "The video must sit 8 pt below a horizontal toolbar or clear a vertical toolbar."
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
        let search = app.buttons["live-tv-search"]
        let category = app.buttons["live-tv-sidebar-category-all"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        let searchFrame = search.frame
        let categoryFrame = category.frame
        let arena = channel("Arena One", in: app)
        XCTAssertTrue(arena.waitForExistence(timeout: 5))
        arena.tap()
        let preview = app.otherElements["category-search-playback"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(search.frame.minY - searchFrame.minY) < 1
                && arena.frame.minY >= preview.frame.maxY
                && preview.frame.minX >= search.frame.maxX
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
                && abs(preview.frame.minY - app.buttons["live-tv-category"].frame.maxY - 8) < 2
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
        XCTAssertEqual(preview.frame.minY - app.buttons["live-tv-category"].frame.maxY, 8, accuracy: 2)
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
            XCTAssertEqual(control.frame.midY, preview.frame.midY, accuracy: 2)
        }
        background.tap()
        XCTAssertTrue(fullscreen.waitForNonExistence(timeout: 5))
        background.tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        XCTAssertEqual(preview.value as? String, "Preview")
        XCTAssertTrue(channel("Daily News", in: app).isHittable)
    }

    func testNativeToolbarGroupsProfileAndBrowseActions() {
        let app = launch()
        defer { app.terminate() }
        let profile = app.navigationBars.buttons["live-tv-profile"]
        let filters = app.navigationBars.buttons["live-tv-category"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(filters.exists, app.debugDescription)
        XCTAssertEqual(filters.frame.midY, profile.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(profile.frame.minX - filters.frame.maxX, 16)
        for button in [profile, filters] {
            XCTAssertGreaterThanOrEqual(button.frame.height, 32)
            XCTAssertLessThanOrEqual(button.frame.height, 48)
        }
        let guide = app.navigationBars.buttons["live-tv-open-guide"]
        if guide.exists {
            XCTAssertEqual(guide.frame.midY, filters.frame.midY, accuracy: 1)
            XCTAssertLessThanOrEqual(filters.frame.minX - guide.frame.maxX, 16)
        }
        filters.tap()
        let close = app.buttons["live-tv-close-sheet"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        profile.tap()
        XCTAssertTrue(app.staticTexts["category-search-profile-settings"].waitForExistence(timeout: 5))
    }

    func testCategoryGridAndSearchShareKeylinesAndEqualGaps() {
        let app = launch()
        defer { app.terminate() }
        let first = app.buttons["live-tv-category-all"]
        if !first.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["live-tv-sidebar-category-all"].waitForExistence(timeout: 10))
            return
        }
        let second = app.buttons["live-tv-browse-category-Entertainment"]
        let third = app.buttons["live-tv-browse-category-International Sports"]
        let field = searchField(in: app)
        XCTAssertEqual(field.frame.minX, first.frame.minX, accuracy: 1)
        XCTAssertEqual(field.frame.maxX, second.frame.maxX, accuracy: 1)
        XCTAssertEqual(app.staticTexts["Categories"].frame.minX, first.frame.minX, accuracy: 1)
        let horizontalGap = second.frame.minX - first.frame.maxX
        let verticalGap = third.frame.minY - first.frame.maxY
        XCTAssertGreaterThanOrEqual(horizontalGap, 8)
        XCTAssertEqual(horizontalGap, verticalGap, accuracy: 1)
        field.tap()
        field.typeText("sports")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(field.frame.minX, first.frame.minX, accuracy: 1)
        XCTAssertEqual(field.frame.maxX, second.frame.maxX, accuracy: 1)
        capture("category-browser-aligned", in: app)
    }
    #endif

    func testCategoryEntryRetainsConnectionRecoveryActions() {
        let app = launch(failsLoading: true)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Channels unavailable"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertTrue(app.buttons["Sources"].exists)
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
        let sports = usesSidebar ? sidebar : tile
        XCTAssertEqual(sports.value as? String, "2 channels")
        let originalX = usesSidebar ? sidebar.frame.minX : 0
        if !usesSidebar {
            XCTAssertFalse(channel("Arena One", in: app).exists)
            #if os(iOS)
            let field = searchField(in: app)
            XCTAssertLessThanOrEqual(field.frame.height, 44)
            XCTAssertLessThanOrEqual(field.frame.minY - app.buttons["live-tv-open-guide"].frame.maxY, 24)
            #endif
        }
        capture("category-browser", in: app)
        activate(sports, in: app)
        XCTAssertTrue(channel("World Arena", in: app).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(channel("Stadium Live", in: app).exists)
        XCTAssertFalse(channel("Daily News", in: app).exists)
        capture("category-browser-guide", in: app)
        if usesSidebar {
            XCTAssertTrue(sidebar.exists)
            XCTAssertEqual(sidebar.frame.minX, originalX, accuracy: 1)
            XCTAssertLessThan(sidebar.frame.maxX, channel("Arena One", in: app).frame.minX)
            #if os(iOS)
            XCTAssertTrue(app.navigationBars.buttons["live-tv-profile"].isHittable)
            #endif
        } else {
            #if os(iOS)
            let profile = app.navigationBars.buttons["live-tv-profile"]
            if UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertFalse(profile.exists, app.debugDescription)
            } else {
                XCTAssertTrue(profile.isHittable, app.debugDescription)
            }
            XCTAssertFalse(app.buttons["live-tv-guide-actions"].exists)
            XCTAssertFalse(app.buttons["live-tv-guide-now"].exists)
            app.navigationBars.buttons["live-tv-multiview-favorites"].tap()
            let close = app.buttons["live-tv-close-sheet"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            app.buttons["live-tv-categories"].tap()
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            XCTAssertTrue(profile.isHittable)
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
        app.buttons["live-tv-search"].tap()
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
        lightAppearance: Bool = false, dimVideo: Bool = false
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
        app.launch()
        return app
    }

    private func launchSearch(guideFirst: Bool = false) -> XCUIApplication {
        let app = launch(guideFirst: guideFirst)
        #if os(iOS)
        if !guideFirst, searchField(in: app).waitForExistence(timeout: 2) {
            searchField(in: app).tap()
            return app
        }
        #endif
        let search = app.buttons["live-tv-search"]
        XCTAssertTrue(channel("Arena One", in: app).waitForExistence(timeout: 15), app.debugDescription)
        #if os(tvOS)
        if guideFirst {
            let categories = app.buttons["live-tv-sidebar-category-all"]
            for _ in 0..<3 where !containsFocus(categories) { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(containsFocus(categories), app.debugDescription)
        }
        #endif
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        activate(search, in: app)
        XCTAssertTrue(searchField(in: app).waitForExistence(timeout: 5), app.debugDescription)
        return app
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        #if os(tvOS)
        app.searchFields.firstMatch
        #else
        app.textFields["live-tv-search-field"]
        #endif
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
