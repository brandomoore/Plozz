import XCTest

@MainActor
final class LiveJellyfinOnboardingInteractionTests: XCTestCase {
    private struct Connection: Decodable {
        let baseURL: String
        let username: String
        let password: String
    }

    override func setUp() { continueAfterFailure = false }

    func testFreshManualJellyfinSignIn() async throws {
        try await signIn(discovered: false)
    }

    func testFreshDiscoveredJellyfinSignIn() async throws {
        try await signIn(discovered: true)
    }

    func testFreshBareAddressJellyfinSignIn() async throws {
        try await signIn(discovered: false, omittingScheme: true)
    }

    private func signIn(discovered: Bool, omittingScheme: Bool = false) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires an owned simulator.")
        #else
        guard let address = ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_ONBOARDING_BROKER"],
              let url = URL(string: address), url.host == "127.0.0.1" else {
            throw XCTSkip("Requires the private internal-account broker.")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let connection = try JSONDecoder().decode(Connection.self, from: data)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--live-jellyfin-onboarding", "-com.plozz.syncSetup.enabled", "NO"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Jellyfin"].waitForExistence(timeout: 40))
        capture(app, "01 Fresh provider chooser")
        select(app.buttons["Jellyfin"], in: app)
        let field = app.textFields["Server address"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        capture(app, "02 Discovery and manual address screen")
        if discovered {
            let host = try XCTUnwrap(URL(string: connection.baseURL)?.host)
            let server = app.buttons.matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", host, "On your network"
            )).firstMatch
            XCTAssertTrue(server.waitForExistence(timeout: 20), app.debugDescription)
            capture(app, "03 Automatically discovered server")
            select(server, in: app)
        } else {
            select(field, in: app)
            let scheme = try XCTUnwrap(connection.baseURL.range(of: "://"))
            let address = omittingScheme ? String(connection.baseURL[scheme.upperBound...]) : connection.baseURL
            app.textFields.firstMatch.typeText(address)
            capture(app, "03 Manual address entered")
            XCUIRemote.shared.press(.menu)
            select(app.buttons["Connect"], in: app)
        }
        let passwordChoice = app.buttons["Sign in with username & password"]
        let accepted = passwordChoice.waitForExistence(timeout: 20)
        capture(app, accepted ? "04 Server accepted" : "04 Server entry failed")
        XCTAssertTrue(accepted, app.debugDescription)
        capture(app, "04 Server accepted and Quick Connect offered")
        select(passwordChoice, in: app)
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 15))
        capture(app, "05 Password sign-in form")
        select(username, in: app)
        app.textFields.firstMatch.typeText(connection.username)
        XCUIRemote.shared.press(.menu)
        let password = app.secureTextFields["Password"]
        select(password, in: app)
        app.secureTextFields.firstMatch.typeText(connection.password)
        XCUIRemote.shared.press(.menu)
        select(app.buttons["Sign In"], in: app)
        let libraries = app.buttons["library-selection-continue"]
        XCTAssertTrue(libraries.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Choose your libraries"].exists)
        capture(app, "06 Authenticated library selection")
        waitUntil { libraries.label == "Continue" }
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture(app, "07 Real libraries loaded")
        #endif
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func select(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<18 {
            if element.hasFocus { break }
            let focused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { XCUIRemote.shared.press(.down); continue }
            let dx = element.frame.midX - focused.frame.midX
            let dy = element.frame.midY - focused.frame.midY
            XCUIRemote.shared.press(abs(dy) > 40 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
        }
        XCTAssertTrue(element.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed)
    }
}
