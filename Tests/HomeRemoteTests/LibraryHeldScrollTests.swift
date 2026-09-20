import XCTest

@MainActor
final class LibraryHeldScrollTests: XCTestCase {
    func testNativeContextMenuNavigationRestoresTheSameScrolledCell() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-held-scroll-fixture", "--library-interaction-fixture", "--all-library-items"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["library-hold-status"].waitForExistence(timeout: 15))
        for _ in 0..<4 where focusedIndex(in: app) == nil { XCUIRemote.shared.press(.down) }
        for _ in 0..<6 { XCUIRemote.shared.press(.down) }
        let selected = try XCTUnwrap(focusedIndex(in: app))
        Thread.sleep(forTimeInterval: 0.6)
        let offset = try scrollPosition(in: app).offset
        XCTAssertGreaterThan(offset, 500)
        XCUIRemote.shared.press(.select, forDuration: 1)
        let menuAction = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Go to Movie'")).firstMatch
        XCTAssertTrue(menuAction.waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["library-detail-identity"].exists, "Long press must not activate the cell.")
        XCUIRemote.shared.press(.select)
        let detail = app.staticTexts["library-detail-identity"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "held-\(selected)|fixture")
        XCUIRemote.shared.press(.menu)
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.focusedIndex(in: app) == selected }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed, app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try scrollPosition(in: app).offset, offset, accuracy: 24,
                       "Native focus may adjust a few points, but must preserve the scrolled row.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "held-\(selected)|fixture")
    }

    func testNativeCollectionModeAndPagedMemberNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--library-held-scroll-fixture", "--library-interaction-fixture", "--borderless"]
        app.launch()
        defer { app.terminate() }
        let collections = app.buttons["library-content-mode-collections"]
        XCTAssertTrue(collections.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<8 where !collections.hasFocus {
            if let current = focusedFrame(in: try app.snapshot()) {
                let target = collections.frame
                XCUIRemote.shared.press(current.midY > target.maxY ? .up : (current.midX > target.midX ? .left : .right))
            } else {
                XCUIRemote.shared.press(.up)
            }
        }
        XCTAssertTrue(collections.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        let firstCollection = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Collection item 0'")).firstMatch
        XCTAssertTrue(firstCollection.waitForExistence(timeout: 5))
        for _ in 0..<4 where focusedLabel(in: try app.snapshot(), prefix: "Collection item ") == nil {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertNotNil(focusedLabel(in: try app.snapshot(), prefix: "Collection item "))
        XCUIRemote.shared.press(.select)
        let member = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Member item '")).firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 5))
        for _ in 0..<4 where focusedLabel(in: try app.snapshot(), prefix: "Member item ") == nil {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertNotNil(focusedLabel(in: try app.snapshot(), prefix: "Member item "))
        XCUIRemote.shared.press(.down, forDuration: 5)
        let index = app.otherElements["List index"].firstMatch
        if index.exists && index.hasFocus { XCUIRemote.shared.press(.left) }
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let snapshot = try? app.snapshot() else { return false }
                return self.focusedLabel(in: snapshot, prefix: "Member item ") != nil
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        let label = try XCTUnwrap(focusedLabel(in: try app.snapshot(), prefix: "Member item "))
        let selected = try XCTUnwrap(Int(label.dropFirst("Member item ".count)))
        XCTAssertGreaterThan(selected, 30)
        XCUIRemote.shared.press(.select)
        let detail = app.staticTexts["library-detail-identity"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.label, "member-\(selected)|fixture")
    }

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
        let nativeIndex = app.otherElements["List index"].firstMatch
        let indexFocused = nativeIndex.exists && nativeIndex.hasFocus
        let loadingFocused = focusedLabel(in: try app.snapshot(), prefix: "Loading") != nil
        XCTAssertTrue(indexFocused || loadingFocused)
        if indexFocused { XCUIRemote.shared.press(.left) }
        Thread.sleep(forTimeInterval: 0.6)
        let exited = try scrollPosition(in: app)
        XCTAssertGreaterThan(exited.offset, after.offset - after.viewport,
                             "Leaving fast scroll must not return to the old loaded frontier.")
        XCUIRemote.shared.press(.select)
        let selection = app.staticTexts["library-hold-selection"]
        XCTAssertFalse(selection.exists && !selection.label.isEmpty, "A loading slot must not open an item.")
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.staticTexts["library-hold-status"].label.contains("loaded=28")
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(try scrollPosition(in: app).offset, after.offset - after.viewport,
                             "Metadata arriving must not restore offscreen remembered focus.")
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
        let peakCells = try XCTUnwrap(Int(app.staticTexts["library-peak-cells"].label))
        XCTAssertGreaterThan(peakCells, 0)
        XCTAssertLessThan(peakCells, 60, "The library must recycle cells rather than retain its full wall.")
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

    private func focusedFrame(in snapshot: any XCUIElementSnapshot) -> CGRect? {
        for child in snapshot.children {
            if let frame = focusedFrame(in: child) { return frame }
        }
        return snapshot.hasFocus ? snapshot.frame : nil
    }

    private func focusedLabel(in snapshot: any XCUIElementSnapshot, prefix: String) -> String? {
        for child in snapshot.children {
            if let label = focusedLabel(in: child, prefix: prefix) { return label }
        }
        return snapshot.hasFocus && snapshot.label.hasPrefix(prefix) ? snapshot.label : nil
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
