import XCTest
import UIKit
import Vision

@MainActor
final class SearchKeyboardInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    private var results: XCUIElement {
        app.scrollViews.containing(.staticText, identifier: "Keyboard result 01").firstMatch
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testBlankSpaceDismissesKeyboardBeforeEnteringQuery() {
        let field = launch()
        focus(field)
        tapBelowHeader(field)
        assertKeyboardDismissed()
        XCTAssertFalse(app.buttons["Clear search"].exists)
        focus(field)
        field.typeText("empty")
        XCTAssertEqual(field.value as? String, "empty")
    }

    func testSearchArtworkCaptionsAndHeadingsAlignWithInput() throws {
        for arguments in [[], ["--search-framed"]] {
            let field = launch(arguments: arguments)
            focus(field)
            field.typeText("alignment")
            XCTAssertTrue(app.staticTexts["Alpha"].firstMatch.waitForExistence(timeout: 8))
            app.staticTexts["Movies"].tap()
            assertKeyboardDismissed()
            XCTAssertTrue(field.exists)
            XCTAssertFalse(app.buttons["Play"].exists)
            let screenshot = app.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            for title in ["Movies", "Alpha"] {
                let observation = try XCTUnwrap(request.results?.first {
                    $0.topCandidates(1).first?.string == title
                }, "Missing rendered \(title)")
                XCTAssertEqual(try renderedLeadingEdge(of: observation, in: image), 16, accuracy: 3, title)
            }
            let artwork = app.images["play.rectangle"].firstMatch
            XCTAssertEqual(artwork.frame.minX, 16, accuracy: 1)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "search-leading-alignment-\(arguments.isEmpty ? "borderless" : "framed")"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private func renderedLeadingEdge(of observation: VNRecognizedTextObservation, in image: CGImage) throws -> CGFloat {
        // Vision's line boxes include variable whitespace; measure the visible glyphs inside them.
        let bounds = observation.boundingBox
        let rect = CGRect(
            x: bounds.minX * CGFloat(image.width), y: (1 - bounds.maxY) * CGFloat(image.height),
            width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height)
        ).integral
        let crop = try XCTUnwrap(image.cropping(to: rect))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let leading = try XCTUnwrap((0..<crop.width).first { x in
            (0..<crop.height).contains { y in
                let offset = (y * crop.width + x) * 4
                return pixels[offset] > 192 && pixels[offset + 1] > 192 && pixels[offset + 2] > 192
            }
        })
        return (rect.minX + CGFloat(leading)) * app.frame.width / CGFloat(image.width)
    }

    func testContentTapPreservesQueryAcrossSearchStates() {
        for (query, marker) in [
            ("empty", "No Results"), ("slow", "Searching"),
            ("failed", "Search unavailable"), ("result", "Keyboard result 01")
        ] {
            let field = launch()
            focus(field)
            field.typeText(query)
            XCTAssertTrue(app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", marker)
            ).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            if query == "result" {
                app.staticTexts["Movies"].tap()
            } else {
                tapBelowHeader(field)
            }
            assertKeyboardDismissed()
            XCTAssertEqual(field.value as? String, query)
            app.terminate()
        }
    }

    func testFieldAndClearButtonKeepKeyboardAvailable() {
        let field = launch()
        focus(field)
        field.typeText("empty")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        field.typeText("result")
        XCTAssertEqual(field.value as? String, "result")
    }

    func testRetryStillRunsOnTheFirstTap() {
        let field = launch()
        focus(field)
        field.typeText("retry")
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        retry.tap()
        XCTAssertTrue(app.staticTexts["Keyboard result 01"].waitForExistence(timeout: 8))
        assertKeyboardDismissed()
        XCTAssertEqual(field.value as? String, "retry")
    }

    func testResultStillOpensOnTheFirstTap() {
        let field = launch()
        focus(field)
        field.typeText("result")
        let result = app.staticTexts["Keyboard result 01"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(field.wait(for: \.exists, toEqual: false, timeout: 5), app.debugDescription)
        assertKeyboardDismissed()
    }

    func testScrollingDismissesKeyboardWithoutClearingQuery() {
        let field = launch()
        focus(field)
        field.typeText("many")
        XCTAssertTrue(app.staticTexts["Keyboard result 01"].waitForExistence(timeout: 8))
        results.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)
            ))
        assertKeyboardDismissed()
        XCTAssertEqual(field.value as? String, "many")
    }

    func testSwipeBackRestoresSearchQueryAndResults() {
        let field = launch()
        focus(field)
        field.typeText("result")
        let result = app.staticTexts["Keyboard result 01"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 8))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ))
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "result")
        XCTAssertTrue(result.isHittable)
        assertKeyboardDismissed()
    }

    func testResultsScrollUnderTheTransparentHeader() {
        let field = launch()
        focus(field)
        field.typeText("many")
        let first = app.staticTexts["Keyboard result 01"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        app.staticTexts["Movies"].tap()
        assertKeyboardDismissed()
        let headerFrame = field.frame
        results.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)
            ))
        XCTAssertEqual(field.frame.minY, headerFrame.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["Cancel search"].isHittable)
        let cards = results.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Keyboard result"))
        XCTAssertTrue(cards.allElementsBoundByIndex.contains {
            $0.frame.minY < headerFrame.maxY && $0.frame.maxY > headerFrame.minY
        }, app.debugDescription)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "search-results-behind-header"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCancelRestoresTheHeaderAndSettingsOpensOnTheFirstTap() {
        let field = launch()
        focus(field)
        field.typeText("empty")
        XCTAssertFalse(app.buttons["search-settings-avatar"].isHittable)
        app.buttons["Cancel search"].tap()
        assertKeyboardDismissed()
        XCTAssertFalse(app.buttons["Clear search"].exists)
        app.buttons["search-settings-avatar"].tap()
        XCTAssertTrue(app.staticTexts["search-fixture-settings"].waitForExistence(timeout: 5))
    }

    func testSearchSurfaceChangesToGlassAndReturnsToFlatWithoutReplacingTheField() throws {
        let field = launch()
        let resting = try surfaceColor(field, name: "search-flat")
        let restingFrame = field.frame
        focus(field)
        let active = try surfaceColor(field, name: "search-glass")
        XCTAssertLessThan(field.frame.minY, restingFrame.minY - 30, "Active search moves up into the title's space.")
        XCTAssertTrue(app.buttons["Cancel search"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["Cancel search"].frame.height, 44)
        XCTAssertGreaterThan(colorDistance(resting, active), 8, "Focus must visibly replace the flat fill with glass.")
        field.typeText("empty")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "No Results")
        ).firstMatch.waitForExistence(timeout: 8))
        tapBelowHeader(field)
        assertKeyboardDismissed()
        let queried = try surfaceColor(field, name: "search-glass-with-query")
        XCTAssertLessThan(colorDistance(active, queried), 5, "A retained query keeps the active search surface.")
        focus(field)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        tapBelowHeader(field)
        assertKeyboardDismissed()
        let restored = try surfaceColor(field, name: "search-flat-restored")
        XCTAssertLessThan(colorDistance(resting, restored), 3)
        XCTAssertEqual(field.frame.minY, restingFrame.minY, accuracy: 1)
        focus(field)
        field.typeText("result")
        XCTAssertEqual(field.value as? String, "result", "Changing surfaces must not tear down editing.")
    }

    func testReducedTransparencyKeepsSearchFlatWhileEditing() throws {
        let field = launch(arguments: ["--search-opaque"])
        let resting = try surfaceColor(field, name: "search-opaque-rest")
        focus(field)
        let active = try surfaceColor(field, name: "search-opaque-editing")
        XCTAssertLessThan(colorDistance(resting, active), 3)
        field.typeText("empty")
        XCTAssertEqual(field.value as? String, "empty")
    }

    private func surfaceColor(_ field: XCUIElement, name: String) throws -> [UInt8] {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        // Sample the surface above the text, away from its caret and glyphs.
        let area = CGRect(x: field.frame.midX, y: field.frame.minY - 7, width: 8, height: 3)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: area.minX * scale, y: area.minY * scale,
            width: area.width * scale, height: area.height * scale
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Array(pixel.prefix(3))
    }

    private func colorDistance(_ first: [UInt8], _ second: [UInt8]) -> Int {
        zip(first, second).map { abs(Int($0) - Int($1)) }.reduce(0, +)
    }

    @discardableResult
    private func launch(arguments: [String] = []) -> XCUIElement {
        app.launchArguments = ["--search-keyboard-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        let field = app.textFields["Search your libraries"]
        XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        return field
    }

    private func focus(_ field: XCUIElement) {
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func tapBelowHeader(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 40)).tap()
    }

    private func assertKeyboardDismissed() {
        XCTAssertTrue(app.keyboards.firstMatch.wait(for: \.exists, toEqual: false, timeout: 5))
    }
}
