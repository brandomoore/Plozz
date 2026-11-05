import XCTest
import UIKit

@MainActor
final class DetailInformationInteractionTests: XCTestCase {
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
            if let testRun, testRun.failureCount > 0 {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.lifetime = .keepAlways
                add(tree)
            }
            app.terminate()
            app = nil
        }
        super.tearDown()
    }

    func testCastMoreIncludesPeopleOutsideThePreviewAndKeepsNavigation() {
        launch()
        reveal(app.buttons["detail-cast-more"])
        app.buttons["detail-cast-more"].tap()
        XCTAssertTrue(app.navigationBars["Cast"].waitForExistence(timeout: 5))
        recordMoreScreenshot("shared-reader-cast-mobile")
        let last = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Person 40")).firstMatch
        reveal(last)
        last.tap()
        XCTAssertTrue(app.staticTexts["Person 40"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Cast"].exists)
    }

    func testCrewMorePreservesTheLastDirector() {
        launch()
        let more = app.buttons["detail-crew-directors-more"]
        reveal(more)
        more.tap()
        XCTAssertTrue(app.navigationBars["Crew"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.collectionViews.count, 0, "Expanded facts use the unboxed reader, not grouped list cells.")
        recordMoreScreenshot("shared-reader-crew-mobile")
        reveal(app.staticTexts["Director 60"])
        XCTAssertTrue(app.staticTexts["Director 60"].isHittable)
    }

    func testSingleLongValueGetsMoreWithoutAnOversizedList() {
        launch(["--detail-single-long-value"])
        let more = app.buttons["detail-details-original-title-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), app.debugDescription)
        let value = String(repeating: "A very long original title ", count: 40)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedValue = app.scrollViews.staticTexts
            .matching(NSPredicate(format: "label == %@", value)).firstMatch
        XCTAssertTrue(expandedValue.waitForExistence(timeout: 5), app.debugDescription)
        recordMoreScreenshot("shared-reader-long-details-mobile")
    }

    private func recordMoreScreenshot(_ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testCrewReaderKeepsAllNamesAtAccessibilitySizes() {
        launch(["--detail-layout-large-type"])
        let more = app.buttons["detail-crew-directors-more"]
        reveal(more)
        more.tap()
        XCTAssertTrue(app.navigationBars["Crew"].waitForExistence(timeout: 5))
        let last = app.staticTexts["Director 60"]
        reveal(last)
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxX, app.frame.maxX)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Crew"].exists)
    }

    func testFamilyGuidanceTileOpensAndDismissesItsDetails() {
        launch(["--detail-layout-guidance"])
        checkGuidanceSheet()
    }

    func testCompactFamilyGuidanceTileKeepsItsFullDetails() {
        launch(["--detail-layout-ratings-1-guide"])
        checkGuidanceSheet()
    }

    func testRatingGridUsesItsAllocatedColumnWidth() {
        for fixture in ["rich", "ratings-1-guide", "ratings-5-guide"] {
            launch(["--detail-layout-\(fixture)"])
            let trailingTile = app.descendants(matching: .any)[
                fixture == "rich" ? "detail-rating-tmdb" : "family-guidance-tile"
            ].firstMatch
            XCTAssertTrue(trailingTile.waitForExistence(timeout: 10))
            if fixture != "rich" { reveal(trailingTile) }
            let width = min(1120, app.frame.width - 48)
            XCTAssertEqual(trailingTile.frame.maxX, app.frame.midX + width / 2, accuracy: 1,
                           "Every multi-tile grid must reach its reading column's trailing edge.")
            app.terminate()
        }
    }

    func testSingleScoreUsesHalfTabletColumnWithoutWideningPhoneTile() {
        launch(["--detail-layout-lupin"])
        let score = app.descendants(matching: .any)["detail-rating-tmdb"].firstMatch
        let about = app.descendants(matching: .any)["detail-about"].firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        XCTAssertTrue(about.exists)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertEqual(score.frame.width, max(160, (about.frame.width - 32) / 2), accuracy: 1)
            XCTAssertGreaterThan(score.frame.minX, about.frame.maxX)
            XCTAssertEqual(score.frame.minY, about.frame.minY, accuracy: 1)
            XCTAssertEqual(score.frame.maxY, about.frame.maxY, accuracy: 1)
            let details = app.staticTexts["Details"].firstMatch
            XCTAssertEqual(details.frame.minX, score.frame.minX, accuracy: 1)
            XCTAssertGreaterThan(details.frame.minY, score.frame.maxY)
        } else {
            XCTAssertEqual(score.frame.width, 160, accuracy: 1,
                           "The compact phone score must retain its existing width.")
        }
    }

    func testLandscapeInformationUsesReadableSectionColumns() throws {
        try checkInformationLayout(orientation: .landscapeLeft, cases: [
            "discover", "rich", "lupin"
        ])
    }

    func testLandscapeGuidanceKeepsReadableSectionColumns() throws {
        try checkInformationLayout(orientation: .landscapeLeft, cases: [
            "ratings-1-guide", "ratings-5-guide"
        ])
    }

    func testPairedFactsKeepLongValuesFullWidthAndStackAtAccessibilitySizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let longRating = "A deliberately long provider rating description that needs the full reading column"
        let example: [String: Any] = ["item": [
            "id": "facts", "title": "Title", "kind": "movie", "productionYear": 2020, "runtime": 2640,
            "officialRating": longRating,
            "originalTitle": "An original title", "genres": ["Drama"]
        ]]
        try JSONSerialization.data(withJSONObject: example).write(to: url)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: url)) }
        app.launchEnvironment["PLOZZ_DETAIL_EXAMPLE_PATH"] = url.path
        defer { app.launchEnvironment.removeValue(forKey: "PLOZZ_DETAIL_EXAMPLE_PATH") }
        for largeText in [false, true] {
            launch(largeText ? ["--detail-layout-large-type"] : [])
            let year = app.staticTexts["Year"].firstMatch
            let runtime = app.staticTexts["Runtime"].firstMatch
            let rating = app.staticTexts["Content Rating"].firstMatch
            XCTAssertTrue(year.waitForExistence(timeout: 10))
            if !largeText, UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertEqual(year.frame.minY, runtime.frame.minY, accuracy: 1)
                XCTAssertGreaterThan(runtime.frame.minX, year.frame.maxX)
                let columnWidth = (min(1120, app.frame.width - 48) - 32) / 2
                XCTAssertGreaterThan(app.staticTexts[longRating].firstMatch.frame.width, columnWidth / 2,
                                     "A long value must use the full reading column, not an orphan half-width cell.")
            } else {
                XCTAssertEqual(year.frame.minX, runtime.frame.minX, accuracy: 1)
                XCTAssertGreaterThan(runtime.frame.minY, year.frame.maxY)
            }
            XCTAssertEqual(rating.frame.minX, year.frame.minX, accuracy: 1)
            XCTAssertGreaterThan(rating.frame.minY, runtime.frame.maxY)
            let originalTitle = app.staticTexts["Original Title"].firstMatch
            reveal(originalTitle)
            XCTAssertEqual(originalTitle.frame.minX, year.frame.minX, accuracy: 1)
            XCTAssertGreaterThan(originalTitle.frame.minY, rating.frame.maxY)
            app.terminate()
        }
    }

    func testPortraitSparseAndReleaseInformationUseTheSameGrid() throws {
        try checkInformationLayout(orientation: .portrait, cases: [
            "discover", "personal", "upcoming"
        ])
    }

    func testSpoilerProtectionCoversTheEntireRatingGridUntilRevealed() {
        launch(["--detail-layout-ratings-1-guide", "--detail-layout-hide-ratings"])
        let prompt = app.buttons["Show Ratings"]
        let score = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail-rating-")).firstMatch
        reveal(prompt)
        XCTAssertFalse(score.exists)
        XCTAssertFalse(app.buttons["family-guidance-tile"].isHittable)
        prompt.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(score.waitForExistence(timeout: 5))
        checkGuidanceSheet()
    }

    private func checkGuidanceSheet() {
        let tile = app.buttons["family-guidance-tile"]
        reveal(tile)
        tile.tap()
        let sheet = app.navigationBars["Family guidance"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "language"))
            .firstMatch.waitForExistence(timeout: 5), "The compact tile must retain its full guidance in the sheet.")
        sheet.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(tile.isHittable)
    }

    private func checkInformationLayout(orientation: UIDeviceOrientation, cases: [String]) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Regular-width iPad layout coverage.")
        let previous = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = previous }
        XCUIDevice.shared.orientation = orientation
        for fixture in cases {
            launch(["--detail-layout-\(fixture)"])
            let oriented = NSPredicate { _, _ in
                (self.app.frame.width > self.app.frame.height) == orientation.isLandscape
            }
            expectation(for: oriented, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            let heading = app.staticTexts[fixture == "personal" ? "Playback" : "About"].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
            let contentWidth = min(1120, app.frame.width - 48)
            XCTAssertEqual(heading.frame.minX, app.frame.midX - contentWidth / 2, accuracy: 1)
            let columnWidth = contentWidth >= 632 ? (contentWidth - 32) / 2 : contentWidth
            if fixture != "personal" {
                let about = app.descendants(matching: .any)["detail-about"].firstMatch
                XCTAssertTrue(about.exists)
                XCTAssertEqual(about.frame.width, columnWidth, accuracy: 1)
            }
            if fixture == "discover" || fixture.hasPrefix("ratings-") {
                let year = app.staticTexts["Year"].firstMatch
                let runtime = app.staticTexts["Runtime"].firstMatch
                let genres = app.staticTexts["Genres"].firstMatch
                let details = app.staticTexts["Details"].firstMatch
                XCTAssertEqual(year.frame.minX, details.frame.minX, accuracy: 1)
                let paired = (columnWidth - 16) / 2 >= 160
                XCTAssertEqual(runtime.frame.minX, year.frame.minX + (paired ? (columnWidth + 16) / 2 : 0), accuracy: 1)
                XCTAssertEqual(genres.frame.minX, year.frame.minX, accuracy: 1)
                if paired {
                    XCTAssertEqual(runtime.frame.minY, year.frame.minY, accuracy: 1)
                } else {
                    XCTAssertGreaterThan(runtime.frame.minY, year.frame.maxY)
                }
                let crew = app.staticTexts["Crew"].firstMatch
                if columnWidth < contentWidth {
                    if fixture == "discover" {
                        XCTAssertEqual(details.frame.minX, heading.frame.minX + columnWidth + 32, accuracy: 1)
                        XCTAssertEqual(crew.frame.minX, heading.frame.minX, accuracy: 1)
                    } else {
                        XCTAssertEqual(crew.frame.minX, heading.frame.minX + columnWidth + 32, accuracy: 1)
                        XCTAssertEqual(crew.frame.minY, details.frame.minY, accuracy: 1)
                    }
                } else {
                    XCTAssertEqual(crew.frame.minX, heading.frame.minX, accuracy: 1)
                    XCTAssertGreaterThan(crew.frame.minY, genres.frame.maxY)
                }
            }
            if fixture.hasPrefix("ratings-") {
                let guide = app.buttons["family-guidance-tile"]
                reveal(guide)
                XCTAssertEqual(guide.frame.maxX, app.frame.midX + contentWidth / 2, accuracy: 1)
            }
            if fixture == "discover" {
                XCTAssertFalse(app.staticTexts["Playback"].exists)
            }
            let image = XCUIScreen.main.screenshot().image
            let screen = app.frame
            let upright = UIGraphicsImageRenderer(size: screen.size).image { context in
                if screen.width > screen.height, let source = image.cgImage, source.width < source.height {
                    context.cgContext.translateBy(x: 0, y: screen.height)
                    context.cgContext.rotate(by: -.pi / 2)
                    UIImage(cgImage: source).draw(in: CGRect(x: 0, y: 0, width: screen.height, height: screen.width))
                } else {
                    image.draw(in: CGRect(origin: .zero, size: screen.size))
                }
            }
            let attachment = XCTAttachment(image: upright)
            attachment.name = "detail-readable-\(orientation.isLandscape ? "landscape" : "portrait")-\(fixture)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func launch(_ options: [String] = []) {
        app.launchArguments = ["--detail-information-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + options
        app.launch()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
