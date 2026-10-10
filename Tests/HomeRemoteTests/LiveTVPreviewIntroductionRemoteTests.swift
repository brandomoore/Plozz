import XCTest

@MainActor
final class LiveTVPreviewIntroductionRemoteTests: XCTestCase {
    func testFavoriteMultiviewsEmptySheetHasCompactHeaderAndDismisses() {
        let app = openMultiviews(saved: false)
        defer { app.terminate() }
        assertCompactMultiviewHeader(in: app)
        let description = app.staticTexts["Favorite a Multiview to open its channels and layout here."]
        XCTAssertTrue(description.exists)
        XCTAssertLessThanOrEqual(description.frame.width, 420)
        XCTAssertLessThan(description.frame.height, 100)
        XCTAssertGreaterThan(description.frame.minY, app.staticTexts["live-multiview-favorites-title"].frame.maxY + 32)
        capture("multiview-favorites-empty", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["live-multiview-favorites-title"].waitForNonExistence(timeout: 5))
    }

    func testFavoriteMultiviewsSavedRowsScrollWithoutMovingHeader() {
        let app = openMultiviews(saved: true)
        defer { app.terminate() }
        assertCompactMultiviewHeader(in: app)
        let headerY = app.staticTexts["live-multiview-favorites-title"].frame.minY
        XCTAssertGreaterThan(headerY, 200, "A long saved list must stay in a compact sheet")
        for index in 1...8 {
            if index > 1 { XCUIRemote.shared.press(.down) }
            let row = app.buttons["live-multiview-saved-fixture-\(index)"]
            assertFocused(row)
            XCTAssertLessThan(row.frame.height, 150)
            XCTAssertLessThanOrEqual(row.frame.maxY, app.frame.maxY - 80)
            if index == 2 { capture("multiview-favorites-saved", in: app) }
        }
        XCTAssertEqual(app.staticTexts["live-multiview-favorites-title"].frame.minY, headerY, accuracy: 1)
        XCTAssertTrue(app.buttons["live-tv-close-sheet"].isHittable)
        capture("multiview-favorites-scrolled", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["live-multiview-favorites-title"].waitForNonExistence(timeout: 5))
    }

    private func openMultiviews(saved: Bool) -> XCUIApplication {
        let app = launch(
            suite: "PreviewIntroduction.\(UUID().uuidString)", reset: true,
            nativeSidebar: true, savedMultiviews: saved
        )
        assertFocused(app.buttons["live-tv-preview-enable"])
        XCUIRemote.shared.press(.menu)
        _ = focusFirstGuideContent(in: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["All categories"])
        let multiviewsReady = NSPredicate { _, _ in app.buttons["live-tv-multiview-favorites"].isEnabled }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: multiviewsReady, object: nil)], timeout: 5
        ), .completed)
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["live-tv-multiview-favorites"])
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons[saved ? "live-multiview-saved-fixture-1" : "live-tv-close-sheet"])
        return app
    }

    private func assertCompactMultiviewHeader(in app: XCUIApplication) {
        let title = app.staticTexts["live-multiview-favorites-title"]
        let done = app.buttons["live-tv-close-sheet"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(title.frame.height, 70)
        XCTAssertLessThanOrEqual(done.frame.height, 60)
        XCTAssertLessThan(done.frame.width, 140)
        XCTAssertLessThanOrEqual(title.frame.maxX + 16, done.frame.minX)
    }

    func testLeadingEdgeRevealsOnlyCategoriesInsideNativeSidebar() {
        exerciseNativeSidebar(rtl: false)
    }

    func testRTLLeadingEdgeRevealsOnlyCategoriesInsideNativeSidebar() {
        exerciseNativeSidebar(rtl: true)
    }

    func testLeadingEdgeRevealsOnlyCategoriesWithNativeSidebarAndPreview() {
        exerciseNativeSidebar(rtl: false, preview: true)
    }

    private func exerciseNativeSidebar(rtl: Bool, preview: Bool = false) {
        let app = launch(
            suite: "PreviewIntroduction.\(UUID().uuidString)", reset: true, rtl: rtl, nativeSidebar: true
        )
        defer {
            capture("native-sidebar-final-state", in: app)
            app.terminate()
        }
        let leading: XCUIRemote.Button = rtl ? .right : .left
        assertFocused(app.buttons["live-tv-preview-enable"])
        if !preview {
            XCUIRemote.shared.press(
                app.buttons["live-tv-preview-disable"].frame.midX < app.buttons["live-tv-preview-enable"].frame.midX
                    ? .left : .right
            )
            assertFocused(app.buttons["live-tv-preview-disable"])
        }
        XCUIRemote.shared.press(.select)
        assertStatus(preview ? "chosen-on; playback=true" : "chosen-off; playback=false", in: app)
        let content = focusFirstGuideContent(in: app, rtl: rtl)
        let station = app.buttons["live-tv-channel-channels-1"]
        let appMenu = app.collectionViews["Sidebar"]
        assertCategoriesHidden(in: app)
        XCTAssertTrue(!appMenu.exists || appMenu.frame.isEmpty)
        var selectedCategory = "All categories"
        for iteration in 0..<3 {
            if iteration > 0 {
                XCUIRemote.shared.press(rtl ? .left : .right)
                assertCategoriesHidden(in: app)
                XCUIRemote.shared.press(rtl ? .left : .right)
                assertFocused(content)
                assertCategoriesHidden(in: app)
            }
            let nativeFocusVisits = app.staticTexts["preview-native-focus-visits"].label
            XCUIRemote.shared.press(leading)
            if iteration != 1 { assertFocused(station) }
            if iteration == 2 { XCUIRemote.shared.press(leading, forDuration: 0.6) }
            else { XCUIRemote.shared.press(leading) }
            assertFocused(app.buttons[selectedCategory])
            XCTAssertTrue(app.buttons[selectedCategory].isEnabled)
            XCTAssertEqual(app.staticTexts["preview-native-focus-visits"].label, nativeFocusVisits,
                           "Native app navigation must not briefly steal focus before categories settle")
            XCTAssertFalse(containsFocus(app.collectionViews["Sidebar"]),
                           "Revealing categories must not open the app menu")
            // Collapsed native menus retain AX elements with empty frames.
            // On tvOS 27, even expanded native rows can report not hittable.
            XCTAssertTrue(!appMenu.exists || appMenu.frame.isEmpty,
                           "The app menu must stay collapsed even if a category still owns focus")
            if iteration == 0 {
                selectedCategory = "Entertainment & Lifestyle"
                XCUIRemote.shared.press(.down)
                assertFocused(app.buttons[selectedCategory])
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.buttons[selectedCategory].isSelected)
            }
        }
        capture("native-sidebar-category-reveal", in: app)
        let collapsedTree = XCTAttachment(string: app.debugDescription)
        collapsedTree.name = "native-sidebar-category-reveal"
        collapsedTree.lifetime = .keepAlways
        add(collapsedTree)
        XCUIRemote.shared.press(leading)
        if containsFocus(app.buttons["live-tv-search"]) {
            XCUIRemote.shared.press(leading)
        }
        let navigationFocused = NSPredicate { _, _ in
            self.containsFocus(app.collectionViews["Sidebar"]) || self.containsFocus(app.buttons["Live TV"])
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: navigationFocused, object: nil)], timeout: 5
        ), .completed, "Leading navigation through the category panel must still reach the app menu\n\(app.debugDescription)")
        let menuVisible = NSPredicate { _, _ in appMenu.exists && !appMenu.frame.isEmpty }
        let menuResult = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: menuVisible, object: nil)], timeout: 5
        )
        capture("native-sidebar-after-categories", in: app)
        let navigationTree = XCTAttachment(string: app.debugDescription)
        navigationTree.name = "native-sidebar-after-categories"
        navigationTree.lifetime = .keepAlways
        add(navigationTree)
        XCTAssertEqual(menuResult, .completed, "The app menu must expand after leaving categories")
    }

    private func focusFirstGuideContent(in app: XCUIApplication, rtl: Bool = false) -> XCUIElement {
        let content = app.buttons["live-tv-channel-content-channels-1-whole"]
        let station = app.buttons["live-tv-channel-channels-1"]
        let guideEntered = NSPredicate { _, _ in self.containsFocus(content) || self.containsFocus(station) }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: guideEntered, object: nil)], timeout: 5
        ), .completed, app.debugDescription)
        if containsFocus(station) { XCUIRemote.shared.press(rtl ? .left : .right) }
        assertFocused(content)
        return content
    }

    func testRTLLeadingEdgeRevealsCategoriesAndReturnsToTheSameChannel() {
        let app = launch(suite: "PreviewIntroduction.\(UUID().uuidString)", reset: true, rtl: true)
        defer { app.terminate() }
        assertFocused(app.buttons["live-tv-preview-enable"])
        XCUIRemote.shared.press(.menu)
        assertStatus("chosen-off; playback=false", in: app)
        let second = app.buttons["live-tv-channel-content-channels-2-whole"]
        XCUIRemote.shared.press(.down)
        assertFocused(second)
        assertCategoriesHidden(in: app)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        assertFocused(app.buttons["All categories"])
        assertFullHeightCategories(in: app, beside: second)
        capture("rtl-categories-revealed", in: app)
        XCUIRemote.shared.press(.left)
        assertCategoriesHidden(in: app)
        XCUIRemote.shared.press(.left)
        assertFocused(second)
        capture("rtl-guide-same-channel", in: app)
    }

    func testAffirmativeInitiallyFocusedAndStartsPreviewOnlyAfterSelection() {
        let suite = "PreviewIntroduction.\(UUID().uuidString)"
        let app = launch(suite: suite, reset: true)
        defer { app.terminate() }
        assertFocused(app.buttons["live-tv-preview-enable"])
        capture("preview-choice-affirmative", in: app)
        assertStatus("unanswered; playback=false", in: app)
        XCUIRemote.shared.press(.select)
        assertStatus("chosen-on; playback=true", in: app)
        XCTAssertFalse(app.buttons["live-tv-preview-enable"].exists)
        app.terminate()
        _ = launch(suite: suite)
        assertStatus("chosen-on; playback=true", in: app)
        XCTAssertFalse(app.buttons["live-tv-preview-enable"].exists)
    }

    func testRightReachesKeepOffAndChoiceIsProfileScoped() {
        let suite = "PreviewIntroduction.\(UUID().uuidString)"
        let app = launch(suite: suite, reset: true)
        defer { app.terminate() }
        assertFocused(app.buttons["live-tv-preview-enable"])
        XCUIRemote.shared.press(.right)
        assertFocused(app.buttons["live-tv-preview-disable"])
        capture("preview-choice-keep-off", in: app)
        assertStatus("unanswered; playback=false", in: app)
        XCUIRemote.shared.press(.select)
        assertStatus("chosen-off; playback=false", in: app)
        XCTAssertFalse(app.buttons["live-tv-preview-enable"].exists)
        let content = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "live-tv-channel-content-channels-")
        ).firstMatch
        assertFocused(content)
        assertCategoriesHidden(in: app)
        let expandedGuideX = content.frame.minX
        capture("preview-categories-collapsed", in: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["All categories"])
        XCTAssertGreaterThan(content.frame.minX - expandedGuideX, 300)
        assertFullHeightCategories(in: app, beside: content)
        capture("preview-wider-categories", in: app)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Entertainment & Lifestyle"])
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.right)
        assertCategoriesHidden(in: app)
        XCUIRemote.shared.press(.right)
        assertFocused(content)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Entertainment & Lifestyle"])
        assertStatus("chosen-off; playback=false", in: app)
        app.terminate()
        _ = launch(suite: suite)
        assertStatus("chosen-off; playback=false", in: app)
        XCTAssertFalse(app.buttons["live-tv-preview-enable"].exists)
        app.terminate()
        _ = launch(suite: suite, secondProfile: true)
        assertFocused(app.buttons["live-tv-preview-enable"])
        assertStatus("unanswered; playback=false", in: app)
        XCUIRemote.shared.press(.menu)
        assertStatus("chosen-off; playback=false", in: app)
        XCTAssertFalse(app.buttons["live-tv-preview-enable"].exists)
    }

    private func launch(
        suite: String, reset: Bool = false, secondProfile: Bool = false, rtl: Bool = false,
        nativeSidebar: Bool = false, savedMultiviews: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--preview-introduction-fixture", "--preview-suite=\(suite)",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (reset ? ["--reset-preview-choice"] : [])
          + (secondProfile ? ["--second-preview-profile"] : [])
          + (rtl ? ["--preview-rtl"] : [])
          + (nativeSidebar ? ["--preview-native-sidebar"] : [])
          + (savedMultiviews ? ["--preview-saved-multiviews"] : [])
        app.launch()
        return app
    }

    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), file: file, line: line)
        let focused = NSPredicate { _, _ in self.containsFocus(element) }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: focused, object: nil)], timeout: 5
        ), .completed, XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost").debugDescription,
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 50, file: file, line: line)
    }

    private func containsFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
    }

    private func assertStatus(
        _ expected: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let status = app.staticTexts["preview-fixture-status"]
        let matches = NSPredicate { _, _ in status.exists && status.label == expected }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 10
        ), .completed, app.debugDescription, file: file, line: line)
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertFullHeightCategories(
        in app: XCUIApplication, beside channel: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let search = app.buttons["live-tv-search"]
        let categories = app.scrollViews["live-tv-category-list"]
        XCTAssertTrue(categories.exists, file: file, line: line)
        XCTAssertLessThan(search.frame.minY, 120, file: file, line: line)
        XCTAssertLessThan(search.frame.maxY, channel.frame.minY - 200, file: file, line: line)
        XCTAssertGreaterThanOrEqual(categories.frame.maxY, app.frame.maxY - 40, file: file, line: line)
        XCTAssertEqual(app.buttons["All categories"].frame.width, 384, accuracy: 1, file: file, line: line)
    }

    private func assertCategoriesHidden(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let hidden = NSPredicate { _, _ in !app.buttons["All categories"].exists }
        let result = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 5
        )
        capture("guide-category-visibility", in: app)
        XCTAssertEqual(result, .completed, app.debugDescription, file: file, line: line)
    }
}
