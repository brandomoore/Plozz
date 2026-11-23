import XCTest

#if os(tvOS)
@MainActor
final class PublicMetaDBLiveSetupTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")

    func testNormalOnboarding() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(environment["PLOZZ_TRACKER_CONNECTION_LIVE"], "1")
        let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_CONNECTION_SIMULATOR"])
        XCTAssertFalse(simulator.isEmpty)
        XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
        XCTAssertEqual(app.state, .runningForeground)
        defer {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "normal-onboarding-final-state"
            state.lifetime = .keepAlways
            add(state)
        }

        if app.buttons["Set up from another device"].exists {
            try select(app.buttons["IPTV"], moving: .down)
            let address = app.textFields["Playlist URL"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            try select(address, moving: .down)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            address.typeText("https://iptv-org.github.io/iptv/countries/sm.m3u")
            XCUIRemote.shared.press(.menu)
            XCTAssertEqual(address.value as? String, "https://iptv-org.github.io/iptv/countries/sm.m3u")
            try select(app.buttons["iptv-connect"], moving: .down)

            let confirm = app.buttons["Looks good"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 90), "Real playlist import did not reach profile confirmation.")
            try select(confirm, moving: .right)
        }
        XCTAssertTrue(app.staticTexts["Requests as"].waitForExistence(timeout: 10))
        try select(app.buttons["Not Now"], moving: .down)
        for heading in [
            "Choose theme for this profile",
            "Choose navigation for this profile",
            "Choose Home layout for this profile",
        ] {
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 10), heading)
            try select(app.buttons["Continue"], moving: .down)
            XCTAssertTrue(app.staticTexts[heading].waitForNonExistence(timeout: 10), heading)
        }
        XCTAssertFalse(app.buttons["Set up from another device"].exists)
    }

    private func select(_ target: XCUIElement, moving direction: XCUIRemote.Button) throws {
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        for _ in 0..<12 {
            if target.hasFocus { break }
            XCUIRemote.shared.press(direction)
        }
        XCTAssertTrue(target.hasFocus, "Normal setup could not focus \(target.identifier).")
        XCUIRemote.shared.press(.select)
    }
}
#endif
