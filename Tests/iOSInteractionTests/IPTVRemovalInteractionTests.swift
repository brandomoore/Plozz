import XCTest

@MainActor
final class IPTVRemovalInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0, app.state == .runningForeground {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testRemovingAdditionalGuidesKeepsTheOtherRowsAndAllowsAddingAgain() {
        verifyRemoval(
            arguments: [], field: "Additional guide URL", remove: "Remove guide", add: "Add guide",
            values: (2...4).map { "https://guide.example.test/\($0).xml" }
        )
    }

    func testRemovingPlaylistHeadersKeepsTheOtherRowsAndAllowsAddingAgain() {
        verifyRemoval(
            arguments: ["--playlist-headers"], field: "Header name", remove: "Remove header", add: "Add header",
            values: (1...3).map { "X-Guide-\($0)" }
        )
    }

    func testRemovingGuideHeadersKeepsTheOtherRowsAndAllowsAddingAgain() {
        verifyRemoval(
            arguments: ["--guide-headers"], field: "Header name", remove: "Remove header", add: "Add header",
            values: (1...3).map { "X-Guide-\($0)" }
        )
    }

    private func verifyRemoval(arguments: [String], field: String, remove: String, add: String, values: [String]) {
        app.launchArguments = ["--iptv-removal-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        let advanced = app.switches["Advanced options"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), app.debugDescription)
        reveal(advanced)
        advanced.tap()
        let fields = app.textFields.matching(identifier: field)
        let buttons = app.buttons.matching(identifier: remove)
        waitForCount(fields, 3)
        XCTAssertEqual(fields.allElementsBoundByIndex.compactMap { $0.value as? String }, values)

        // Remove the middle, last, then first row so shifted bindings are exercised.
        var remaining = values
        for index in [1, 1, 0] {
            let button = buttons.element(boundBy: index)
            reveal(button)
            button.tap()
            remaining.remove(at: index)
            waitForCount(fields, remaining.count)
            XCTAssertEqual(fields.allElementsBoundByIndex.compactMap { $0.value as? String }, remaining)
            XCTAssertEqual(app.state, .runningForeground)
        }
        let addButton = app.buttons.matching(identifier: add).element(
            boundBy: arguments.contains("--guide-headers") ? 1 : 0
        )
        reveal(addButton)
        addButton.tap()
        waitForCount(fields, 1)
        reveal(buttons.firstMatch)
        buttons.firstMatch.tap()
        waitForCount(fields, 0)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.textFields["Guide URL (optional)"].exists)
    }

    private func waitForCount(_ query: XCUIElementQuery, _ count: Int) {
        let predicate = NSPredicate { _, _ in query.count == count }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5
        ), .completed, app.debugDescription)
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.midY < app.windows.firstMatch.frame.midY {
                app.scrollViews.firstMatch.swipeDown()
            } else {
                app.scrollViews.firstMatch.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
