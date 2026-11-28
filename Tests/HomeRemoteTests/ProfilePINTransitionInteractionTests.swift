import XCTest

@MainActor
final class ProfilePINTransitionInteractionTests: XCTestCase {
    func testAvatarHandoffCancelAndSuccessfulPIN() throws {
        try verifyHandoff(reduceMotion: false)
    }

    func testReducedMotionKeepsPINAndReturnFocus() throws {
        try verifyHandoff(reduceMotion: true)
    }

    func testChainedPlexPINRetainsSelectedProfileIdentity() throws {
        try verifyHandoff(reduceMotion: false, usesPlex: true)
    }

    func testForegroundBackRetainsGateAndReturnFocus() throws {
        try verifyHandoff(reduceMotion: false, foregroundLocked: true)
    }

    func testDirectPlexPINCancelReselectAndNativeKeypad() throws {
        try verifyDirectPlexHandoff(reduceMotion: false)
    }

    func testDirectPlexPINReducedMotionCancelReselectAndNativeKeypad() throws {
        try verifyDirectPlexHandoff(reduceMotion: true)
    }

    private func verifyDirectPlexHandoff(reduceMotion: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--profile-pin-transition-fixture", "--direct-plex-pin"]
        app.launch()
        addTeardownBlock { app.terminate() }
        let viewer = app.buttons.matching(NSPredicate(format: "label == %@", "Locked viewer")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        try XCTSkipUnless(
            app.staticTexts["profile-handoff-motion"].label == (reduceMotion ? "Reduced motion" : "Full motion"),
            "Run with the matching Reduce Motion setting on the owned simulator."
        )
        XCUIRemote.shared.press(.right)
        waitForFocus(viewer)
        let sourceFrame = viewer.frame
        capture(app, name: "Direct Plex source, reduced motion \(reduceMotion)")
        let identity = app.descendants(matching: .any)["profile-pin-name"]
        let prompt = app.staticTexts["pin-entry-title"]
        let one = app.buttons["1"]

        for selection in 1...2 {
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(prompt.waitForExistence(timeout: 5))
            XCTAssertEqual(prompt.label, "Enter your Plex PIN")
            XCTAssertEqual(identity.label, "Locked viewer")
            XCTAssertFalse(viewer.isHittable)
            XCTAssertFalse(app.staticTexts["profile-handoff-complete"].exists)
            capture(app, name: "Direct Plex selection \(selection), reduced motion \(reduceMotion)")
            waitForFocus(one)
            XCTAssertTrue(one.isEnabled)
            XCTAssertTrue(one.isHittable)
            if selection == 1 {
                XCUIRemote.shared.press(.menu)
                waitForFocus(viewer)
                XCTAssertFalse(identity.exists)
                XCTAssertFalse(prompt.exists)
                XCTAssertFalse(app.staticTexts["profile-handoff-complete"].exists)
                XCTAssertEqual(viewer.frame.midX, sourceFrame.midX, accuracy: 2)
                XCTAssertEqual(viewer.frame.midY, sourceFrame.midY, accuracy: 2)
                capture(app, name: "Direct Plex cancelled, reduced motion \(reduceMotion)")
            }
        }

        XCUIRemote.shared.press(.right)
        let two = app.buttons["2"]
        waitForFocus(two)
        XCTAssertTrue(two.isEnabled)
        XCTAssertTrue(two.isHittable)
        for _ in 0..<4 { XCUIRemote.shared.press(.select) }
        let complete = app.staticTexts["profile-handoff-complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertEqual(complete.label, "Opened Locked viewer")
        capture(app, name: "Direct Plex authorized, reduced motion \(reduceMotion)")
    }

    private func verifyHandoff(
        reduceMotion: Bool, usesPlex: Bool = false, foregroundLocked: Bool = false
    ) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--profile-pin-transition-fixture"]
        if usesPlex { app.launchArguments.append("--plex-pin") }
        if foregroundLocked { app.launchArguments.append("--foreground-lock") }
        app.launch()
        defer { app.terminate() }
        let viewer = app.buttons.matching(NSPredicate(format: "label == %@", "Locked viewer")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        if foregroundLocked {
            XCTAssertEqual(app.staticTexts["profile-handoff-foreground"].label, "Foreground locked")
        }
        if reduceMotion {
            try XCTSkipUnless(app.staticTexts["profile-handoff-motion"].label == "Reduced motion",
                              "Run with Reduce Motion enabled on the owned simulator.")
        }
        XCUIRemote.shared.press(.right)
        waitForFocus(viewer)
        let sourceFrame = viewer.frame
        capture(app, name: "Profile handoff source, reduced motion \(reduceMotion)")
        XCUIRemote.shared.press(.select)
        let identity = app.descendants(matching: .any)["profile-pin-name"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertTrue(identity.label.contains("Locked viewer"))
        XCTAssertFalse(viewer.isHittable, "The retained picker must not remain interactive.")
        let one = app.buttons["1"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        waitForFocus(one)
        capture(app, name: "Profile handoff PIN, reduced motion \(reduceMotion)")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        waitForFocus(viewer)
        XCTAssertEqual(viewer.frame.midX, sourceFrame.midX, accuracy: 2)
        XCTAssertEqual(viewer.frame.midY, sourceFrame.midY, accuracy: 2)
        XCTAssertFalse(identity.exists)
        if foregroundLocked {
            XCTAssertEqual(app.staticTexts["profile-handoff-foreground"].label, "Foreground locked")
        }
        capture(app, name: "Profile handoff return, reduced motion \(reduceMotion)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        waitForFocus(one)
        for _ in 0..<4 { XCUIRemote.shared.press(.select) }
        if usesPlex {
            let plexTitle = app.staticTexts["pin-entry-title"]
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "Enter your Plex PIN"), object: plexTitle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
            XCTAssertEqual(identity.label, "Locked viewer")
            XCTAssertFalse(app.staticTexts["profile-handoff-complete"].exists)
            waitForFocus(one)
            capture(app, name: "Plex PIN keeps selected Plozz avatar")
            XCUIRemote.shared.press(.menu)
            waitForFocus(viewer)
            XCTAssertFalse(identity.exists)
            XCTAssertEqual(viewer.frame.midX, sourceFrame.midX, accuracy: 2)
            XCTAssertEqual(viewer.frame.midY, sourceFrame.midY, accuracy: 2)
            capture(app, name: "Plex PIN returns to the original tile")
            XCUIRemote.shared.press(.select)
            waitForFocus(one)
            for _ in 0..<4 { XCUIRemote.shared.press(.select) }
            let repeatedPlex = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "Enter your Plex PIN"), object: plexTitle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [repeatedPlex], timeout: 5), .completed)
            waitForFocus(one)
            XCUIRemote.shared.press(.right)
            waitForFocus(app.buttons["2"])
            for _ in 0..<4 { XCUIRemote.shared.press(.select) }
        }
        XCTAssertTrue(app.staticTexts["profile-handoff-complete"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile-handoff-complete"].label, "Opened Locked viewer")
    }

    private func waitForFocus(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
