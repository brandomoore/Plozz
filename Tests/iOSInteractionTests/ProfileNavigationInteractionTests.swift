import XCTest

@MainActor
final class ProfileNavigationInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = [
            "--navigation-interaction-fixture", "--profile-rail-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 { capture("profile-placement-failure") }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testVerticalRailKeepsProfileInTheSamePlaceAcrossRootPages() {
        XCTAssertTrue(app.staticTexts["profile-toolbar-layout"].wait(
            for: \.label, toEqual: "vertical", timeout: 10
        ), "Run this case on a device with a native vertical toolbar.")
        verifyPages(["Home", "Watchlist", "Live TV", "Downloads", "Search"], vertical: true)
    }

    func testOrdinaryDevicesKeepTopRightProfilesAndInlineSearch() {
        XCTAssertTrue(app.staticTexts["profile-toolbar-layout"].wait(
            for: \.label, toEqual: "horizontal", timeout: 10
        ), "Run this case on a device without a native vertical toolbar.")
        verifyPages(["Home", "Watchlist", "Downloads"], vertical: false)
        select("Search")
        let inlineAvatar = app.buttons["search-settings-avatar"]
        XCTAssertTrue(inlineAvatar.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Settings for ")
        ).firstMatch.exists)
        inlineAvatar.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
    }

    private func verifyPages(_ pages: [String], vertical: Bool) {
        var homeFrame: CGRect?
        for title in pages {
            select(title)
            let avatars = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings for "))
            let avatar = avatars.firstMatch
            XCTAssertTrue(avatar.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
            XCTAssertEqual(avatars.count, 1, "Exactly one profile entry on \(title).")
            if let homeFrame {
                if vertical {
                    XCTAssertEqual(avatar.frame.midX, homeFrame.midX, accuracy: 2, "\(title) profile X")
                }
                XCTAssertEqual(avatar.frame.midY, homeFrame.midY, accuracy: 2, "\(title) profile Y")
            } else {
                homeFrame = avatar.frame
                XCTAssertGreaterThan(avatar.frame.midX, app.frame.midX)
            }
            if !vertical {
                // Native grouped actions have different padding from a single horizontal item.
                XCTAssertGreaterThan(avatar.frame.midX, app.frame.maxX - 80)
                XCTAssertTrue(app.navigationBars.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Settings for ")
                ).firstMatch.exists)
            }
            if vertical && title == "Search" {
                XCTAssertFalse(app.buttons["search-settings-avatar"].exists)
                let field = app.textFields["Search your libraries"]
                XCTAssertTrue(field.isHittable)
                field.tap()
                field.typeText("Sample")
                let entered = expectation(for: NSPredicate(format: "value == %@", "Sample"), evaluatedWith: field)
                wait(for: [entered], timeout: 5)
                XCTAssertEqual(field.value as? String, "Sample", app.debugDescription)
                app.buttons["Clear search"].tap()
            }
            capture("profile-\(vertical ? "rail" : "top")-\(title)")
            avatar.tap()
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
            close.tap()
            XCTAssertTrue(avatar.wait(for: \.isHittable, toEqual: true, timeout: 5))
        }
    }

    private func select(_ title: String) {
        let tab = app.buttons[title].firstMatch
        XCTAssertTrue(tab.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        tab.tap()
    }

    private func capture(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "\(name)-screen-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
