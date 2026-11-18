import Foundation
import XCTest
import notify

final class LiveJellyfinHomeRemoteTests: XCTestCase {
    @MainActor
    func testShowcaseWithRealJellyfinLibrary() throws {
        try exerciseShowcase(provider: "jellyfin")
    }

    @MainActor
    func testShowcaseWithRealPlexLibrary() throws {
        try exerciseShowcase(provider: "plex")
    }

    @MainActor
    private func exerciseShowcase(provider: String) throws {
        guard let broker = ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_HOME_BROKER"] else {
            throw XCTSkip("Requires the authorized read-only live Home broker.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--live-jellyfin-home", "--live-showcase-home"]
        app.launchEnvironment = [
            "PLOZZ_JELLYFIN_HOME_BROKER": broker + "/" + provider,
            "PLOZZ_LIVE_HOME_PROVIDER": provider,
            "PLOZZ_LIVE_HOME_RUN_ID": UUID().uuidString
        ]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["live-home-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 35))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Real Home data ready"].waitForExistence(timeout: 60))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Live Showcase initial focus"
        initial.lifetime = .keepAlways
        add(initial)
        for _ in 0..<6 {
            if hero.exists && hero.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in hero.exists && hero.hasFocus }, object: nil)
        ], timeout: 10), .completed)
        func focusedCard() -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        }
        XCUIRemote.shared.press(.down)
        let rowQuery = app.scrollViews["showcase-rows"].scrollViews
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rowQuery.count >= 4 }, object: nil)
        ], timeout: 5), .completed)
        let rows = rowQuery.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(rows.count, 4, "The live library must provide several real Home rows.")
        var shortRows = 0
        func assertGutterEntry(_ row: XCUIElement, from departure: CGRect) {
            let cards = row.buttons.allElementsBoundByIndex.sorted { $0.frame.maxX < $1.frame.maxX }
            if cards.count <= 3, let last = cards.last, departure.minX > last.frame.maxX {
                XCTAssertTrue(last.hasFocus, "A short real row must select its nearest edge card.")
            }
        }
        for (index, row) in rows.enumerated() {
            let departure = focusedCard().frame
            if index > 0 { XCUIRemote.shared.press(.down) }
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    row.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
                }, object: nil)
            ], timeout: 5), .completed, "Down must enter the immediately adjacent real row.")
            if index > 0 { assertGutterEntry(row, from: departure) }
            if row.buttons.count <= 3 { shortRows += 1 }
            for _ in 0..<4 { XCUIRemote.shared.press(.right) }
            if row.buttons.count > 1 {
                let cards = row.buttons.allElementsBoundByIndex
                let right = try XCTUnwrap(cards.firstIndex { $0.hasFocus })
                XCUIRemote.shared.press(.left)
                let left = try XCTUnwrap(cards.firstIndex { $0.hasFocus })
                if right == left {
                    let failure = XCTAttachment(screenshot: app.screenshot())
                    failure.name = "Live Showcase horizontal focus"
                    failure.lifetime = .keepAlways
                    add(failure)
                }
                XCTAssertNotEqual(right, left, "The live row must support horizontal navigation; row \(index), cards \(cards.count).")
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(cards[right].hasFocus)
            }
        }
        for row in rows.dropLast().reversed() {
            let departure = focusedCard().frame
            XCUIRemote.shared.press(.up)
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    row.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
                }, object: nil)
            ], timeout: 5), .completed, "Up must enter the immediately adjacent real row.")
            assertGutterEntry(row, from: departure)
        }
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(hero.exists && hero.hasFocus, "Up must return through the live rows to the Showcase hero.")
        let runID = try XCTUnwrap(app.launchEnvironment["PLOZZ_LIVE_HOME_RUN_ID"])
        XCTAssertEqual(notify_post("com.thatcube.Plozz.live-home.\(runID).finish"), UInt32(NOTIFY_STATUS_OK))
        XCTAssertTrue(app.staticTexts["Real Home measured"].waitForExistence(timeout: 10))
        print("LIVE_SHOWCASE passed provider=\(provider) realLibrary=true readOnly=true rows=\(rows.count) shortRows=\(shortRows)")
    }

    func testProfileRealHome() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_ATTACH"] == "1",
              ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_HOME_BROKER"] != nil,
              let runID = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_RUN_ID"] else {
            throw XCTSkip("Requires the explicitly authorized live profiling lane.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        XCTAssertEqual(app.state, .runningForeground)
        let start = app.buttons["live-home-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 35))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Real Home data ready"].waitForExistence(timeout: 35))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(hero.hasFocus)
        func focusedLabel() -> String {
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.label
        }
        var rowDepth = 0
        for depth in 1...8 {
            XCUIRemote.shared.press(.down)
            let before = focusedLabel()
            XCUIRemote.shared.press(.right)
            let moved = !before.isEmpty && before != focusedLabel()
            XCUIRemote.shared.press(.left)
            if moved {
                rowDepth = depth
                break
            }
        }
        XCTAssertGreaterThan(rowDepth, 0, "Real data must include a horizontally navigable media row.")
        for _ in 0..<rowDepth { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(hero.hasFocus)
        XCTAssertEqual(notify_post("com.thatcube.Plozz.live-home.\(runID).navigation"), UInt32(NOTIFY_STATUS_OK))
        for _ in 0..<3 {
            for _ in 0..<rowDepth { XCUIRemote.shared.press(.down) }
            XCTAssertFalse(hero.hasFocus)
            let before = focusedLabel()
            for _ in 0..<4 { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(before != focusedLabel(), "Native horizontal focus must actually move.")
            for _ in 0..<4 { XCUIRemote.shared.press(.left) }
            for _ in 0..<rowDepth { XCUIRemote.shared.press(.up) }
            XCTAssertTrue(hero.hasFocus)
        }
        XCTAssertEqual(notify_post("com.thatcube.Plozz.live-home.\(runID).finish"), UInt32(NOTIFY_STATUS_OK))
        XCTAssertTrue(app.staticTexts["Real Home measured"].waitForExistence(timeout: 10))
        #else
        throw XCTSkip("The live profiling lane is simulator-only.")
        #endif
    }
}
