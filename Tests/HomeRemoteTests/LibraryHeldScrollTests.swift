import XCTest

@MainActor
final class LibraryHeldScrollTests: XCTestCase {
    func testNativeFramedHoldTraversesPreloadedAndPagedLibraries() throws {
        try exerciseHold(borderless: false, preloaded: true)
        try exerciseHold(borderless: false, preloaded: false)
    }

    func testNativeBorderlessHoldTraversesPreloadedAndPagedLibraries() throws {
        try exerciseHold(borderless: true, preloaded: true)
        try exerciseHold(borderless: true, preloaded: false)
    }

    func testNativeHoldKeepsScrollingWhileTheNextMetadataPagesArePending() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-held-scroll-fixture", "--borderless", "--delayed-library-page"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["library-hold-status"].waitForExistence(timeout: 15))
        for _ in 0..<4 where focusedIndex(in: app) == nil { XCUIRemote.shared.press(.down) }
        XCTAssertNotNil(focusedIndex(in: app))
        let before = try scrollPosition(in: app)
        XCUIRemote.shared.press(.down, forDuration: 5)
        let after = try scrollPosition(in: app)
        XCTAssertGreaterThan(after.offset - before.offset, after.viewport * 3)
        XCTAssertTrue(app.staticTexts["library-hold-status"].label.contains("loaded=28"))
        XCTAssertTrue(app.otherElements["List index"].firstMatch.hasFocus)
    }

    private func exerciseHold(borderless: Bool, preloaded: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-held-scroll-fixture"]
            + (borderless ? ["--borderless"] : [])
            + (preloaded ? ["--all-library-items"] : [])
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["library-hold-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        for _ in 0..<4 where focusedIndex(in: app) == nil {
            XCUIRemote.shared.press(.down)
        }
        let initial = try XCTUnwrap(focusedIndex(in: app), "The initial card must receive actual focus.")
        if preloaded {
            let horizontal: XCUIRemote.Button = initial % 6 == 5 ? .left : .right
            XCUIRemote.shared.press(horizontal)
            XCTAssertEqual(focusedIndex(in: app), initial + (horizontal == .right ? 1 : -1))
            XCUIRemote.shared.press(horizontal == .right ? .left : .right)
            XCTAssertEqual(focusedIndex(in: app), initial)
            XCUIRemote.shared.press(.down)
            XCTAssertEqual(focusedIndex(in: app), initial + 6)
            XCUIRemote.shared.press(.up)
            XCTAssertEqual(focusedIndex(in: app), initial)
        }
        let before = try scrollPosition(in: app)
        XCTAssertGreaterThan(before.viewport, 0)

        XCUIRemote.shared.press(.down, forDuration: 5)

        let after = try scrollPosition(in: app)
        XCTAssertGreaterThan(after.offset - before.offset, after.viewport * 3,
                             "Holding Down must continue past the initial native cards.")
        let nativeIndex = app.otherElements["List index"].firstMatch
        XCTAssertTrue(focusedIndex(in: app) != nil || (nativeIndex.exists && nativeIndex.hasFocus),
                      "The grid or the native fast-scroll index must still own focus.")
        if nativeIndex.exists && nativeIndex.hasFocus {
            XCUIRemote.shared.press(.left)
        }
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.focusedIndex(in: app) != nil },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 4), .completed,
                       "Leaving fast scroll must restore a real card. \(app.debugDescription)")
        let selectedIndex = try XCTUnwrap(focusedIndex(in: app))
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(
            app.staticTexts["library-hold-selection"].label,
            String(format: "%@: Library item %03d", selectedIndex < 250 ? "A" : "M", selectedIndex)
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "library-hold-\(borderless)-\(preloaded)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("LIBRARY_HOLD borderless=\(borderless) preloaded=\(preloaded) offset=\(before.offset)->\(after.offset) \(status.label)")
    }

    private func scrollPosition(in app: XCUIApplication) throws -> (offset: Double, viewport: Double) {
        let parts = app.staticTexts["library-scroll-position"].label.split(separator: "|")
        XCTAssertEqual(parts.count, 2)
        return (try XCTUnwrap(parts.first.flatMap { Double($0) }),
                try XCTUnwrap(parts.last.flatMap { Double($0) }))
    }

    private func focusedIndex(in app: XCUIApplication) -> Int? {
        do {
            return focusedIndex(in: try app.snapshot())
        } catch {
            XCTFail("Could not capture actual focus: \(error)")
            return nil
        }
    }

    private func focusedIndex(in snapshot: any XCUIElementSnapshot) -> Int? {
        for child in snapshot.children {
            if let index = focusedIndex(in: child) { return index }
        }
        return snapshot.hasFocus ? captionIndex(in: snapshot) : nil
    }

    private func captionIndex(in snapshot: any XCUIElementSnapshot) -> Int? {
        if let range = snapshot.label.range(of: "Library item "),
           let index = Int(snapshot.label[range.upperBound...].prefix(while: \.isNumber)) {
            return index
        }
        for child in snapshot.children {
            if let index = captionIndex(in: child) { return index }
        }
        return nil
    }
}
