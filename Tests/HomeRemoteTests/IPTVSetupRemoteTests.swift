import UIKit
import XCTest

@MainActor
final class IPTVSetupRemoteTests: XCTestCase {
    func testAdvancedDisclosureExpandsAndCollapsesWithoutMovingFocus() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--iptv-setup-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let advanced = app.buttons["iptv-advanced-options"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["iptv-authentication"].exists)
        XCTAssertFalse(app.staticTexts["HTTP is unencrypted. Use HTTPS when available."].exists)
        for _ in 0..<8 {
            if advanced.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        assertFocused(advanced)
        try captureFocusedRow(advanced, in: app, name: "advanced-collapsed")
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(advanced.value as? String, "Expanded")
        assertFocused(advanced)
        try captureFocusedRow(advanced, in: app, name: "advanced-expanded")
        let authentication = app.buttons["iptv-authentication"]
        XCTAssertTrue(authentication.exists, app.debugDescription)
        XCUIRemote.shared.press(.down)
        assertFocused(authentication)
        try captureFocusedRow(authentication, in: app, name: "authentication")
        XCUIRemote.shared.press(.select)
        let basic = app.cells.containing(.any, identifier: "Username and password").firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.down)
        assertFocused(basic)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        assertFocused(authentication)
        XCUIRemote.shared.press(.up)
        assertFocused(advanced)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        assertFocused(advanced)
        XCTAssertFalse(authentication.exists)
        XCTAssertFalse(app.textFields["Guide URL (optional)"].exists)
    }

    func testGuideAndHeaderActionsHavePaddedFocusRows() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--iptv-setup-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let advanced = app.buttons["iptv-advanced-options"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), app.debugDescription)
        focusDown(to: advanced)
        XCUIRemote.shared.press(.select)
        let addGuide = app.buttons["Add guide"]
        focusDown(to: addGuide)
        try captureFocusedRow(addGuide, in: app, name: "add-guide")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.up)
        let removeGuide = app.buttons["Remove guide"]
        assertFocused(removeGuide)
        try captureFocusedRow(removeGuide, in: app, name: "remove-guide")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(removeGuide.exists)

        let addPlaylistHeader = app.buttons.matching(identifier: "Add header").element(boundBy: 0)
        focusDown(to: addPlaylistHeader)
        try captureFocusedRow(addPlaylistHeader, in: app, name: "add-playlist-header")
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.up)
        let removeHeader = app.buttons["Remove header"]
        assertFocused(removeHeader)
        try captureFocusedRow(removeHeader, in: app, name: "remove-playlist-header")
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(removeHeader.exists)

        let addGuideHeader = app.buttons.matching(identifier: "Add header").element(boundBy: 1)
        focusDown(to: addGuideHeader)
        try captureFocusedRow(addGuideHeader, in: app, name: "add-guide-header")
    }

    private func focusDown(to element: XCUIElement) {
        for _ in 0..<16 {
            if element.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        assertFocused(element)
    }

    private func captureFocusedRow(
        _ element: XCUIElement, in app: XCUIApplication, name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        assertFocused(element, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 74, file: file, line: line)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "iptv-focus-\(name)-screen"
        screen.lifetime = .keepAlways
        add(screen)
        let screenshot = element.screenshot()
        let row = XCTAttachment(screenshot: screenshot)
        row.name = "iptv-focus-\(name)-row"
        row.lifetime = .keepAlways
        add(row)
        let image = try XCTUnwrap(screenshot.image.cgImage, file: file, line: line)
        let scale = CGFloat(image.width) / element.frame.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let fill = try XCTUnwrap(pixelBounds(bytes, width: image.width, region: bounds) {
            min($0, $1, $2) >= 245
        }, "The focused row must have a visible fill.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fill.height / scale, 74, file: file, line: line)
        // Exclude rounded corners, not the text/icon margin being measured.
        let interior = fill.insetBy(dx: 6 * scale, dy: 6 * scale)
        let ink = try XCTUnwrap(pixelBounds(bytes, width: image.width, region: interior) {
            max($0, $1, $2) < 100
        }, "Text and icons must remain visible against the focus fill.", file: file, line: line)
        XCTAssertGreaterThanOrEqual((ink.minX - fill.minX) / scale, 12, file: file, line: line)
        XCTAssertGreaterThanOrEqual((fill.maxX - ink.maxX) / scale, 12, file: file, line: line)
        XCTAssertGreaterThanOrEqual((ink.minY - fill.minY) / scale, 14, file: file, line: line)
        XCTAssertGreaterThanOrEqual((fill.maxY - ink.maxY) / scale, 14, file: file, line: line)
    }

    private func pixelBounds(
        _ bytes: [UInt8], width: Int, region: CGRect,
        matching predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> CGRect? {
        var result = CGRect.null
        for y in Int(ceil(region.minY))..<Int(floor(region.maxY)) {
            for x in Int(ceil(region.minX))..<Int(floor(region.maxX)) {
                let index = (y * width + x) * 4
                if predicate(bytes[index], bytes[index + 1], bytes[index + 2]) {
                    result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return result.isNull ? nil : result
    }

    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            element.exists && (element.hasFocus || element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5),
            .completed, element.debugDescription, file: file, line: line
        )
    }
}
