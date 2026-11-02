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

    func testOpenLibrarySettings() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-libraries"])
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 15))
    }

    func testEnableEpisodeLibraries() throws {
        try testOpenLibrarySettings()
        let shows = app.collectionViews.buttons["TV Shows"]
        try tapVisible(shows, tapping: false)
        XCTAssertFalse(shows.isSelected)
        XCTAssertTrue(app.collectionViews.buttons["TV shows"].isSelected)
        shows.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: shows)
        try require(XCTWaiter.wait(for: [selected], timeout: 10) == .completed, "Expected the destination TV library")
        try testOpenLibrarySettings()
        XCTAssertTrue(app.collectionViews.buttons["TV Shows"].isSelected)
    }

    func testSelectEpisodeSourceLibrary() throws {
        let selected = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_LIBRARY"])
        try require(["TV Shows", "TV shows"].contains(selected), "Expected an exact verified source library")
        let excluded = selected == "TV Shows" ? "TV shows" : "TV Shows"
        try testOpenLibrarySettings()
        for (label, shouldSelect) in [(selected, true), (excluded, false)] {
            let control = app.collectionViews.buttons[label]
            try tapVisible(control, tapping: false)
            if control.isSelected != shouldSelect { control.tap() }
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == %@", NSNumber(value: shouldSelect)), object: control
            )
            try require(XCTWaiter.wait(for: [changed], timeout: 10) == .completed,
                        "Expected the exact source-library selection")
        }
        try testOpenLibrarySettings()
        XCTAssertTrue(app.collectionViews.buttons[selected].isSelected)
        XCTAssertFalse(app.collectionViews.buttons[excluded].isSelected)
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

    func testInspectPlaybackReporting() throws {
        try openPlaybackReporting()
        XCTAssertTrue(app.staticTexts["Playback reporting enabled"].exists)
    }

    func testInspectUnsupportedEpisodeReporting() throws {
        try openPlaybackReporting()
        try tapVisible(app.staticTexts[
            "A session could not be reported because its content identity or episode order was not confirmed."
        ], tapping: false)
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

    func testDisableCrossServerWatchSync() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-playback"])
        let control = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Sync across servers")).firstMatch
        try tapVisible(control, tapping: false)
        if control.value as? String == "1" {
            try tapVisible(control.switches.firstMatch)
        }
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: control)
        try require(XCTWaiter.wait(for: [disabled], timeout: 5) == .completed,
                    "Independent tracker-import tests require cross-server playback mirroring off")
    }

    func testCreatePrivateAcceptanceList() throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_NAME"])
        try require(!name.isEmpty, "Expected the explicit test-list name")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Create a list"])
        let field = app.textFields["publicmetadb.list.name"]
        try tapVisible(field)
        field.typeText(name)
        XCTAssertEqual(app.switches["Public list"].value as? String, "0")
        app.swipeUp()
        let confirm = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Create list", "publicmetadb.list.create"
        )).firstMatch
        try tapVisible(app.buttons["publicmetadb.list.create"])
        try require(confirm.waitForExistence(timeout: 5), "Expected list confirmation")
        try tapVisible(app.otherElements["PopoverDismissRegion"])
        try require(confirm.waitForNonExistence(timeout: 5), "Expected cancellation to dismiss confirmation")
        XCTAssertTrue(app.textFields["publicmetadb.list.name"].exists)
        try tapVisible(app.buttons["publicmetadb.list.create"])
        try require(confirm.waitForExistence(timeout: 5), "Expected the new list confirmation")
        try require(confirm.isHittable, "Expected the confirmation action, not the underlying form")
        confirm.tap()
        try require(app.staticTexts["List created on PublicMetaDB"].waitForExistence(timeout: 45),
                    "Expected independently confirmed private-list creation")
    }

    func testBrowseExactAcceptanceList() throws {
        try openAcceptanceList()
        XCTAssertTrue(app.staticTexts["Private"].exists)
        try tapVisible(app.buttons["Browse items"])
        try require(app.staticTexts["No records"].waitForExistence(timeout: 30), "Expected an empty new list")
    }

    func testPrepareExactListDeletion() throws {
        try openAcceptanceList()
        try tapVisible(app.buttons["publicmetadb.list.delete"])
        try require(listDeletionConfirmation.waitForExistence(timeout: 5), "Expected exact-list confirmation")
    }

    func testCancelExactListDeletion() throws {
        try require(listDeletionConfirmation.exists, "Expected the pending exact-list confirmation")
        try tapVisible(app.otherElements["PopoverDismissRegion"])
        try require(listDeletionConfirmation.waitForNonExistence(timeout: 5), "Expected cancellation")
        XCTAssertTrue(app.buttons["publicmetadb.list.delete"].exists)
    }

    func testConfirmExactListDeletion() throws {
        try require(listDeletionConfirmation.exists && listDeletionConfirmation.isHittable,
                    "Expected the pending exact-list confirmation")
        listDeletionConfirmation.tap()
        try require(app.staticTexts["List deleted from PublicMetaDB"].waitForExistence(timeout: 45),
                    "Expected confirmed exact-list deletion")
    }

    private var listDeletionConfirmation: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Delete list", "publicmetadb.list.delete"
        )).firstMatch
    }

    private func openAcceptanceList() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_ID"])
        try require(!id.isEmpty, "Expected the exact run-owned list")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Lists"])
        try tapVisible(app.buttons["publicmetadb.list.record.\(id)"])
        try require(app.buttons["publicmetadb.list.delete"].exists, "Expected owned-list controls")
    }

    func testEnableOngoingWatchedImport() throws {
        try enableOngoingImport(categories: [("watched", "Watched")])
    }

    func testEnableOngoingResumeImport() throws {
        try enableOngoingImport(categories: [("resume", "Resume points")])
    }

    func testEnableOngoingWatchedAndResumeImport() throws {
        try enableOngoingImport(categories: [("watched", "Watched"), ("resume", "Resume points")])
    }

    private func enableOngoingImport(categories: [(id: String, label: String)]) throws {
        try openHistoryComparison()
        try tapVisible(app.buttons["tracker-history.ongoing-sync"])
        let accountID = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ACCOUNT"])
        let destination = app.switches.matching(NSPredicate(
            format: "identifier == %@", "tracker-history.sync-server.\(accountID)"
        )).firstMatch
        let watched = app.switches["tracker-history.sync-watched"]
        XCTAssertEqual(destination.value as? String, "0")
        XCTAssertEqual(watched.value as? String, "0")
        XCTAssertEqual(app.switches["tracker-history.sync-resume"].value as? String, "0")
        try tapVisible(destination.switches.firstMatch)
        for category in categories {
            try tapVisible(app.switches["tracker-history.sync-\(category.id)"].switches.firstMatch)
        }
        try tapVisible(app.buttons["tracker-history.enable-sync"])
        let confirm = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Enable sync", "tracker-history.enable-sync"
        )).firstMatch
        try require(confirm.waitForExistence(timeout: 5) && confirm.isHittable,
                    "Expected the native confirmation action, not the underlying Enable sync form")
        confirm.tap()
        try require(app.buttons["tracker-history.disable-sync"].waitForExistence(timeout: 30),
                    "Expected separate ongoing-import permission")
        let summary = categories.count == 2 ? "Watched and resume points" : categories[0].label
        XCTAssertTrue(app.staticTexts[summary].exists)
    }

    func testSynchronizeOngoingImport() throws {
        try synchronizeOngoingImport(expectingReview: false)
    }

    func testOngoingSyncReportsReviewRequirement() throws {
        try synchronizeOngoingImport(expectingReview: true)
    }

    private func synchronizeOngoingImport(expectingReview: Bool) throws {
        try openHistoryComparison()
        try tapVisible(app.buttons["tracker-history.ongoing-sync"])
        try require(app.buttons["tracker-history.disable-sync"].exists, "Expected existing sync permission")
        try tapVisible(app.buttons["tracker-history.sync-now"])
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: app.buttons["tracker-history.sync-now"]
        )
        try require(XCTWaiter.wait(for: [completed], timeout: 65) == .completed, "Expected bounded sync completion")
        XCTAssertEqual(app.staticTexts["Some changes need review. Compare with server history before retrying."].exists,
                       expectingReview, "Review deferral and confirmed ongoing delivery are different outcomes")
    }

    func testDisableOngoingImport() throws {
        try openHistoryComparison()
        try tapVisible(app.buttons["tracker-history.ongoing-sync"])
        try tapVisible(app.buttons["tracker-history.disable-sync"])
        try require(app.buttons["tracker-history.enable-sync"].waitForExistence(timeout: 10),
                    "Expected revoked ongoing-import permission")
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
        try tapVisible(importSelection, tapping: false)
        XCTAssertTrue(importSelection.exists)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false)
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
        try tapVisible(importSelection, tapping: false)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false)
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
        try tapVisible(importSelection, tapping: false)
        let expected = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_EXPECTED_RESUME_SECONDS"] ?? "90"
        ))
        XCTAssertTrue(app.staticTexts[
            "Server resume: \(expected.formatted(.number.precision(.fractionLength(0)))) seconds"
        ].exists)
        XCTAssertTrue(app.staticTexts["Different from server — selecting replaces its current state"].exists)
        try confirmSelectedHistoryImport()
    }

    private func confirmSelectedHistoryImport() throws {
        try selectHistoryImport()
        let confirm = app.buttons["Apply selected changes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        try testInspectConfirmedHistoryImport()
    }

    func testInspectConfirmedHistoryImport() throws {
        let rows = try historyImportRows()
        for _ in 0..<8 {
            if rows.firstMatch.exists && rows.firstMatch.isHittable { break }
            app.swipeDown()
        }
        try require(rows.count == 1 && rows.firstMatch.isHittable, "Expected the exact selected import row")
        XCTAssertTrue(rows.firstMatch.staticTexts["Confirmed on server"].waitForExistence(timeout: 60))
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testImportedHistoryMatchesAfterRelaunch() throws {
        try openHistoryComparison()
        let rows = try historyImportRows()
        try tapVisible(rows.firstMatch, tapping: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.staticTexts["Already matches — no change"].exists)
        XCTAssertFalse(importSelection.exists)
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    private func historyImportRows() throws -> XCUIElementQuery {
        let environment = ProcessInfo.processInfo.environment
        let episodeTitle = environment["PLOZZ_TRACKER_HISTORY_EPISODE_TITLE"] ?? ""
        let title = try XCTUnwrap(
            episodeTitle.isEmpty ? environment["PLOZZ_TRACKER_HISTORY_TITLE"] : episodeTitle
        )
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_USER"])
        return app.cells.containing(.staticText, identifier: title)
            .containing(NSPredicate(format: "label ENDSWITH %@", " · \(user)"))
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
        try require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", user))
            .firstMatch.waitForExistence(timeout: 60), "Expected the dedicated user's real comparison rows")
    }

    private func selectHistoryImport() throws {
        try tapVisible(importSelection, tapping: false)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(importSelection.switches.firstMatch)
        XCTAssertEqual(importSelection.value as? String, "1")
        let apply = app.buttons["tracker-history.apply"]
        try tapVisible(apply, tapping: false)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        try require(XCTWaiter.wait(for: [selected], timeout: 5) == .completed, "Expected the selected import action")
        XCTAssertEqual(apply.label, "Apply 1 selected changes")
        try tapVisible(apply)
    }

    private func enableReporting() throws {
        try tapVisible(app.buttons["publicmetadb.playback.enable"])
        let confirm = app.buttons["Enable reporting"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Playback reporting enabled"].waitForExistence(timeout: 10))
    }

    func testOpenSelectedMovie() throws {
        try openSelectedTitle()
    }

    func testOpenSelectedSeries() throws {
        try openSelectedTitle()
    }

    private func openSelectedTitle() throws {
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
        let matches = app.buttons.containing(.staticText, identifier: title).matching(NSPredicate(
            format: "NOT (label MATCHES %@)", ".*, S[0-9]+ · E[0-9]+ · .*"
        ))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 30))
        try require(matches.count == 1, "Expected one exact title card in the selected libraries")
        matches.element.tap()
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

    func testReplayMovieToCompletion() async throws {
        let duration = try verifiedRuntime()
        try await seekAndPlay(
            fraction: 0.9 - 20 / duration, minimumElapsedSeconds: Int(ceil(duration * 0.9))
        )
    }

    func testPlayMovieFromResumePosition() async throws {
        let duration = try verifiedRuntime()
        let fraction = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SEEK_FRACTION"] ?? ""
        ))
        try require(fraction.isFinite && (0.03...0.6).contains(fraction), "Expected an in-range resume seek")
        try await seekAndPlay(
            fraction: fraction, minimumElapsedSeconds: Int(duration * fraction),
            maximumElapsedSeconds: Int(duration * 0.8)
        )
    }

    func testPlaySelectedEpisodeBelowResumeThreshold() async throws {
        let duration = try verifiedRuntime()
        let maximum = Int(floor(duration * 0.02)) - 1
        try require(maximum > 5, "Expected room below the resume threshold")
        try startSelectedEpisodePlayback()
        try await seekActivePlayback(
            fraction: 0, minimumElapsedSeconds: 1, maximumElapsedSeconds: maximum,
            playSeconds: min(27, maximum - 5)
        )
    }

    func testPlaySelectedEpisodeFromResumePosition() async throws {
        let duration = try verifiedRuntime()
        let fraction = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SEEK_FRACTION"] ?? ""
        ))
        try require(fraction.isFinite && (0.03...0.6).contains(fraction), "Expected an in-range resume seek")
        try startSelectedEpisodePlayback()
        try await seekActivePlayback(
            fraction: fraction, minimumElapsedSeconds: Int(duration * fraction),
            maximumElapsedSeconds: Int(duration * 0.8)
        )
    }

    func testSelectEpisodeSeason() throws {
        try selectEpisodeSeason()
    }

    func testReplayEpisodeToCompletion() async throws {
        let duration = try verifiedRuntime()
        try startSelectedEpisodePlayback()
        try await seekActivePlayback(
            fraction: 0.9 - 20 / duration, minimumElapsedSeconds: Int(ceil(duration * 0.9))
        )
    }

    func testPlayEpisodeAboveResumeRange() async throws {
        let duration = try verifiedRuntime()
        try startSelectedEpisodePlayback()
        try await seekActivePlayback(
            fraction: 0.82, minimumElapsedSeconds: Int(duration * 0.8) + 1,
            maximumElapsedSeconds: Int(duration * 0.9) - 1
        )
    }

    private func startSelectedEpisodePlayback() throws {
        let environment = ProcessInfo.processInfo.environment
        let title = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_EPISODE_TITLE"])
        try require(!title.isEmpty, "Expected the independently verified episode")
        try selectEpisodeSeason()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let rails = app.scrollViews.containing(NSPredicate(
            format: "elementType == %d AND label BEGINSWITH %@", XCUIElement.ElementType.staticText.rawValue, "EPISODE "
        )).allElementsBoundByIndex.filter { $0.frame.height < app.frame.height * 0.8 }
        try require(rails.count == 1, "Expected one native episode rail")
        let rail = rails[0]
        try tapVisible(rail, tapping: false)
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.frame.minY
        try require(bottom > top + rail.frame.height, "Expected room for the complete episode rail")
        for _ in 0..<8 {
            if rail.frame.minY >= top && rail.frame.maxY <= bottom { break }
            let downward = rail.frame.midY < (top + bottom) / 2
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.35 : 0.65))
                .press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.65 : 0.35)),
                    withVelocity: .slow, thenHoldForDuration: 0.2
                )
        }
        try require(rail.frame.minY >= top && rail.frame.maxY <= bottom,
                    "Expected the episode rail clear of navigation controls")
        for _ in 0..<10 {
            var forward = true
            if episode.count == 1 {
                let frame = episode.element.frame
                if frame.minX >= rail.frame.minX && frame.maxX <= rail.frame.maxX { break }
                forward = frame.minX >= rail.frame.minX
            }
            rail.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.8 : 0.2, dy: 0.3))
                .press(
                    forDuration: 0.1,
                    thenDragTo: rail.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.2 : 0.8, dy: 0.3)),
                    withVelocity: .slow, thenHoldForDuration: 0.2
                )
        }
        try require(episode.count == 1, "Expected one exact episode action")
        try require(episode.element.frame.minX >= rail.frame.minX && episode.element.frame.maxX <= rail.frame.maxX,
                    "Expected the exact horizontally visible episode")
        try tapVisible(episode.element, tapping: false)
        startedPlayback = true
        episode.element.tap()
        try require(app.buttons["Close player"].waitForExistence(timeout: 45), "Expected real episode playback")
    }

    private func selectEpisodeSeason() throws {
        let season = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SEASON_LABEL"])
        try require(!season.isEmpty, "Expected the independently verified season")
        let tabs = app.scrollViews["series-season-tabs"]
        try tapVisible(tabs, tapping: false)
        let target = tabs.buttons[season]
        for _ in 0..<8 {
            if target.exists && target.isHittable && tabs.frame.contains(target.frame) { break }
            let forward = target.exists && target.frame.maxX > tabs.frame.maxX
            tabs.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.8 : 0.2, dy: 0.5))
                .press(
                    forDuration: 0.1,
                    thenDragTo: tabs.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.2 : 0.8, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.2
                )
        }
        try require(target.exists && target.isHittable && tabs.frame.contains(target.frame),
                    "Expected the exact fully visible season")
        if !target.isSelected { target.tap() }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: target)
        try require(XCTWaiter.wait(for: [selected], timeout: 10) == .completed,
                    "Expected the exact selected season")
    }

    private func verifiedRuntime() throws -> Double {
        let duration = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RUNTIME_SECONDS"] ?? ""
        ))
        try require(duration.isFinite && (100...86_400).contains(duration), "Expected independently verified runtime")
        return duration
    }

    private func seekAndPlay(
        fraction: Double, minimumElapsedSeconds: Int, maximumElapsedSeconds: Int? = nil
    ) async throws {
        try require(detailPlayButton.exists && detailPlayButton.isHittable, "Expected the exact movie detail")
        startedPlayback = true
        detailPlayButton.tap()
        try require(app.buttons["Close player"].waitForExistence(timeout: 45), "Expected real playback")
        try await seekActivePlayback(
            fraction: fraction, minimumElapsedSeconds: minimumElapsedSeconds,
            maximumElapsedSeconds: maximumElapsedSeconds
        )
    }

    private func seekActivePlayback(
        fraction: Double, minimumElapsedSeconds: Int, maximumElapsedSeconds: Int? = nil,
        playSeconds: Int = 27
    ) async throws {
        try await Task.sleep(for: .seconds(1))
        try pausePlayback()
        let scrubber = app.otherElements["player-timeline-scrubber"]
        try require(scrubber.exists && scrubber.isHittable, "Expected the real player timeline")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(
                withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)
            ))
        try require(app.buttons["Play"].waitForExistence(timeout: 5) && app.buttons["Play"].isHittable,
                    "Expected paused playback after the real seek")
        app.buttons["Play"].tap()
        try await Task.sleep(for: .seconds(playSeconds))
        try pauseAndClose(
            maximumElapsedSeconds: maximumElapsedSeconds, minimumElapsedSeconds: minimumElapsedSeconds
        )
    }

    private func pauseAndClose(maximumElapsedSeconds: Int? = nil, minimumElapsedSeconds: Int? = nil) throws {
        try pausePlayback()
        if maximumElapsedSeconds != nil || minimumElapsedSeconds != nil {
            let value = try XCTUnwrap(app.buttons["player-timeline-current-time"].value as? String)
            let parts = try value.split(separator: ":").map { try XCTUnwrap(Int($0)) }
            XCTAssertTrue((2...3).contains(parts.count))
            let elapsed = parts.reduce(0) { $0 * 60 + $1 }
            if let maximumElapsedSeconds { XCTAssertLessThanOrEqual(elapsed, maximumElapsedSeconds) }
            if let minimumElapsedSeconds { XCTAssertGreaterThanOrEqual(elapsed, minimumElapsedSeconds) }
        }
        recordState()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["Close player"].waitForNonExistence(timeout: 10))
        startedPlayback = false
    }

    private func pausePlayback() throws {
        if !app.buttons["Pause"].exists || !app.buttons["Pause"].isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try require(app.buttons["Pause"].waitForExistence(timeout: 5),
                        "Expected playback controls after revealing them")
        }
        try require(app.buttons["Pause"].exists && app.buttons["Pause"].isHittable,
                    "Expected the visible real pause control")
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
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
            if target.exists && !target.frame.isEmpty && target.frame.midY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
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
