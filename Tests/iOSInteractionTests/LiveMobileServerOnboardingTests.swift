import XCTest

/// Opt-in local integration checks. The loopback helper reads the private registry
/// and approves Quick Connect without exposing credentials to XCTest or attachments.
@MainActor
final class LiveMobileServerOnboardingTests: XCTestCase {
    private struct Connection: Decodable {
        let baseURL: String
        let username: String
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testLiveEmbyPasswordlessSignIn() async throws {
        let helper = try helperURL()
        let connection = try await connection("emby", helper: helper)
        let app = launch()
        defer { app.terminate() }
        open("emby", connection: connection, app: app)
        let username = app.textFields["server-sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        username.typeText(connection.username)
        app.buttons["server-sign-in-submit"].tap()
        assertPersisted("emby", connection: connection, app: app)
    }

    func testLiveJellyfinQuickConnectSignIn() async throws {
        let helper = try helperURL()
        let connection = try await connection("jellyfin", helper: helper)
        let app = launch()
        defer { app.terminate() }
        open("jellyfin", connection: connection, app: app)
        let code = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]{6}$")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 20))
        var request = URLRequest(url: helper.appendingPathComponent("approve-jellyfin"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code.label])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Live Quick Connect approval failed")
        assertPersisted("jellyfin", connection: connection, app: app)
    }

    private func helperURL() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["PLOZZ_ONBOARDING_LIVE_HELPER"],
              let url = URL(string: value), url.host == "127.0.0.1" else {
            throw XCTSkip("Set PLOZZ_ONBOARDING_LIVE_HELPER to an authorized local test helper.")
        }
        return url
    }

    private func connection(_ provider: String, helper: URL) async throws -> Connection {
        let (data, response) = try await URLSession.shared.data(
            from: helper.appendingPathComponent("connection/\(provider)")
        )
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(Connection.self, from: data)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-page=live"]
        app.launch()
        return app
    }

    private func open(_ provider: String, connection: Connection, app: XCUIApplication) {
        app.buttons["add-server-provider-\(provider)"].tap()
        let address = app.textFields["add-server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(connection.baseURL + "\n")
    }

    private func assertPersisted(_ provider: String, connection: Connection, app: XCUIApplication) {
        let completed = app.staticTexts["onboarding-completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 30))
        XCTAssertEqual(completed.label, "Added: \(provider):\(connection.username)")
    }
}
