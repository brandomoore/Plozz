import XCTest

@MainActor
final class IPTVSetupInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var advanced: XCUIElement { app.buttons["iptv-advanced-options"] }
    private var authentication: XCUIElement { app.buttons["iptv-authentication"] }
    private let httpWarning = "HTTP is unencrypted. Use HTTPS when available."

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testPlaylistStartsQuietAndDisclosureDoesNotActAsASwitch() {
        launch()
        XCTAssertTrue(app.textFields["Playlist URL"].exists)
        XCTAssertTrue(app.textFields["Name (optional)"].exists)
        XCTAssertFalse(authentication.exists)
        XCTAssertFalse(app.textFields["Guide URL (optional)"].exists)
        XCTAssertFalse(app.switches["Advanced options"].exists)
        XCTAssertFalse(app.staticTexts[httpWarning].exists)
        XCTAssertFalse(app.staticTexts["Add a playlist or sign in."].exists)
        XCTAssertFalse(app.staticTexts["CONNECTION"].exists)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        advanced.tap()
        XCTAssertTrue(authentication.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Guide URL (optional)"].exists)
        XCTAssertFalse(app.staticTexts["Your link may already include a login."].exists)
        XCTAssertFalse(app.staticTexts[
            "Only add headers requested by your provider. Credentials are never forwarded to a different server."
        ].exists)
        XCTAssertEqual(advanced.value as? String, "Expanded")
        advanced.tap()
        XCTAssertFalse(authentication.exists)
        XCTAssertFalse(app.textFields["Guide URL (optional)"].exists)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
    }

    func testPlaylistAuthenticationSurvivesCollapseAndModeChanges() {
        launch()
        let address = app.textFields["Playlist URL"]
        address.tap()
        address.typeText("https://playlist.example.test/channels.m3u\n")
        reveal(advanced)
        advanced.tap()
        reveal(authentication)
        authentication.tap()
        app.buttons["Username and password"].tap()
        let username = app.textFields["Username"]
        reveal(username)
        username.tap()
        username.typeText("fixture-user\n")
        let password = app.secureTextFields["Password"]
        reveal(password)
        password.tap()
        password.typeText("fixture-password\n")
        reveal(advanced)
        advanced.tap()
        XCTAssertFalse(username.exists)
        XCTAssertTrue(app.buttons["iptv-connect"].isEnabled)
        advanced.tap()
        XCTAssertEqual(username.value as? String, "fixture-user")
        XCTAssertTrue(app.buttons["iptv-connect"].isEnabled)
        reveal(advanced)
        advanced.tap()
        let connection = app.buttons["iptv-connection-type"]
        reveal(connection)
        connection.tap()
        app.buttons["Xtream account"].tap()
        XCTAssertTrue(username.exists)
        XCTAssertEqual(username.value as? String, "fixture-user")
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        connection.tap()
        app.buttons["Playlist URL"].tap()
        XCTAssertEqual(advanced.value as? String, "Expanded")
        XCTAssertTrue(authentication.exists)
        XCTAssertEqual(username.value as? String, "fixture-user")
    }

    func testXtreamKeepsRequiredCredentialsOutsideAdvanced() {
        launch(["--xtream"])
        XCTAssertTrue(app.textFields["Server address"].exists)
        XCTAssertTrue(app.textFields["Username"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        reveal(advanced)
        advanced.tap()
        XCTAssertFalse(authentication.exists)
        XCTAssertTrue(app.textFields["Username"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
    }

    func testReconnectExposesSavedAdvancedSettingsAndCollapsePreservesThem() {
        launch(["--reconnect"])
        XCTAssertEqual(advanced.value as? String, "Expanded")
        XCTAssertEqual(app.textFields["Header name"].value as? String, "Authorization")
        advanced.tap()
        XCTAssertFalse(app.textFields["Header name"].exists)
        XCTAssertTrue(app.buttons["iptv-connect"].isEnabled)
        advanced.tap()
        XCTAssertEqual(app.textFields["Header name"].value as? String, "Authorization")
    }

    func testHTTPWarningIsShownForAnEnteredHTTPAddress() {
        launch(["--http-playlist"])
        XCTAssertTrue(app.staticTexts[httpWarning].exists)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = ["--iptv-setup-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), app.debugDescription)
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 {
            let safeFrame = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 90)
            if element.exists && element.isHittable && safeFrame.contains(element.frame) { return }
            if element.exists && element.frame.midY < app.windows.firstMatch.frame.midY {
                app.scrollViews.firstMatch.swipeDown()
            } else {
                app.scrollViews.firstMatch.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
