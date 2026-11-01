import XCTest

#if os(iOS)
@MainActor
final class PublicMetaDBLiveHistoryTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
    private var startedPlayback = false
    private var authorizedLiveRun = false

    override func setUp() async throws {
        try await MainActor.run {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            XCTAssertEqual(environment["PLOZZ_TRACKER_HISTORY_LIVE"], "1")
            let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_SIMULATOR"])
            XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(app.launchArguments.isEmpty)
            XCTAssertTrue(app.launchEnvironment.isEmpty)
            authorizedLiveRun = true
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            guard authorizedLiveRun else { return }
            recordState()
            if startedPlayback { app.terminate() }
        }
    }

    func testInspectLiveApp() {
        recordState()
    }

    func testPasswordlessEmbyOnboarding() throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_SERVER"])
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_USER"])
        let url = try XCTUnwrap(URLComponents(string: address))
        XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertFalse(user.isEmpty)

        if app.buttons["Don't Share"].waitForExistence(timeout: 3) {
            app.buttons["Don't Share"].tap()
        }
        let provider = app.buttons["Emby"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.tap()
        let server = app.textFields["Server address"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap()
        server.typeText(address)
        app.buttons["Continue"].tap()
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 30))
        username.tap()
        username.typeText(user)
        let signIn = app.buttons["Sign In"]
        XCTAssertTrue(signIn.isEnabled)
        signIn.tap()
        XCTAssertTrue(username.waitForNonExistence(timeout: 45))
        XCTAssertTrue(app.navigationBars["Choose Your Libraries"].waitForExistence(timeout: 30))
    }

    func testFinishOnboarding() throws {
        if app.navigationBars["Choose Your Libraries"].exists {
            let shows = app.switches["TV shows"]
            if shows.value as? String == "1" { shows.tap() }
            XCTAssertEqual(app.switches["Movies"].value as? String, "1")
            app.buttons["Continue"].tap()
            XCTAssertTrue(app.navigationBars["Choose Your Libraries"].waitForNonExistence(timeout: 10))
        }
        XCTAssertTrue(app.staticTexts["Almost all settings are saved per profile."].waitForExistence(timeout: 10))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Not Now"].waitForExistence(timeout: 10))
        try tapVisible(app.buttons["Not Now"])
        XCTAssertTrue(app.staticTexts["Choose Your Look"].waitForExistence(timeout: 10))
        try tapVisible(app.buttons["Continue"])
        XCTAssertTrue(app.staticTexts["Choose Your Look"].waitForNonExistence(timeout: 10))
    }

    func testOpenPublicMetaDB() throws {
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_USER"])
        let settings = app.buttons["Settings for \(user)"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        try tapVisible(app.buttons["settings-category-trackers"])
        try tapVisible(app.buttons["publicmetadb.pair"], tapping: false)
        XCTAssertEqual(app.buttons["publicmetadb.pair"].label, "Enter API key")
    }

    func testEnablePlaybackReporting() throws {
        try openPlaybackReporting()
        try enableReporting()
    }

    func testRenewPlaybackConsent() throws {
        try openPlaybackReporting()
        try tapVisible(app.buttons["publicmetadb.playback.disable"])
        try enableReporting()
    }

    func testDisablePlaybackReporting() throws {
        try openPlaybackReporting()
        try tapVisible(app.buttons["publicmetadb.playback.disable"])
        XCTAssertTrue(app.buttons["publicmetadb.playback.enable"].waitForExistence(timeout: 5))
    }

    private func enableReporting() throws {
        try tapVisible(app.buttons["publicmetadb.playback.enable"])
        let confirm = app.buttons["Enable reporting"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Playback reporting enabled"].waitForExistence(timeout: 10))
    }

    func testOpenSelectedMovie() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        app.terminate()
        app.launch()
        let search = app.tabBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let query = app.textFields["Search your libraries"]
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap()
        query.typeText(title + "\n")
        let movie = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 30))
        movie.tap()
        XCTAssertTrue(detailPlayButton.waitForExistence(timeout: 15))
    }

    func testPlaySelectedMovie() async throws {
        let seconds = try XCTUnwrap(Int(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_PLAY_SECONDS"] ?? "25"))
        XCTAssertTrue((1...180).contains(seconds))
        let play = detailPlayButton
        XCTAssertTrue(play.exists && play.isHittable)
        startedPlayback = true
        play.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 45))
        try await Task.sleep(for: .seconds(seconds))
        try pauseAndClose()
    }

    func testRestartAndPauseBelowResumeThreshold() async throws {
        XCTAssertTrue(detailPlayButton.exists && detailPlayButton.isHittable)
        startedPlayback = true
        detailPlayButton.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 45))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let scrubber = app.otherElements["player-timeline-scrubber"]
        XCTAssertTrue(scrubber.exists && scrubber.isHittable)
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)))
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        app.buttons["Play"].tap()
        try await Task.sleep(for: .seconds(1))
        try pauseAndClose(maximumElapsedSeconds: 3)
    }

    private func pauseAndClose(maximumElapsedSeconds: Int? = nil) throws {
        if !app.buttons["Pause"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        if let maximumElapsedSeconds {
            let value = try XCTUnwrap(app.buttons["player-timeline-current-time"].value as? String)
            let parts = try value.split(separator: ":").map { try XCTUnwrap(Int($0)) }
            XCTAssertTrue((2...3).contains(parts.count))
            XCTAssertLessThanOrEqual(parts.reduce(0) { $0 * 60 + $1 }, maximumElapsedSeconds)
        }
        recordState()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForNonExistence(timeout: 10))
        startedPlayback = false
    }

    private var detailPlayButton: XCUIElement {
        app.buttons.containing(.image, identifier: "play.fill").firstMatch
    }

    private func openPlaybackReporting() throws {
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_USER"])
        app.terminate()
        app.launch()
        let settings = app.buttons["Settings for \(user)"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        try tapVisible(app.buttons["settings-category-trackers"])
        try tapVisible(app.buttons["publicmetadb.browse"])
        try tapVisible(app.buttons["publicmetadb.playback"])
    }

    private func tapVisible(_ target: XCUIElement, tapping: Bool = true) throws {
        for _ in 0..<8 {
            if target.exists && target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable)
        if tapping { target.tap() }
    }

    private func recordState() {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "live-history-native-state"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "live-history-native-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif
