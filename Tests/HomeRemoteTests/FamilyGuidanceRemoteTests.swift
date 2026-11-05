import XCTest
import UIKit
import Vision

@MainActor
final class FamilyGuidanceRemoteTests: XCTestCase {
    func testVisibleGuidanceFocusDoesNotScrollThePage() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-guidance",
                               "--detail-layout-scrolling"]
        app.launch()
        defer { app.terminate() }
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        let score = app.descendants(matching: .any)["detail-rating-rottenTomatoes"].firstMatch
        let guidance = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        let heading = app.staticTexts["Ratings"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 15))
        XCTAssertTrue(isFocused(app.buttons["detail-fixture-header"].firstMatch))
        for _ in 0..<4 where !isFocused(about) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(about))
        XCUIRemote.shared.press(.right)
        if isFocused(guidance) { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(score), app.debugDescription)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(isFocused(score), app.debugDescription)
        let before = heading.frame.minY
        XCTAssertGreaterThan(before, 60)
        XCTAssertLessThan(before, 200)
        XCTAssertGreaterThan(guidance.frame.minY, app.frame.minY + 40)
        XCTAssertLessThan(guidance.frame.maxY, app.frame.maxY - 40)
        recordScreenshot(app, name: "visible-guidance-before-focus")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(guidance), app.debugDescription)
        recordScreenshot(app, name: "visible-guidance-after-focus")
        XCTAssertEqual(heading.frame.minY, before, accuracy: 1,
                       "Focusing an already-visible guidance card must not move the page.")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(score), app.debugDescription)
        XCTAssertEqual(heading.frame.minY, before, accuracy: 1)

        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(app.descendants(matching: .any)["detail-crew-writers-more"].firstMatch),
                      app.debugDescription)
        for _ in 0..<3 { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(score), app.debugDescription)
        let returned = heading.frame.minY
        XCTAssertGreaterThan(guidance.frame.minY, app.frame.minY + 40)
        XCTAssertLessThan(guidance.frame.maxY, app.frame.maxY - 40)
        recordScreenshot(app, name: "visible-guidance-return-before-focus")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(guidance), app.debugDescription)
        recordScreenshot(app, name: "visible-guidance-return-after-focus")
        XCTAssertEqual(heading.frame.minY, returned, accuracy: 1)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.isFocused(guidance) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(app.descendants(matching: .any)["detail-crew-directors-more"].firstMatch),
                      app.debugDescription)
    }

    func testClippedGuidanceStillScrollsIntoView() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-guidance",
                               "--detail-layout-scrolling", "--detail-layout-guidance-clipped"]
        app.launch()
        defer { app.terminate() }
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        let score = app.descendants(matching: .any)["detail-rating-rottenTomatoes"].firstMatch
        let guidance = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 15))
        for _ in 0..<4 where !isFocused(about) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(about))
        XCUIRemote.shared.press(.right)
        if isFocused(guidance) { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(score), app.debugDescription)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(isFocused(score), app.debugDescription)
        let before = app.staticTexts["Ratings"].firstMatch.frame.minY
        XCTAssertGreaterThan(guidance.frame.maxY, app.frame.maxY - 60)
        recordScreenshot(app, name: "clipped-guidance-before-focus")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(guidance), app.debugDescription)
        XCTAssertLessThan(guidance.frame.maxY, app.frame.maxY - 40)
        XCTAssertLessThan(app.staticTexts["Ratings"].firstMatch.frame.minY, before)
        recordScreenshot(app, name: "clipped-guidance-after-focus")
    }

    func testSummaryCardsHaveClearlyVisibleFocus() throws {
        try checkSummaryFocus(extra: [], name: "dark")
    }

    func testSummaryCardsKeepLightFocusReadable() throws {
        try checkSummaryFocus(extra: ["--detail-layout-light"], name: "light")
    }

    func testSummaryCardsKeepOpaqueFocusReadable() throws {
        try checkSummaryFocus(extra: ["--detail-layout-reduced-transparency"], name: "opaque")
    }

    private func checkSummaryFocus(extra: [String], name: String) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-rich"] + extra
        app.launch()
        defer { app.terminate() }
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        let score = app.descendants(matching: .any)["detail-rating-rottenTomatoes"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 15))
        XCTAssertTrue(score.exists, app.debugDescription)
        for _ in 0..<4 where !isFocused(about) { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(about))
        let aboutRegion = about.frame.insetBy(dx: 30, dy: 30)
        let scoreRegion = score.frame.insetBy(dx: 30, dy: 30)
        let focusedAbout = try XCTUnwrap(app.screenshot().image.cgImage)
        try assertSummaryTextContrast(focusedAbout, containing: ["documentary", "collectors"], in: about.frame, app: app)
        recordScreenshot(app, name: "summary-focus-\(name)-about")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(score), app.debugDescription)
        let focusedScore = try XCTUnwrap(app.screenshot().image.cgImage)
        try assertSummaryTextContrast(focusedScore, containing: ["96%"], in: score.frame, app: app)
        recordScreenshot(app, name: "summary-focus-\(name)-rating")
        for region in [aboutRegion, scoreRegion] {
            XCTAssertGreaterThan(
                try changedPixelFraction(focusedAbout, focusedScore, frame: region, app: app), 0.45,
                "Focus must visibly change the card interior, not just add a faint rim."
            )
        }
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(about))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail-reader-card"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.isFocused(about) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    func testCastRailKeepsAllPeopleAndNavigationWithoutMore() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture"]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["Person 1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(isFocused(first), app.debugDescription)
        XCTAssertFalse(app.buttons["detail-cast-more"].exists)
        for _ in 1..<40 { XCUIRemote.shared.press(.right) }
        let last = app.buttons["Person 40"].firstMatch
        XCTAssertTrue(isFocused(last), app.debugDescription)
        recordScreenshot(app, name: "complete-cast-rail")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["selected-cast-person"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-cast-person"].label, "Person 40")
        XCTAssertFalse(app.staticTexts["detail-more-title"].exists)
    }

    func testDirectorFollowsSixActorsAndKeepsPersonNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-cast-crew"]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["Person 1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(isFocused(first), app.debugDescription)
        for _ in 0..<6 { XCUIRemote.shared.press(.right) }
        // The circular control exposes its final caption as the focused AX node.
        XCTAssertTrue(isFocused(app.buttons["Director"].firstMatch), app.debugDescription)
        XCTAssertTrue(app.buttons["Film Director"].exists)
        recordScreenshot(app, name: "director-after-six-actors")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["selected-cast-person"].label, "Film Director")
        for (name, focusLabel) in [("Film Writer", "Writer"), ("Film Producer", "Producer"),
                                   ("Film Composer", "Composer"), ("Person 7", "Person 7")] {
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(app.buttons[name].exists)
            XCTAssertTrue(isFocused(app.buttons[focusLabel].firstMatch), app.debugDescription)
        }
        for _ in 7..<40 { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(isFocused(app.buttons["Person 40"].firstMatch), app.debugDescription)
        XCTAssertFalse(app.buttons["detail-cast-more"].exists)
    }

    func testLongDetailsUseTheSameReadableCard() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-single-long-value"]
        app.launch()
        defer { app.terminate() }
        let more = app.buttons["detail-details-original-title-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        XCTAssertTrue(isFocused(more))
        XCUIRemote.shared.press(.select)
        assertDetailReader(app, title: "Details")
        recordScreenshot(app, name: "shared-reader-long-details")
        XCUIRemote.shared.press(.menu)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: more)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
    }

    private func assertDetailReader(_ app: XCUIApplication, title: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let heading = app.staticTexts["detail-more-title"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(heading.label, title, file: file, line: line)
        let card = app.descendants(matching: .any)["detail-reader-card"].firstMatch
        XCTAssertTrue(card.exists, file: file, line: line)
        XCTAssertEqual(card.frame.width, 900, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(card.frame.height, 761, file: file, line: line)
        XCTAssertLessThan(heading.frame.height, 50, file: file, line: line)
        XCTAssertEqual(heading.frame.minX, card.frame.minX + 48, accuracy: 1, file: file, line: line)
        XCTAssertTrue(heading.isHittable, file: file, line: line)
        XCTAssertEqual(heading.frame.minY, card.frame.minY + 48, accuracy: 1, file: file, line: line)
    }

    func testCompactScorePromotesFactsAndKeepsAvailabilityLeading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let example: [String: Any] = [
            "item": [
                "id": "series", "title": "A series", "kind": "series",
                "overview": String(repeating: "A story about friends working together. ", count: 8),
                "productionYear": 2020, "originalLanguage": "fr", "seriesStatus": "ended",
                "catalogSeasonCount": 8, "catalogEpisodeCount": 100,
                "runtime": 2640, "genres": ["Drama"],
                "ratings": [["source": "tmdb", "value": 8.1, "scale": "outOfTen"]],
                "people": [["id": "director", "name": "A director", "kind": "Director"]]
            ],
            "availability": [
                "regionCode": "US", "releaseEvents": [],
                "watchOffers": [
                    ["providerID": 1, "providerName": "Stream service", "kind": "subscription", "regionCode": "US"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: example).write(to: url)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture"]
        app.launchEnvironment["PLOZZ_DETAIL_EXAMPLE_PATH"] = url.path
        app.launch()
        defer { app.terminate() }
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        let score = app.descendants(matching: .any)["detail-rating-tmdb"].firstMatch
        let year = app.descendants(matching: .any)["detail-details-year-more"].firstMatch
        let runtime = app.descendants(matching: .any)["detail-details-runtime-more"].firstMatch
        let status = app.descendants(matching: .any)["detail-details-series-status-more"].firstMatch
        let seasons = app.descendants(matching: .any)["detail-details-seasons-more"].firstMatch
        let episodes = app.descendants(matching: .any)["detail-details-episodes-more"].firstMatch
        let language = app.descendants(matching: .any)["detail-details-original-language-more"].firstMatch
        let genres = app.descendants(matching: .any)["detail-details-genres-more"].firstMatch
        let streaming = app.descendants(matching: .any)["detail-availability-streaming-more"].firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(streaming))
        let details = app.staticTexts["Details"].firstMatch
        let availability = app.staticTexts["Release & Availability"].firstMatch
        let crew = app.staticTexts["Crew"].firstMatch
        XCTAssertEqual(details.frame.minY, app.staticTexts["Ratings"].firstMatch.frame.minY, accuracy: 1)
        XCTAssertEqual(year.frame.minX, about.frame.minX + 2 * (about.frame.width + 56), accuracy: 1)
        XCTAssertLessThanOrEqual(score.frame.width, about.frame.width / 2)
        XCTAssertEqual(score.frame.minY, about.frame.minY, accuracy: 1)
        XCTAssertEqual(score.frame.maxY, about.frame.maxY, accuracy: 1)
        XCTAssertEqual(availability.frame.minX, about.frame.minX, accuracy: 1)
        XCTAssertEqual(crew.frame.minX, score.frame.minX, accuracy: 1)
        XCTAssertEqual(crew.frame.minY, availability.frame.minY, accuracy: 1)
        for (leading, trailing) in [(year, runtime), (status, seasons), (episodes, language)] {
            XCTAssertEqual(leading.frame.minX, details.frame.minX, accuracy: 1)
            XCTAssertEqual(trailing.frame.minX, details.frame.minX + (about.frame.width + 56) / 2, accuracy: 1)
            XCTAssertEqual(leading.frame.minY, trailing.frame.minY, accuracy: 1)
        }
        XCTAssertGreaterThan(status.frame.minY, year.frame.maxY)
        XCTAssertGreaterThan(episodes.frame.minY, status.frame.maxY)
        XCTAssertGreaterThan(genres.frame.minY, episodes.frame.maxY)
        for value in ["Ended", "8", "100", "French", "JustWatch"] {
            XCTAssertTrue(app.staticTexts[value].exists, value)
        }
        XCUIRemote.shared.press(.up)
        for _ in 0..<4 where !isFocused(about) { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(about))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue([year, runtime, status, seasons, episodes, language, genres].contains(where: isFocused),
                      "Right from the score must enter the adjacent facts.")
        for _ in 0..<4 where !isFocused(year) && !isFocused(runtime) { XCUIRemote.shared.press(.up) }
        if isFocused(runtime) { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(isFocused(year), "The promoted facts must be reachable beside the score.")
        let yearLabel = year.staticTexts.element(boundBy: 0)
        let yearFrame = yearLabel.frame
        try assertFocusedFactContrast(year, in: app)
        XCTAssertLessThanOrEqual(year.frame.maxX + 12, runtime.frame.minX - 22,
                                 "Paired facts must leave room for both glass focus outsets.")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(runtime))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(seasons))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(status))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(year))
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(streaming), "Down from About must reach the leading availability section.")
        XCTAssertEqual(yearLabel.frame, yearFrame, "Focus must not move promoted fact text.")
        try assertFocusedFactContrast(streaming, in: app)
        recordScreenshot(app, name: "compact-score-leading-availability")
    }

    func testUnboxedFocusIsVisibleWithoutMovingOrCoveringNeighbors() throws {
        try checkUnboxedFocus(extra: [], name: "gradient")
    }

    func testUnboxedFocusKeepsLightThemeContrastAndClearance() throws {
        try checkUnboxedFocus(extra: ["--detail-layout-light"], name: "light")
    }

    func testUnboxedFocusKeepsOpaqueFallbackContrastAndClearance() throws {
        try checkUnboxedFocus(extra: ["--detail-layout-reduced-transparency"], name: "opaque")
    }

    func testUnboxedFocusKeepsFlatBackgroundContrastAndClearance() throws {
        try checkUnboxedFocus(extra: ["--detail-layout-flat"], name: "flat")
    }

    func testCapturedDiscoverExamplePreservesOffersAndAttribution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let example: [String: Any] = [
            "item": ["id": "captured", "title": "Captured movie", "kind": "movie",
                     "overview": "An example with regional availability."],
            "availability": [
                "regionCode": "US", "releaseEvents": [],
                "watchOffers": [
                    ["providerID": 1, "providerName": "Stream service", "kind": "subscription", "regionCode": "US"],
                    ["providerID": 2, "providerName": "Rental service", "kind": "rent", "regionCode": "US"],
                    ["providerID": 3, "providerName": "Purchase service", "kind": "buy", "regionCode": "US"]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: example).write(to: url)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture"]
        app.launchEnvironment["PLOZZ_DETAIL_EXAMPLE_PATH"] = url.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Stream service"].waitForExistence(timeout: 15))
        for label in ["Streaming", "Rent", "Buy", "Stream service", "Rental service", "Purchase service", "JustWatch"] {
            XCTAssertTrue(app.staticTexts[label].exists, label)
        }
        XCTAssertFalse(app.staticTexts["Playback"].exists)
        XCTAssertFalse(app.staticTexts["Cast"].exists, "Captured examples must not inherit unrelated synthetic people.")
    }

    private func checkUnboxedFocus(extra: [String], name: String) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-rich"] + extra
        app.launch()
        defer { app.terminate() }
        let year = app.descendants(matching: .any)["detail-details-year-more"].firstMatch
        let directors = app.descendants(matching: .any)["detail-crew-directors-more"].firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 15))
        for _ in 0..<8 where !isFocused(year) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(year))
        let neighbors = ["Runtime", "Content Rating", "Written By", "Server", "Details", "Crew"]
            .map { app.staticTexts[$0].firstMatch }
        let frames = neighbors.map(\.frame)
        let yearFrame = year.frame
        let directorsFrame = directors.frame
        let text = [year, directors].flatMap { element in
            [element.staticTexts.element(boundBy: 0), element.staticTexts.element(boundBy: 1)]
        }
        let textFrames = text.map(\.frame)
        let before = try XCTUnwrap(app.screenshot().image.cgImage)
        try assertFocusedFactContrast(year, in: app)
        recordScreenshot(app, name: "contained-focus-\(name)-year")
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(app.descendants(matching: .any)["detail-details-runtime-more"].firstMatch))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(directors))
        let after = try XCTUnwrap(app.screenshot().image.cgImage)
        try assertFocusedFactContrast(directors, in: app)
        recordScreenshot(app, name: "contained-focus-\(name)-directors")

        for frame in [yearFrame, directorsFrame] {
            let region = frame.insetBy(dx: -10, dy: -10)
            let change = try changedPixelFraction(before, after, frame: region, app: app)
            // A native rim changes a perimeter, not a fixed percentage of a large text area.
            let minimumChange = 0.5 * (region.width + region.height) / (region.width * region.height)
            XCTAssertGreaterThan(change, minimumChange, "Logical focus without a visible highlight is not sufficient.")
        }
        for label in [textFrames[0], textFrames[2]] {
            let paddingRegions = [
                CGRect(x: label.minX - 18, y: label.midY - 5, width: 8, height: 10),
                CGRect(x: label.minX + 12, y: label.minY - 10, width: 30, height: 8)
            ]
            for region in paddingRegions {
                let change = try changedPixelFraction(before, after, frame: region, app: app)
                XCTAssertGreaterThan(change, 0.5,
                                     "Glass must preserve horizontal and vertical breathing room.")
            }
        }
        for (element, frame) in zip(text, textFrames) {
            XCTAssertEqual(element.frame, frame, "Focus must not move or scale the text keyline.")
        }
        for (neighbor, frame) in zip(neighbors, frames) {
            XCTAssertEqual(neighbor.frame, frame, "Focus must not reflow a sibling.")
            let change = try changedPixelFraction(before, after, frame: frame, app: app)
            XCTAssertLessThan(change, 0.02, "The highlight must not paint over \(neighbor.label).")
        }
        let factGap = neighbors[1].frame.minY - textFrames[1].maxY
        XCTAssertGreaterThanOrEqual(factGap, 24,
                                    "The next fact must leave room for both 12pt vertical focus outsets.")
        XCTAssertLessThanOrEqual(factGap, 40, "Short facts must not retain the old 56pt row gap.")
        XCTAssertGreaterThanOrEqual(textFrames[2].minY - neighbors[5].frame.maxY, 12,
                                    "The focus surface must clear its section heading.")
    }

    func testUnboxedSectionMoreRetainsFocusContrastAndExpandsOmittedFacts() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-upcoming",
                               "--detail-many-release-events", "--detail-layout-flat"]
        app.launch()
        defer { app.terminate() }
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        let more = app.buttons["detail-availability-more"]
        XCTAssertTrue(about.waitForExistence(timeout: 15))
        for _ in 0..<4 where !isFocused(about) { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(isFocused(about))
        for _ in 0..<16 where !isFocused(more) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(more), app.debugDescription)
        try assertFocusedFactContrast(more, in: app)
        recordScreenshot(app, name: "unboxed-section-more-focused")
        XCUIRemote.shared.press(.select)
        assertDetailReader(app, title: "Release & Availability")
        recordScreenshot(app, name: "shared-reader-availability")
    }

    func testUnboxedDetailColumnsSupportRemoteExpansionAndScrolling() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--detail-information-fixture", "--detail-layout-rich",
                               "--detail-layout-flat", "--detail-long-filename"]
        app.launch()
        defer { app.terminate() }
        let year = app.descendants(matching: .any)["detail-details-year-more"].firstMatch
        let directors = app.descendants(matching: .any)["detail-crew-directors-more"].firstMatch
        let filename = app.descendants(matching: .any)["detail-playback-filename-more"].firstMatch
        XCTAssertTrue(year.waitForExistence(timeout: 15))
        for _ in 0..<8 where !isFocused(year) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(year), app.debugDescription)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(app.descendants(matching: .any)["detail-about"].firstMatch),
                      "Up must return from facts to About.")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(year))
        try assertFocusedFactContrast(year, in: app)
        recordScreenshot(app, name: "unboxed-detail-reading-stop")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.staticTexts["detail-more-title"].exists,
                       "A complete fact is a reading stop, not an expansion action.")

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(app.descendants(matching: .any)["detail-details-runtime-more"].firstMatch))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(directors), "Right must enter the neighboring unboxed column.")
        try assertFocusedFactContrast(directors, in: app)
        recordScreenshot(app, name: "unboxed-detail-directors-focused")
        XCUIRemote.shared.press(.select)
        assertDetailReader(app, title: "Crew")
        recordScreenshot(app, name: "shared-reader-crew")
        let lastDirector = app.staticTexts["Director 20"]
        for _ in 0..<25 where !lastDirector.exists || !lastDirector.isHittable { XCUIRemote.shared.press(.down) }
        recordScreenshot(app, name: "unboxed-detail-full-crew")
        XCTAssertTrue(lastDirector.isHittable, "More retains the complete list: \(app.debugDescription)")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(directors.waitForExistence(timeout: 5))
        XCTAssertTrue(isFocused(directors))

        XCUIRemote.shared.press(.right)
        let initialTop = year.frame.minY
        for _ in 0..<12 where !isFocused(filename) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(filename), app.debugDescription)
        XCTAssertTrue(filename.isHittable)
        try assertFocusedFactContrast(filename, in: app)
        XCTAssertLessThan(year.frame.minY, initialTop, "Focus must scroll lower technical facts into view.")
        recordScreenshot(app, name: "unboxed-detail-playback-scrolled")
        XCUIRemote.shared.press(.select)
        assertDetailReader(app, title: "Playback")
        recordScreenshot(app, name: "shared-reader-playback")
    }

    func testHeaderAgeIsSeparateFromTwoReviewScores() {
        let app = launch()
        defer { app.terminate() }
        let age = app.descendants(matching: .any)["family-guidance-age-badge"].firstMatch
        XCTAssertTrue(age.isHittable)
        XCTAssertEqual(age.label, "Common Sense Media, recommended age 14 and older")
        XCTAssertGreaterThanOrEqual(age.frame.height, 32)
        XCTAssertLessThanOrEqual(age.frame.height, 34)
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

    func testHeaderCaptionAndSynopsisShareAnAlignedRow() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let age = app.staticTexts["Recommended age: 16+"].firstMatch
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        let caption = app.staticTexts["Recommended age"].firstMatch
        let synopsis = app.staticTexts[
            "A sci-fi mystery with tense scenes, strong language, and unsettling images."
        ].firstMatch
        let title = app.staticTexts["Family guidance fixture"].firstMatch
        XCTAssertEqual(caption.frame.maxY, synopsis.frame.maxY, accuracy: 2)
        XCTAssertEqual(age.frame.minX, caption.frame.minX, accuracy: 1)
        XCTAssertEqual(title.frame.minX, synopsis.frame.minX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(title.frame.minY, age.frame.minY)
        XCTAssertLessThanOrEqual(app.staticTexts["Common Sense Media"].firstMatch.frame.maxY, age.frame.maxY)
        recordScreenshot(app, name: "family-guidance-header-grid")
    }

    func testWrappedHeaderKeepsSynopsisAlignedWithoutOverlappingTheReader() {
        let app = launch(extra: "--family-guidance-wrapped-header")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let age = app.staticTexts["Recommended age: 16+"].firstMatch
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        let caption = app.staticTexts["Recommended age"].firstMatch
        let synopsis = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "A sci-fi mystery with tense scenes"
        )).firstMatch
        XCTAssertGreaterThan(synopsis.frame.height, caption.frame.height * 2)
        XCTAssertEqual(caption.frame.minY, synopsis.frame.minY, accuracy: 2,
                       "A wrapped synopsis starts on the caption row, rather than moving the whole identity block.")
        XCTAssertTrue(age.isHittable)
        XCTAssertGreaterThan(app.staticTexts["What parents need to know"].frame.minY, synopsis.frame.maxY)
        recordScreenshot(app, name: "family-guidance-header-grid-wrapped")
    }

    func testHeaderWithoutSynopsisKeepsAgeBrandAndReaderVisible() {
        let app = launch(extra: "--family-guidance-no-summary")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended age"].isHittable)
        XCTAssertTrue(app.staticTexts["Common Sense Media"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["family-guidance-reader"].firstMatch.isHittable)
    }

    func testOverviewMovesUpToDoneAndCloses() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let overview = app.buttons["family-guidance-overview"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(isFocused(overview))
        XCUIRemote.shared.press(.up)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(isFocused(done), "Up from Overview must reach Done across the header.")
        recordScreenshot(app, name: "family-guidance-done-dark")
        XCUIRemote.shared.press(.select)
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.buttons["family-guidance-overview"].exists
                    && self.isFocused(app.descendants(matching: .any)["family-guidance-tile"].firstMatch)
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Done must dismiss the dialog and restore its tile after the transition.")
    }

    func testLongReaderMovesUpToDoneOnlyAfterScrollingBackToTheTop() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(reader))
        let paragraph = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Review paragraph 1.")
        ).firstMatch
        let top = paragraph.frame.minY
        XCUIRemote.shared.press(.down)
        let scrolled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in paragraph.frame.minY < top - 20 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 3), .completed)
        XCUIRemote.shared.press(.up)
        let atTop = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                paragraph.frame.minY >= top - 1 && self.isFocused(reader)
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [atTop], timeout: 3), .completed,
                       "The first Up scrolls to the top without leaving the reader.")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(app.buttons["Done"].firstMatch),
                      "Once at the top, Up must reach Done rather than trapping focus.")
    }

    func testShortTopicReaderCanReachDoneAndReturnToItsTopic() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let topic = app.buttons["family-guidance-topic-language"].firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 5))
        for _ in 0..<9 where !isFocused(topic) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(topic))
        XCUIRemote.shared.press(.right)
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue(isFocused(reader))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(app.buttons["Done"].firstMatch),
                      "A short right-hand section must allow Up to Done immediately.")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(reader))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(topic))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(isFocused(app.buttons["family-guidance-topic-sex"].firstMatch),
                      "Returning from Done must not leave the other menu topics disabled.")
    }

    func testBlackDialogUsesTheAvailableReadingHeightWithoutAFooter() {
        let app = launch(extra: "--family-guidance-black")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(reader.frame.maxY, app.frame.maxY - 140,
                                   "The reading viewport should extend into the space formerly reserved for the footer.")
        XCTAssertFalse(app.staticTexts["Guidance from Common Sense Media through Plex"].exists)
        XCTAssertFalse(app.otherElements["PopoverDismissRegion"].exists,
                       "The custom panel must not be nested inside the system's glass sheet.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "family-guidance-black-panel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(app.buttons["Done"].firstMatch))
        recordScreenshot(app, name: "family-guidance-done-black")
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
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(isFocused(app.buttons["Done"].firstMatch))
        recordScreenshot(app, name: "family-guidance-done-light")
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
        checkGuidanceRetry(extra: "--family-guidance-failure")
    }

    func testGuidanceRetryAfterAuthorizationFailureActuallyLoadsTheReview() {
        checkGuidanceRetry(extra: "--family-guidance-expired-once")
    }

    private func checkGuidanceRetry(extra: String) {
        let app = launch(extra: extra)
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Common Sense Media"].exists)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(retry))
        XCUIRemote.shared.press(.select)
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5), "The static section heading is not evidence that Retry loaded anything.")
        XCTAssertTrue((reader.value as? String)?.contains("Review paragraph 1.") == true)
        XCTAssertTrue(app.buttons["family-guidance-topic-violence"].exists)
        XCTAssertFalse(retry.exists)
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

    func testDiscussionReaderKeepsHeadingAndRemoteReturnBehavior() {
        let app = launch()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let discussion = app.buttons["family-guidance-discussion"].firstMatch
        XCTAssertTrue(discussion.waitForExistence(timeout: 5))
        for _ in 0..<12 where !isFocused(discussion) { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(isFocused(discussion))
        let reader = app.descendants(matching: .any)["family-guidance-reader"].firstMatch
        XCTAssertTrue((reader.value as? String ?? "").hasPrefix("What helped"))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(isFocused(reader))
        recordScreenshot(app, name: "family-guidance-discussion-reader")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(isFocused(discussion))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["family-guidance-tile"].firstMatch.waitForExistence(timeout: 5))
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

    private func assertFocusedFactContrast(_ element: XCUIElement, in app: XCUIApplication) throws {
        let label = element.staticTexts.firstMatch
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let frame = label.exists ? label.frame : element.frame
        let pixels = try pixels(image, frame: frame, app: app)
        assertTextContrast(pixels, message: "Focused metadata must remain readable in both native and opaque highlights.")
    }

    private func assertSummaryTextContrast(
        _ image: CGImage, containing expected: [String], in frame: CGRect, app: XCUIApplication
    ) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        for text in expected {
            let observation = try XCTUnwrap(request.results?.first {
                guard $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(text) == true else { return false }
                let center = CGPoint(x: $0.boundingBox.midX * app.frame.width,
                                     y: (1 - $0.boundingBox.midY) * app.frame.height)
                return frame.contains(center)
            }, "The focused card must actually display readable text containing \(text).")
            let bounds = observation.boundingBox
            let textFrame = CGRect(x: bounds.minX * app.frame.width, y: (1 - bounds.maxY) * app.frame.height,
                                   width: bounds.width * app.frame.width, height: bounds.height * app.frame.height)
            assertTextContrast(try pixels(image, frame: textFrame, app: app),
                               message: "Focused summary text must retain contrast: \(text)")
        }
    }

    private func assertTextContrast(_ pixels: [UInt8], message: String) {
        let luminances = stride(from: 0, to: pixels.count, by: 4).map { offset -> Double in
            let channels = (0..<3).map { channel -> Double in
                let value = Double(pixels[offset + channel]) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }.sorted()
        XCTAssertFalse(luminances.isEmpty)
        guard !luminances.isEmpty else { return }
        let contrast = (luminances[luminances.count * 95 / 100] + 0.05)
            / (luminances[luminances.count * 5 / 100] + 0.05)
        XCTAssertGreaterThan(contrast, 3, message)
    }

    private func changedPixelFraction(
        _ before: CGImage, _ after: CGImage, frame: CGRect, app: XCUIApplication
    ) throws -> Double {
        let first = try pixels(before, frame: frame, app: app)
        let second = try pixels(after, frame: frame, app: app)
        XCTAssertEqual(first.count, second.count)
        guard first.count == second.count, !first.isEmpty else { return 0 }
        let changed = stride(from: 0, to: first.count, by: 4).filter { offset in
            // Native glass on a light backdrop can lift each channel by only 4-5 steps.
            (0..<3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(second[offset + $1])) } > 12
        }.count
        return Double(changed) / Double(first.count / 4)
    }

    private func pixels(_ image: CGImage, frame: CGRect, app: XCUIApplication) throws -> [UInt8] {
        let scale = CGFloat(image.width) / app.frame.width
        let region = frame.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return pixels
    }

    private func recordScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if app.buttons["Done"].exists {
            let doneFrame = XCTAttachment(string: app.buttons["Done"].firstMatch.frame.debugDescription)
            doneFrame.name = "\(name)-button-frame"
            doneFrame.lifetime = .keepAlways
            add(doneFrame)
        }
    }

    private func launch(extra: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--family-guidance-fixture"] + (extra.map { [$0] } ?? [])
        app.launch()
        XCTAssertTrue(app.staticTexts["family-guidance-fixture-ready"].waitForExistence(timeout: 15))
        return app
    }
}
