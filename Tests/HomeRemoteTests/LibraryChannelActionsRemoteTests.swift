import XCTest

@MainActor
final class LibraryChannelActionsRemoteTests: XCTestCase {
    func testGuideCanOpenTheOriginalShow() { exerciseNavigation(guide: true, movie: false) }
    func testGuideCanOpenTheOriginalMovie() { exerciseNavigation(guide: true, movie: true) }
    func testPlayerCanOpenTheOriginalShow() { exerciseNavigation(guide: false, movie: false) }
    func testPlayerCanOpenTheOriginalMovie() { exerciseNavigation(guide: false, movie: true) }

    func testDisplayMatchingIsOnlyAllowedAfterOpeningTheChannel() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-channel-actions", "--preview"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Matching off"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Watch channel"].hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Matching on"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Matching off"].waitForExistence(timeout: 5))
    }

    private func exerciseNavigation(guide: Bool, movie: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-channel-actions"]
            + (guide ? ["--guide"] : []) + (movie ? ["--movie"] : [])
        app.launch()
        defer {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "library-title-action-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.terminate()
        }
        if guide {
            XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 15))
            XCUIRemote.shared.press(.left)
            if !isFocused(app.buttons["live-tv-channel-channels-1"]) {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "guide-focus-before-menu"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(isFocused(app.buttons["live-tv-channel-channels-1"]))
            XCUIRemote.shared.press(.select)
        }
        let action = guide
            ? app.cells.containing(.any, identifier: "library-channel-open-title").firstMatch
            : app.buttons["library-channel-open-title"]
        let exists = action.waitForExistence(timeout: 15)
        if !exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "missing-library-title-action"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(exists)
        for _ in 0..<6 where !isFocused(action) {
            XCUIRemote.shared.press(guide ? .down : .up)
        }
        XCTAssertTrue(isFocused(action))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts[movie ? "Opened Fixture Movie" : "Opened Fixture Show"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[movie ? "movie:movie-1:fixture-account" : "series:show-1:fixture-account"].exists)
        if !guide {
            XCTAssertTrue(app.staticTexts["Stopped 1"].waitForExistence(timeout: 5))
        }
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        element.hasFocus || element.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).count > 0
    }
}
