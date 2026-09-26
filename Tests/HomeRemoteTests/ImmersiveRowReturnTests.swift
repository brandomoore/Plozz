import XCTest

/// Beside the pinned sidebar, a Home row puts its first card back exactly where
/// the row opened after scrolling right and returning. tvOS parks a card returning
/// left against the screen's safe area, which leaves the first card short of its
/// place and inside the sidebar's feather unless the row corrects it. Runs the
/// real Home against local fixture data in the isolated host.
@MainActor
final class ImmersiveRowReturnTests: XCTestCase {
    func testFirstCardReturnsToWhereTheRowOpenedInImmersive() throws {
        try exercise(arguments: ["--immersive-home"], name: "immersive")
    }

    func testFirstCardReturnsToWhereTheRowOpenedInSpotlight() throws {
        try exercise(arguments: [], name: "spotlight", leavesHero: true)
    }

    private func exercise(arguments: [String], name: String, leavesHero: Bool = false) throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = true
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--pinned-home"] + arguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        if leavesHero {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let first = focusedCard(in: app)
        let label = first.label
        let start = first.frame.minX
        XCTAssertFalse(label.isEmpty, "Focus must start on a card.")
        attach(app, "\(name)-opened")
        // Deep and shallow trips at a relaxed pace, a brisk pace and a fast tap.
        let trips: [(depth: Int, pause: TimeInterval)] = [
            (8, 0.6), (8, 0.6), (5, 0.6), (12, 0.4), (8, 0.25),
            (5, 0.25), (12, 0.25), (8, 0.12), (5, 0.12), (12, 0.12),
        ]
        var misses: [String] = []
        for (trip, (depth, pause)) in trips.enumerated() {
            for _ in 0..<depth {
                XCUIRemote.shared.press(.right)
                Thread.sleep(forTimeInterval: pause)
            }
            for _ in 0..<depth {
                XCUIRemote.shared.press(.left)
                Thread.sleep(forTimeInterval: pause)
            }
            Thread.sleep(forTimeInterval: 1.2)
            let card = focusedCard(in: app)
            let drift = card.frame.minX - start
            if card.label != label || abs(drift) > 2 {
                misses.append("trip \(trip) (\(depth) cards, \(pause)s): \(card.label) drifted \(drift)pt")
                attach(app, "\(name)-trip-\(trip)")
            }
        }
        XCTAssertEqual(misses, [], "The first card must return to where the row opened every time.")
        #else
        throw XCTSkip("Uses the isolated host with local fixture data.")
        #endif
    }

    /// The focused card: the smallest focused element, since containers that hold
    /// focus report it too.
    private func focusedCard(in app: XCUIApplication) -> XCUIElement {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        return focused.filter { !$0.frame.isEmpty }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
