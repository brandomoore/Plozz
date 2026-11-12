import XCTest

@MainActor
final class MobileServerOnboardingInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFirstLaunchKeepsPrimaryProvidersAndMusicSignInReachable() throws {
        let app = launch("welcome")
        defer { app.terminate() }
        let music = app.buttons["add-server-provider-subsonic"]
        XCTAssertTrue(music.waitForExistence(timeout: 5))
        for provider in ["jellyfin", "plex", "emby", "silo", "mediaShare", "iptv"] {
            XCTAssertTrue(app.buttons["add-server-provider-\(provider)"].exists)
        }
        if !music.isHittable { app.swipeUp() }
        XCTAssertTrue(music.isHittable)
        let transfer = app.buttons["Set Up from Another Device"]
        XCTAssertTrue(transfer.exists)
        XCTAssertGreaterThanOrEqual(transfer.frame.minY, music.frame.maxY)
        attach(app, name: "Subsonic-first-launch")
        music.tap()
        XCTAssertTrue(app.textFields["subsonic-address"].waitForExistence(timeout: 5))
    }

    func testSubsonicOpensDirectlyAndReturnsToProviderChoices() throws {
        let app = launch("chooser")
        defer { app.terminate() }
        let choice = app.buttons["add-server-provider-subsonic"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        if !choice.isHittable { app.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        attach(app, name: "Subsonic-provider-choice")
        choice.tap()
        let address = app.textFields["subsonic-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["subsonic-username"].exists)
        XCTAssertTrue(app.secureTextFields["subsonic-secret"].exists)
        XCTAssertFalse(app.buttons["subsonic-sign-in"].isEnabled)
        attach(app, name: "Subsonic-direct-sign-in")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["add-server-provider-jellyfin"].waitForExistence(timeout: 5))
    }

    func testSourceEntryPointsShareTheChooserAndReturnToTheirOrigin() throws {
        for page in ["home-empty", "home-new", "sources", "libraries", "libraries-empty"] {
            let app = launch(page)
            defer { app.terminate() }
            let identifier = page == "sources" ? "sources-add-source"
                : page.hasPrefix("libraries") ? "libraries-add-source" : "home-add-source"
            let add = app.buttons[identifier]
            XCTAssertTrue(add.waitForExistence(timeout: 8), page)
            if !add.isHittable { app.swipeUp() }
            XCTAssertTrue(add.isHittable, page)
            XCTAssertEqual(add.label, "Add Source")
            XCTAssertEqual(app.buttons.matching(identifier: identifier).count, 1)
            XCTAssertFalse(app.buttons["Add Network Share"].exists)
            attach(app, name: "Source-entry-\(page)")
            add.tap()
            let share = app.buttons["add-server-provider-mediaShare"]
            XCTAssertTrue(share.waitForExistence(timeout: 5), page)
            for provider in ["jellyfin", "plex", "emby", "silo", "iptv"] {
                XCTAssertTrue(app.buttons["add-server-provider-\(provider)"].exists, page)
            }
            attach(app, name: "Source-destination-\(page)")
            share.tap()
            XCTAssertTrue(app.buttons["Enter an address manually"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            app.navigationBars.buttons["Cancel"].tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5), page)
            if page == "sources" {
                let server = app.buttons.containing(.staticText, identifier: "Living Room").firstMatch
                XCTAssertTrue(server.exists)
                server.tap()
                XCTAssertTrue(app.navigationBars["Living Room"].waitForExistence(timeout: 5))
                XCTAssertFalse(share.exists, "A source detail row must not open the add chooser")
            }
        }
    }

    func testHomeEmptyStatesKeepOnePrimaryActionInBothAppearances() throws {
        for page in ["home-empty", "home-new"] {
            for light in [false, true] {
                let app = launch(page, arguments: light ? ["--light"] : [])
                defer { app.terminate() }
                let add = app.buttons["home-add-source"]
                XCTAssertTrue(add.waitForExistence(timeout: 5))
                XCTAssertTrue(add.isHittable)
                XCTAssertGreaterThanOrEqual(add.frame.height, 44)
                XCTAssertLessThanOrEqual(add.frame.width, 320 + 32)
                XCTAssertTrue(app.staticTexts[page == "home-empty"
                    ? "Nothing to watch yet" : "Build your library"].exists)
                let transfer = app.buttons["Set Up from Another Device"]
                XCTAssertEqual(transfer.exists, page == "home-new")
                if transfer.exists {
                    XCTAssertEqual(transfer.frame.width, add.frame.width, accuracy: 1)
                    XCTAssertEqual(transfer.frame.height, add.frame.height, accuracy: 1)
                }
                attach(app, name: "Home-empty-\(page)-\(light ? "light" : "dark")")
            }
        }
    }

    func testEveryOnboardingStageOnThisDevice() throws {
        var pageActionSize: CGSize?
        let actions = [
            "welcome": ["Set Up from Another Device"],
            "discovery": ["Connect"],
            "quick": ["Use Password"],
            "password": ["Sign In", "Use Quick Connect"],
            "emby": ["Sign In"],
            "plex": ["Open Plex to link"],
            "plex-servers": ["Continue"],
            "silo": ["Open Silo to approve", "Use another device"],
            "iptv": ["Connect"]
        ]
        for (page, expected) in [
            ("welcome", "Free forever and open source."),
            ("chooser", "Add Source"),
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
            for title in actions[page, default: []] {
                let button = app.buttons[title]
                XCTAssertTrue(button.waitForExistence(timeout: 5), "\(page): \(title)")
                if !button.isHittable { app.swipeUp() }
                XCTAssertTrue(button.isHittable, "\(page): \(title) must remain reachable")
                if let expectedSize = pageActionSize {
                    XCTAssertEqual(button.frame.height, expectedSize.height, accuracy: 1,
                                   "\(page): \(title) must use the shared page-action height")
                    XCTAssertEqual(button.frame.width, expectedSize.width, accuracy: 1,
                                   "\(page): \(title) must use the shared content width")
                } else {
                    pageActionSize = button.frame.size
                    XCTAssertGreaterThanOrEqual(button.frame.height, 44)
                }
            }
            if page != "welcome" {
                let cancel = app.navigationBars.buttons["Cancel"]
                XCTAssertTrue(cancel.exists, "\(page) must retain native toolbar cancellation")
                XCTAssertTrue(cancel.isHittable)
            }
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

    func testEveryProviderCanGoBackThroughTheRealFlow() throws {
        for provider in ["jellyfin", "emby", "silo", "plex", "iptv", "mediaShare"] {
            let app = launch("chooser")
            defer { app.terminate() }
            let choice = app.buttons["add-server-provider-\(provider)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertEqual(app.navigationBars.buttons.count, 1, provider)
            XCTAssertFalse(app.buttons["Cancel"].exists, "Pushed pages use Back, not another Cancel")
            if ["jellyfin", "emby", "silo"].contains(provider) {
                let server = app.buttons["discovered-server-living-room"]
                XCTAssertTrue(server.waitForExistence(timeout: 8))
                server.tap()
                let expected = provider == "silo" ? app.buttons["Open Silo to approve"]
                    : provider == "emby" ? app.buttons["server-sign-in-submit"] : app.buttons["Use Password"]
                XCTAssertTrue(expected.waitForExistence(timeout: 8))
                try assertVisible(back, in: app)
                XCTAssertEqual(app.navigationBars.buttons.count, 1)
                XCTAssertFalse(app.buttons["Cancel"].exists)
                attach(app, name: "Flow-\(provider)-sign-in")
                if provider == "jellyfin" {
                    app.buttons["Use Password"].tap()
                    XCTAssertTrue(app.buttons["Use Quick Connect"].waitForExistence(timeout: 5))
                    try assertVisible(back, in: app)
                    attach(app, name: "Flow-jellyfin-password")
                } else if provider == "silo" {
                    let phrase = app.staticTexts.matching(
                        NSPredicate(format: "label CONTAINS %@", "Check Silo shows")
                    ).firstMatch
                    XCTAssertTrue(phrase.exists)
                    XCTAssertLessThanOrEqual(phrase.frame.height, 24, "Default-size verification fits one line")
                    app.buttons["Use another device"].tap()
                    XCTAssertTrue(app.staticTexts["Or enter a code at"].waitForExistence(timeout: 5))
                    attach(app, name: "Flow-silo-other-device")
                    app.buttons["Use another device"].tap()
                    XCTAssertFalse(app.staticTexts["Or enter a code at"].exists)
                }
                back.tap()
                XCTAssertTrue(app.textFields["add-server-address"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["onboarding-completed"].exists)
            } else {
                let expected = provider == "plex" ? app.buttons["Open Plex to link"]
                    : provider == "iptv" ? app.buttons["Connect"] : app.buttons["Enter an address manually"]
                XCTAssertTrue(expected.waitForExistence(timeout: 8))
                attach(app, name: "Flow-\(provider)")
            }
            back.tap()
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            app.navigationBars.buttons["Cancel"].tap()
            XCTAssertTrue(app.staticTexts["Servers"].waitForExistence(timeout: 5))
        }
    }

    func testRootCancelAndSignInBackReturnToTheirOwnLevels() throws {
        for page in ["flow", "silo-flow", "iptv", "share", "plex"] {
            let app = launch(page)
            defer { app.terminate() }
            XCTAssertTrue(app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).count, 1)
            if page == "flow" || page == "silo-flow" {
                let server = app.buttons["discovered-server-living-room"]
                XCTAssertTrue(server.waitForExistence(timeout: 8))
                server.tap()
                let action = app.buttons[page == "flow" ? "Use Password" : "Open Silo to approve"]
                XCTAssertTrue(action.waitForExistence(timeout: 8))
                XCTAssertFalse(app.buttons["Cancel"].exists)
                let back = app.navigationBars.buttons.firstMatch
                try assertVisible(back, in: app)
                back.tap()
                XCTAssertTrue(app.textFields["add-server-address"].waitForExistence(timeout: 5))
            }
            app.navigationBars.buttons["Cancel"].tap()
            XCTAssertTrue(app.staticTexts["Servers"].waitForExistence(timeout: 5))
        }
    }

    func testPlexBackReturnsToProviderChooser() throws {
        let app = launch("chooser")
        defer { app.terminate() }
        app.buttons["add-server-provider-plex"].tap()
        XCTAssertTrue(app.staticTexts["ABCD"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["Back"].tap()
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

    func testCodeLayoutAndAlternativeActionSizesMatch() throws {
        let app = launch("quick")
        defer { app.terminate() }
        let password = app.buttons["Use Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        let code = app.staticTexts["654321"]
        XCTAssertTrue(code.waitForExistence(timeout: 8))
        let countdown = app.descendants(matching: .any).matching(identifier: "connection-code-countdown").firstMatch
        XCTAssertTrue(countdown.exists)
        XCTAssertGreaterThan(countdown.frame.minX, code.frame.maxX)
        XCTAssertEqual(countdown.frame.midY, code.frame.midY, accuracy: 2)
        let alternateFrame = password.frame
        XCTAssertGreaterThanOrEqual(alternateFrame.height, 44)
        attach(app, name: "Refined-quick")

        password.tap()
        let quick = app.buttons["Use Quick Connect"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        let primary = app.buttons["server-sign-in-submit"]
        XCTAssertEqual(primary.frame.height, quick.frame.height, accuracy: 1)
        XCTAssertEqual(primary.frame.minX, quick.frame.minX, accuracy: 1)
        XCTAssertEqual(primary.frame.width, quick.frame.width, accuracy: 1)
        XCTAssertEqual(primary.frame.height, alternateFrame.height, accuracy: 1)
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let primaryOutline = try renderedOutline(of: primary, in: app, screenshot: screenshot)
        let secondaryOutline = try renderedOutline(of: quick, in: app, screenshot: screenshot)
        XCTAssertEqual(primaryOutline.width, secondaryOutline.width, accuracy: 1)
        XCTAssertEqual(primaryOutline.height, secondaryOutline.height, accuracy: 1)
        attach(app, name: "Refined-password")
        app.terminate()

        app.launchArguments = ["--onboarding-page=plex"]
        app.launch()
        let plexCode = app.staticTexts["ABCD"]
        XCTAssertTrue(plexCode.waitForExistence(timeout: 8))
        let plexCountdown = app.descendants(matching: .any).matching(identifier: "connection-code-countdown").firstMatch
        XCTAssertTrue(plexCountdown.exists)
        XCTAssertGreaterThan(plexCountdown.frame.minX, plexCode.frame.maxX)
        XCTAssertEqual(plexCountdown.frame.midY, plexCode.frame.midY, accuracy: 2)
        XCTAssertEqual(app.buttons["Open Plex to link"].frame.height, alternateFrame.height, accuracy: 1)
        attach(app, name: "Refined-plex")
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

    private func renderedOutline(of button: XCUIElement, in app: XCUIApplication,
                                 screenshot: CGImage) throws -> CGSize {
        let scale = CGFloat(screenshot.width) / app.frame.width
        let frame = button.frame.offsetBy(dx: -app.frame.minX, dy: -app.frame.minY)
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale)
            .insetBy(dx: -4 * scale, dy: -4 * scale).integral
        let image = try XCTUnwrap(screenshot.cropping(to: crop))
        let pixels = try rgba(image)
        func span(_ offsets: [Int]) throws -> CGFloat {
            let differences = zip(offsets, offsets.dropFirst()).map { previous, current in
                (0..<3).reduce(0) { $0 + abs(Int(pixels[current + $1]) - Int(pixels[previous + $1])) }
            }
            let edgeRange = Int(7 * scale)
            // Measure the outer rim, not whichever interior glass highlight is strongest.
            let leading = try XCTUnwrap(differences.indices.prefix(edgeRange).first {
                differences[$0] > 12
            }, "The visible leading edge must be measurable")
            let trailing = try XCTUnwrap(differences.indices.suffix(edgeRange).last {
                differences[$0] > 12
            }, "The visible trailing edge must be measurable")
            return CGFloat(trailing - leading)
        }
        return try CGSize(
            width: span((0..<image.width).map { (image.height / 2 * image.width + $0) * 4 }),
            height: span((0..<image.height).map { ($0 * image.width + image.width * 3 / 4) * 4 })
        )
    }

    private func assertVisible(_ button: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(button.isHittable)
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(screenshot.width) / app.frame.width
        let frame = button.frame.offsetBy(dx: -app.frame.minX, dy: -app.frame.minY)
        let image = try XCTUnwrap(screenshot.cropping(to: CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale
        ).integral))
        let pixels = try rgba(image)
        let red = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }
        XCTAssertGreaterThan(try XCTUnwrap(red.max()) - XCTUnwrap(red.min()), 48,
                             "Back must be visibly drawn, not merely present in the accessibility tree")
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func launch(_ page: String, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-page=\(page)"] + arguments
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
