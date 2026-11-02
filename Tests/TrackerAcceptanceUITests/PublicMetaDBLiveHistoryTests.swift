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

    func testFinishIndependentServerLibraries() throws {
        try finishIndependentServerLibraries()
    }

    private func finishIndependentServerLibraries() throws {
        let savePassword = app.sheets["Save Password?"]
        if savePassword.waitForExistence(timeout: 3) {
            savePassword.buttons["Not Now"].tap()
            try require(savePassword.waitForNonExistence(timeout: 5), "Password save prompt did not close")
        }
        try require(app.navigationBars["Choose Your Libraries"].waitForExistence(timeout: 30),
                    "Expected library selection after sign-in")
        try require(app.switches["Movies"].waitForExistence(timeout: 30), "Expected destination movie library")
        let libraries = app.switches.matching(NSPredicate(format: "label != ''")).allElementsBoundByIndex
        try require(!libraries.isEmpty && libraries.count <= 20, "Expected a bounded library selection")
        for library in libraries where library.label != "Movies" && library.value as? String == "1" {
            try tapVisible(library.switches.firstMatch)
            let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: library)
            try require(XCTWaiter.wait(for: [disabled], timeout: 5) == .completed,
                        "Only the movie library should remain selected")
        }
        try require(app.switches["Movies"].value as? String == "1", "Movies must be selected")
        try tapVisible(app.buttons["Continue"])
        try require(app.navigationBars["Choose Your Libraries"].waitForNonExistence(timeout: 15),
                    "Library selection did not finish")
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_USER"])
        try require(app.staticTexts["Signed in as \(user)"].waitForExistence(timeout: 10),
                    "Expected the dedicated destination account on the Servers page")
    }

    func testOpenHistoryComparison() throws {
        try openHistoryComparison()
        XCTAssertTrue(importSelection.exists)
        XCTAssertEqual(importSelection.value as? String, "0")
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testCancelHistoryImportAndReopen() throws {
        try openHistoryComparison()
        try selectHistoryImport()
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].firstMatch.exists {
            try tapVisible(app.buttons["Cancel"].firstMatch)
        } else {
            try tapVisible(app.otherElements["PopoverDismissRegion"])
        }
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(importSelection.value as? String, "1")
        try openHistoryComparison()
        XCTAssertEqual(importSelection.value as? String, "0")
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testConfirmSelectedHistoryImport() throws {
        try openHistoryComparison()
        try confirmSelectedHistoryImport()
    }

    func testPrepareStaleHistoryImport() throws {
        try openHistoryComparison()
        XCTAssertTrue(app.staticTexts["Server resume: 75 seconds"].exists)
        XCTAssertTrue(app.staticTexts["Different from server — selecting replaces its current state"].exists)
        try selectHistoryImport()
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForExistence(timeout: 5))
    }

    func testRejectStaleHistoryImport() throws {
        XCTAssertEqual(importSelection.value as? String, "1")
        let confirm = app.buttons["Apply selected changes"]
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Not confirmed. Compare again before retrying."].waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["Confirmed on server"].exists)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testConfirmFreshHistoryConflict() throws {
        try openHistoryComparison()
        XCTAssertTrue(app.staticTexts["Server resume: 90 seconds"].exists)
        XCTAssertTrue(app.staticTexts["Different from server — selecting replaces its current state"].exists)
        try confirmSelectedHistoryImport()
    }

    private func confirmSelectedHistoryImport() throws {
        try selectHistoryImport()
        let confirm = app.buttons["Apply selected changes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Confirmed on server"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testImportedHistoryMatchesAfterRelaunch() throws {
        try openHistoryComparison()
        XCTAssertFalse(importSelection.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Already matches — no change").count, 2)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    private var importSelection: XCUIElement {
        let environment = ProcessInfo.processInfo.environment
        let accountID = environment["PLOZZ_TRACKER_IMPORT_ACCOUNT"] ?? "missing-import-account"
        let itemID = environment["PLOZZ_TRACKER_IMPORT_ITEM"] ?? "missing-import-item"
        return app.switches.matching(NSPredicate(
            format: "identifier == %@", "tracker-history.select.\(accountID):\(itemID)"
        )).firstMatch
    }

    private func openHistoryComparison() throws {
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_USER"])
        let item = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ITEM"])
        let account = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ACCOUNT"])
        XCTAssertFalse(user.isEmpty || item.isEmpty || account.isEmpty)
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.compare-history"])
        XCTAssertTrue(app.buttons["tracker-history.apply"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", user)).firstMatch.exists)
    }

    private func selectHistoryImport() throws {
        XCTAssertTrue(importSelection.exists && importSelection.isHittable)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(importSelection.switches.firstMatch)
        let apply = app.buttons["tracker-history.apply"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        try require(XCTWaiter.wait(for: [selected], timeout: 5) == .completed, "Expected the selected import action")
        XCTAssertEqual(importSelection.value as? String, "1")
        XCTAssertEqual(apply.label, "Apply 1 selected changes")
        apply.tap()
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
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.playback"])
    }

    private func openPublicMetaDBAccount() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-trackers"])
        try tapVisible(app.buttons["publicmetadb.browse"])
    }

    private func openSettings() throws {
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_USER"])
        app.terminate()
        app.launch()
        let settings = app.buttons["Settings for \(user)"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
    }

    private func tapVisible(_ target: XCUIElement, tapping: Bool = true) throws {
        _ = target.waitForExistence(timeout: 5)
        for _ in 0..<8 {
            if target.exists && target.isHittable { break }
            app.swipeUp()
        }
        guard target.exists && target.isHittable else { throw Failure.expectedVisibleElement }
        if tapping { target.tap() }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.precondition(message) }
    }

    private enum Failure: Error {
        case expectedVisibleElement
        case precondition(String)
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
