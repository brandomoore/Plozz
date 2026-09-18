import XCTest

@MainActor
final class FamilyGuidanceRemoteTests: XCTestCase {
    func testHeaderAgeIsSeparateFromTwoReviewScores() {
        let app = launch()
        defer { app.terminate() }
        let age = app.descendants(matching: .any)["family-guidance-age-badge"].firstMatch
        XCTAssertTrue(age.isHittable)
        XCTAssertTrue(age.label.contains("recommended age 14"))
        XCTAssertFalse(age.label.contains("5"))
        XCTAssertTrue(app.staticTexts["94%"].exists)
        XCTAssertTrue(app.staticTexts["88%"].exists)
        XCTAssertFalse(app.staticTexts["8.0"].exists)
        let tile = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        XCTAssertTrue(isFocused(tile), "The informational header must not add a focus target.")
    }

    func testOpeningLongGuidanceKeepsAgeAndSummaryVisible() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let age = app.staticTexts["Recommended age: 16+"].firstMatch
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "family-guidance-opening-position"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(age.isHittable, "The recommended age must remain visible when the dialog opens.")
        XCTAssertGreaterThanOrEqual(age.frame.height, 70, "Age should be the dominant number, not another review score.")
        XCTAssertGreaterThanOrEqual(age.frame.minY, app.frame.minY + 30)
        XCTAssertTrue(app.staticTexts[
            "A sci-fi mystery with tense scenes, strong language, and unsettling images."
        ].firstMatch.isHittable, "Opening must not scroll past the summary.")
    }

    func testLightThemeKeepsAgeAndBrandVisible() {
        let app = launch(extra: "--family-guidance-light")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].isHittable)
        XCTAssertTrue(app.staticTexts["Common Sense Media"].isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "family-guidance-light-theme"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRatingTileOpensGuidanceAndReturnsFocus() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Ratings"].exists)
        let tile = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "family-guidance-rating-tile"
        before.lifetime = .keepAlways
        add(before)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].exists)
        XCTAssertTrue(isFocused(app.buttons["family-guidance-overview"].firstMatch))
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "family-guidance-detail-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
    }

    func testFailedGuidanceOffersRetryWithoutLosingBasicRating() {
        let app = launch(extra: "--family-guidance-failure")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Common Sense Media"].exists)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(retry))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
    }

    func testRestrictedGuidanceDoesNotPretendTheContentIsSafe() {
        let app = launch(extra: "--family-guidance-restricted")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts[
            "Detailed guidance requires Plex Pass access for the account viewing this title."
        ].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["family-guidance-topic-violence"].exists)
    }

    func testTopicsShowOneExplanationAndKeepQualitySeparate() {
        let app = launch()
        defer { app.terminate() }
        let tile = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        XCTAssertFalse(tile.label.contains("/ 5"), "Quality must not look like part of the age recommendation.")
        XCUIRemote.shared.press(.select)
        let language = app.buttons["family-guidance-topic-language"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        for _ in 0..<9 where !isFocused(language) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(language))
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertEqual(reader.value as? String, "A fictional description of language.")
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].firstMatch.isHittable)
        let reviews = app.buttons["family-guidance-reviews"].firstMatch
        for _ in 0..<9 where !isFocused(reviews) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(reviews))
        XCTAssertTrue(app.staticTexts["Quality ratings, not age recommendations"].exists)
        XCTAssertFalse((reader.value as? String ?? "").contains("A fictional description of language."))
    }

    func testLongReaderReturnsToTheSelectedTopic() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(reader))
        let firstParagraph = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Review paragraph 1.")
        ).firstMatch
        XCTAssertTrue(firstParagraph.exists)
        let paragraphTop = firstParagraph.frame.minY
        let beforeScroll = XCTAttachment(screenshot: app.screenshot())
        beforeScroll.name = "family-guidance-before-scroll"
        beforeScroll.lifetime = .keepAlways
        add(beforeScroll)
        XCUIRemote.shared.press(.down, forDuration: 0.7)
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        let afterScroll = XCTAttachment(screenshot: app.screenshot())
        afterScroll.name = "family-guidance-after-scroll"
        afterScroll.lifetime = .keepAlways
        add(afterScroll)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "family-guidance-scrolled-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertLessThan(firstParagraph.frame.minY, paragraphTop - 5,
                          "The text must actually scroll, not merely retain focus.")
        let scrolledTop = firstParagraph.frame.minY
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(reader), "Up must not escape to Done before the reader handles it.")
        let scrolledUp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in firstParagraph.frame.minY > scrolledTop + 5 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [scrolledUp], timeout: 3), .completed,
                       "Up must scroll back through the review.")
        XCTAssertTrue(isFocused(reader), "Down should scroll the reader, not jump into another topic.")
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].firstMatch.isHittable)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(app.buttons["family-guidance-overview"].firstMatch),
                      "Left must return to Overview rather than the nearest middle row.")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(app.buttons["family-guidance-topic-message"].firstMatch),
                      "Other topics must become available again after returning.")
    }

    private func isFocused(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
    }

    private func launch(extra: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--family-guidance-fixture"] + (extra.map { [$0] } ?? [])
        app.launch()
        XCTAssertTrue(app.staticTexts["family-guidance-fixture-ready"].waitForExistence(timeout: 15))
        return app
    }
}
