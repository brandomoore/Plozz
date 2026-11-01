import XCTest

@MainActor
final class MobileServerOnboardingInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testEveryOnboardingStageOnThisDevice() throws {
        for (page, expected) in [
            ("welcome", "Free forever and open source."),
            ("chooser", "Add Server"),
            ("discovery", "Living Room"),
            ("quick", "654321"),
            ("password", "Username"),
            ("emby", "Username"),
            ("plex", "ABCD"),
            ("plex-servers", "Home Server"),
            ("silo", "ABCD-EFGH"),
            ("iptv", "Playlist"),
            ("share", "Enter an address manually")
        ] {
            let app = launch(page)
            defer { app.terminate() }
            let target = expected == "Username"
                ? app.textFields["server-sign-in-username"]
                : app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 12),
                "Missing \(expected) on \(page): \(app.debugDescription)")
            attach(app, name: "Onboarding-\(page)")
        }
    }

    func testProviderChoiceBackAndSeededAddress() throws {
        let app = launch("chooser")
        defer { app.terminate() }
        app.buttons["add-server-provider-emby"].tap()
        XCTAssertTrue(app.textFields["add-server-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Emby"].exists)
        XCTAssertFalse(app.buttons["add-server-provider-jellyfin"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["add-server-provider-jellyfin"].waitForExistence(timeout: 5))
        app.buttons["add-server-provider-jellyfin"].tap()
        XCTAssertTrue(app.textFields["add-server-address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Jellyfin"].exists)
        app.terminate()

        app.launchArguments = ["--onboarding-page=seeded"]
        app.launch()
        let address = app.textFields["add-server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "https://emby.example.test/media")
        XCTAssertFalse(app.buttons["add-server-provider-emby"].exists)
    }

    func testPlexCancelReturnsToProviderChooser() throws {
        let app = launch("chooser")
        defer { app.terminate() }
        app.buttons["add-server-provider-plex"].tap()
        XCTAssertTrue(app.staticTexts["ABCD"].waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["add-server-provider-jellyfin"].waitForExistence(timeout: 5))
    }

    func testQuickConnectSwitchesToPasswordAndBack() throws {
        let app = launch("quick")
        defer { app.terminate() }
        let password = app.buttons["Use Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        XCTAssertTrue(app.textFields["server-sign-in-username"].waitForExistence(timeout: 5))
        app.buttons["Use Quick Connect"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["654321"].waitForExistence(timeout: 5))
    }

    func testDiscoveredServerOpensSignInAndPersistsAccount() throws {
        let app = launch("flow")
        defer { app.terminate() }
        let server = app.buttons["discovered-server-living-room"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        XCTAssertTrue(app.staticTexts["654321"].waitForExistence(timeout: 8))
        attach(app, name: "Onboarding-quick-navigation")
        app.buttons["Use Password"].tap()
        let username = app.textFields["server-sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("Alex")
        app.secureTextFields["server-sign-in-password"].tap()
        app.secureTextFields["server-sign-in-password"].typeText("fixture\n")
        XCTAssertTrue(app.staticTexts["onboarding-completed"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["onboarding-completed"].label, "Added: living-room")
    }

    func testManualAddressStillValidatesBeforeOpeningSignIn() throws {
        let app = launch("flow")
        defer { app.terminate() }
        let address = app.textFields["add-server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["add-server-connect"].isEnabled)
        address.tap()
        address.typeText("https://jellyfin.example.test\n")
        XCTAssertTrue(app.staticTexts["654321"].waitForExistence(timeout: 8))
    }

    func testPasswordRetryPersistsTheAuthenticatedServer() throws {
        let app = launch("password-error")
        defer { app.terminate() }
        let username = app.textFields["server-sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("Alex")
        app.secureTextFields["server-sign-in-password"].tap()
        app.secureTextFields["server-sign-in-password"].typeText("fixture\n")
        let submit = app.buttons["server-sign-in-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        if !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isEnabled)
        attach(app, name: "Onboarding-password-error-keyboard")
        submit.tap()
        XCTAssertTrue(app.staticTexts["onboarding-completed"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["onboarding-completed"].label.contains("living-room"))
    }

    func testQuickConnectRetryKeepsPasswordAlternative() throws {
        let app = launch("quick-error")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Use Password"].exists)
        attach(app, name: "Onboarding-quick-error")
        app.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["654321"].waitForExistence(timeout: 8))
    }

    func testPlexPreselectsOwnedServersAndAddsOnlySelection() throws {
        let app = launch("plex-servers")
        defer { app.terminate() }
        let home = app.buttons["plex-server-home"]
        let studio = app.buttons["plex-server-studio"]
        let shared = app.buttons["plex-server-shared"]
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(studio.isSelected)
        XCTAssertFalse(shared.isSelected)
        home.tap()
        studio.tap()
        XCTAssertFalse(app.buttons["plex-servers-continue"].isEnabled)
        home.tap()
        shared.tap()
        XCTAssertTrue(app.buttons["plex-servers-continue"].isEnabled)
        app.buttons["plex-servers-continue"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-completed"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["onboarding-completed"].label, "Added: home, shared")
    }

    func testPlexCancelConfirmationPreservesSelectionWhenKept() throws {
        let app = launch("plex-servers")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["plex-server-home"].waitForExistence(timeout: 8))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 5))
        attach(app, name: "Onboarding-plex-cancel-confirmation")
        if app.sheets.buttons["Cancel"].exists {
            app.sheets.buttons["Cancel"].tap()
        } else if app.buttons["Keep Going"].exists {
            app.buttons["Keep Going"].tap()
        } else {
            app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.9)).tap()
        }
        XCTAssertTrue(app.buttons["plex-server-home"].isSelected)
        XCTAssertTrue(app.buttons["plex-server-studio"].isSelected)
    }

    private func launch(_ page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-page=\(page)"]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
