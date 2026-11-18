import XCTest

@MainActor
final class LiveContentRefreshInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testJellyfinMovieReturn() async throws { try await exercise("jellyfin", scope: "movie") }
    func testJellyfinSeriesReturn() async throws { try await exercise("jellyfin", scope: "series") }
    func testJellyfinHomeReturn() async throws { try await exercise("jellyfin", scope: "home") }
    func testPlexMovieReturn() async throws { try await exercise("plex", scope: "movie") }
    func testPlexSeriesReturn() async throws { try await exercise("plex", scope: "series") }
    func testPlexHomeReturn() async throws { try await exercise("plex", scope: "home") }

    private func exercise(_ provider: String, scope: String) async throws {
        guard let value = ProcessInfo.processInfo.environment["PLOZZ_LIVE_REFRESH_BROKER"] else {
            throw XCTSkip("Requires the authorized internal live-refresh broker.")
        }
        let broker = try XCTUnwrap(URL(string: value))
        guard broker.scheme == "http", broker.host == "127.0.0.1", broker.port != nil,
              broker.user == nil, broker.password == nil, broker.query == nil,
              broker.fragment == nil else { throw LiveRefreshError.invalidBroker }
        try await change("prepare", provider: provider, scope: scope, broker: broker)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--live-content-refresh-fixture"]
        app.launchEnvironment = [
            "PLOZZ_LIVE_REFRESH_BROKER": value,
            "PLOZZ_LIVE_REFRESH_PROVIDER": provider,
            "PLOZZ_LIVE_REFRESH_SCOPE": scope
        ]
        app.launch()
        defer { app.terminate() }
        let status = app.staticTexts["live-refresh-status"]
        let before = scope == "series" ? "series:first" : scope == "home" ? "home:300" : "movie:0"
        try await waitFor(status, label: before, seconds: 90)
        let play = app.buttons["detail-hero-play"]
        if scope != "home" { XCTAssertTrue(play.waitForExistence(timeout: 30)) }
        let playBefore = scope == "home" ? "" : play.label
        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let left = ContinuousClock.now
        try await change("advance", provider: provider, scope: scope, broker: broker)
        // Use the real production wall-clock thresholds, without clock injection.
        let delay: Duration = scope == "home" ? .seconds(20) : .seconds(305)
        try await Task.sleep(until: left.advanced(by: delay), clock: .continuous)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let expected = scope == "series" ? "series:second" : "\(scope):900"
        try await waitFor(status, label: expected, seconds: 90)
        if scope != "home" {
            XCTAssertNotEqual(play.label, playBefore, "The real Play button must reflect the refreshed model.")
        }
        print("LIVE_REFRESH passed provider=\(provider) scope=\(scope) realThreshold=true")
    }

    private func change(_ action: String, provider: String, scope: String, broker: URL) async throws {
        var request = URLRequest(
            url: broker.appendingPathComponent(provider).appendingPathComponent(action).appendingPathComponent(scope),
            timeoutInterval: 90
        )
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LiveRefreshError.serverOperation }
    }

    private func waitFor(_ element: XCUIElement, label: String, seconds: TimeInterval) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if element.exists && element.label == label { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("Live refresh state did not converge to \(label); observed \(element.exists ? element.label : "missing").")
        throw LiveRefreshError.didNotConverge
    }

    private enum LiveRefreshError: Error { case invalidBroker, serverOperation, didNotConverge }
}
