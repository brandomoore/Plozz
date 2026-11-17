import XCTest

@MainActor
final class UpcomingNavigationTests: XCTestCase {
    func testWeekStripPagesAndJumpsWithoutFilteringTheAgenda() throws {
        let app = launch(sparse: false, extraArguments: ["--capture-thirty", "--capture-many-days"])
        defer { app.terminate() }
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "01. ")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        assertFocused(today(in: app), in: app)
        let nextWeek = app.buttons["upcoming.week.next"]
        for _ in 0..<8 where !nextWeek.hasFocus { XCUIRemote.shared.press(.right) }
        assertFocused(nextWeek, in: app)
        XCUIRemote.shared.press(.select)
        assertFocused(nextWeek, in: app)
        XCUIRemote.shared.press(.select)
        assertFocused(nextWeek, in: app)
        for _ in 0..<7 { XCUIRemote.shared.press(.left) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        let today = calendar.startOfDay(for: Date())
        let initialWeek = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: today))
        let day = try XCTUnwrap(calendar.date(byAdding: .weekOfYear, value: 2, to: initialWeek.start))
        assertFocused(app.buttons["upcoming.week.day.\(Int(day.timeIntervalSinceReferenceDate))"], in: app)
        XCUIRemote.shared.press(.select)
        let offset = try XCTUnwrap(calendar.dateComponents([.day], from: today, to: day).day)
        assertFocused(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Upcoming day \(offset)"
        )).firstMatch, in: app)
        XCTAssertFalse(nextWeek.isHittable, "The week strip must scroll away rather than stay pinned.")
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Upcoming day \(offset - 1)"
        )).firstMatch, in: app)
    }

    func testDenseDateScrollsHorizontallyAndDownThroughOffscreenDates() {
        let app = launch(sparse: false, extraArguments: ["--capture-thirty", "--capture-many-days"])
        defer { app.terminate() }
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "01. ")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        moveFocus(to: first, in: app)
        assertFocused(first, in: app)
        for number in 2...9 {
            XCUIRemote.shared.press(.right)
            assertFocused(app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", String(format: "%02d. ", number)
            )).firstMatch, in: app)
        }
        XCUIRemote.shared.press(.down)
        let movie = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "A saved movie")).firstMatch
        assertFocused(movie, in: app)
        for day in 3..<20 {
            XCUIRemote.shared.press(.down)
            assertFocused(app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Upcoming day \(day)"
            )).firstMatch, in: app)
        }
        for day in (3..<19).reversed() {
            XCUIRemote.shared.press(.up)
            assertFocused(app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Upcoming day \(day)"
            )).firstMatch, in: app)
        }
        XCUIRemote.shared.press(.up)
        assertFocused(movie, in: app)
        attach(app, name: "Upcoming deep agenda return")
    }

    func testPinnedEntryStartsAtWeekAndRestoresReleaseFromNavigation() {
        let app = launch()
        defer { app.terminate() }
        let first = firstRelease(in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        assertFocused(today(in: app), in: app)
        XCUIRemote.shared.press(.down)
        assertFocused(first, in: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Upcoming"], in: app)
        XCUIRemote.shared.press(.right)
        assertFocused(first, in: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["Home"], in: app)
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["Home fixture"], in: app)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        assertFocused(first, in: app)
        attach(app, name: "Upcoming first release focused")
    }

    func testHeaderControlsReachSparseReleaseRowsInBothDirections() {
        let app = launch()
        defer { app.terminate() }
        let first = firstRelease(in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        XCUIRemote.shared.press(.down)
        assertFocused(first, in: app)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["upcoming.calendar"], in: app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        assertFocused(first, in: app)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.up)
        XCUIRemote.shared.press(.right)
        assertFocused(app.buttons["upcoming.filters"], in: app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        assertFocused(first, in: app)
        XCUIRemote.shared.press(.down)
        let later = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Later upcoming movie")).firstMatch
        assertFocused(later, in: app)
        XCUIRemote.shared.press(.up)
        assertFocused(first, in: app)
        attach(app, name: "Upcoming calendar-to-agenda focus")
    }

    func testCalendarHasUniformDaysAndSelectionScrollsWithoutRemovingEarlierReleases() {
        let app = launch()
        defer { app.terminate() }
        let first = firstRelease(in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        moveFocus(to: app.buttons["upcoming.calendar"], in: app)
        XCUIRemote.shared.press(.select)
        let month = app.staticTexts["upcoming.calendar.month"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        let expectedMonth = Date().formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
        XCTAssertEqual(month.label, expectedMonth)
        XCTAssertTrue(app.staticTexts["Today"].exists)
        let one = app.buttons["upcoming.calendar.day.1"]
        let ten = app.buttons["upcoming.calendar.day.10"]
        XCTAssertEqual(one.frame.width, ten.frame.width, accuracy: 1)
        XCTAssertEqual(one.frame.height, ten.frame.height, accuracy: 1)
        attach(app, name: "Upcoming calendar")

        let calendar = Calendar.current
        let laterDate = calendar.date(byAdding: .day, value: 10, to: Date())!
        if !calendar.isDate(laterDate, equalTo: Date(), toGranularity: .month) {
            moveFocus(to: app.buttons["upcoming.calendar.next"], in: app)
            XCUIRemote.shared.press(.select)
        }
        moveFocus(to: app.buttons["upcoming.calendar.day.\(calendar.component(.day, from: laterDate))"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(month.waitForNonExistence(timeout: 5))
        let later = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Later upcoming movie")).firstMatch
        let aligned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            later.exists && later.frame.minY > 0 && later.frame.minY < app.frame.height / 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed, app.debugDescription)
        assertFocused(later, in: app)
        attach(app, name: "Upcoming selected date")
        XCUIRemote.shared.press(.up)
        assertFocused(first, in: app)
    }

    private func moveFocus(to target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.exists, app.debugDescription)
        for _ in 0..<24 {
            if target.hasFocus { return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(focused.exists, app.debugDescription)
            let origin = focused.frame
            let destination = target.frame
            if abs(origin.midY - destination.midY) > destination.height / 2 {
                XCUIRemote.shared.press(origin.midY < destination.midY ? .down : .up)
            } else {
                XCUIRemote.shared.press(origin.midX < destination.midX ? .right : .left)
            }
        }
        XCTFail("Could not reach calendar date using the remote: \(app.debugDescription)")
    }

    private func launch(sparse: Bool = true, extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--upcoming-capture-fixture", "--capture-pinned",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (sparse ? ["--capture-sparse"] : []) + extraArguments
        app.launchEnvironment["PLZHFOCUS_STDOUT"] = "1"
        app.launch()
        return app
    }

    private func firstRelease(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "First upcoming movie")).firstMatch
    }

    private func today(in app: XCUIApplication) -> XCUIElement {
        let day = Calendar.current.startOfDay(for: Date())
        return app.buttons["upcoming.week.day.\(Int(day.timeIntervalSinceReferenceDate))"]
    }

    private func assertFocused(
        _ element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && (element.hasFocus
                || element.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus))
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed { attach(app, name: "Upcoming focus failure") }
        XCTAssertEqual(result, .completed, app.debugDescription, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
