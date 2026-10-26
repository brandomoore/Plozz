import XCTest

@MainActor
final class TrackerHistoryImportInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        #if os(tvOS)
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testCancellingAndReopeningNeverRestoresSelectionOrWrites() {
        launch()
        select("jellyfin")
        openConfirmation()
        cancelConfirmation()
        assertReport(jellyfin: 0, plex: 0)
        activate(app.buttons["fixture.history.close"])
        activate(app.buttons["fixture.history.open"])
        XCTAssertTrue(element("tracker-history.select.jellyfin:movie").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
        assertReport(jellyfin: 0, plex: 0)
    }

    func testJellyfinApprovalDoesNotWritePlexOrMirrorToTrackers() {
        verifySelectedServer("jellyfin")
    }

    func testPlexApprovalDoesNotWriteJellyfinOrMirrorToTrackers() {
        verifySelectedServer("plex")
    }

    func testExportJellyfinPreviewCancellationAndConfirmationLeaveServersUnchanged() {
        verifyExport("Jellyfin")
    }

    func testExportPlexPreviewCancellationAndConfirmationLeaveServersUnchanged() {
        verifyExport("Plex")
    }

    func testExportChangedTrackerStateRejectsDelivery() {
        launchExport("Jellyfin", arguments: ["--history-change-on-recheck"])
        confirmExport()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "changed after the comparison"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        assertExportReport(writes: 0)
    }

    func testExportLostReplyUsesReadbackWithoutReplayOnReentry() {
        launchExport("Plex", arguments: ["--history-lost-write-reply"])
        confirmExport()
        XCTAssertTrue(app.staticTexts["Already present; no additional play needed."].waitForExistence(timeout: 5))
        assertExportReport(writes: 1)
        activate(app.buttons["fixture.history.close"])
        openExport("Plex")
        XCTAssertTrue(app.staticTexts["Already present"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("tracker-export.select.movie").exists)
        assertExportReport(writes: 1)
    }

    func testExportReopeningRequiresNewSourceAndTitleSelection() {
        launchExport("Jellyfin")
        activate(element("tracker-export.select.movie"))
        XCTAssertTrue(app.buttons["tracker-export.apply"].isEnabled)
        activate(app.buttons["fixture.history.close"])
        activate(app.buttons["fixture.history.open"])
        XCTAssertTrue(app.buttons["tracker-export.preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tracker-export.preview"].isEnabled)
        XCTAssertFalse(element("tracker-export.select.movie").exists)
        assertExportReport(writes: 0)
    }

    func testOngoingJellyfinConsentCancellationAndNewHistoryStayScoped() {
        verifyOngoingSync("jellyfin")
    }

    func testOngoingPlexConsentCancellationAndNewHistoryStayScoped() {
        verifyOngoingSync("plex")
    }

    #if os(iOS)
    func testExportSelectionDoesNotActivateNeighboringActions() {
        launchExport("Jellyfin")
        let before = app.staticTexts["fixture.history.report"].label
        let selection = element("tracker-export.select.movie")
        activate(selection)
        XCTAssertEqual(app.staticTexts["fixture.history.report"].label, before)
        XCTAssertTrue(app.buttons["tracker-export.apply"].isEnabled)
        XCTAssertFalse(app.buttons["Export selected titles"].exists)
        activate(selection)
        XCTAssertEqual(app.staticTexts["fixture.history.report"].label, before)
        XCTAssertFalse(app.buttons["tracker-export.apply"].isEnabled)
        XCTAssertFalse(app.buttons["Export selected titles"].exists)
    }

    func testSelectionRowDoesNotActivateNeighboringActions() {
        launch()
        element("tracker-history.select.jellyfin:movie").tap()
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.hasSuffix(";reads=1"))
        XCTAssertFalse(app.buttons["Apply selected changes"].exists)
        assertReport(jellyfin: 0, plex: 0)
    }
    #endif

    func testTrackerChangesBeforeApprovalRejectAllWrites() {
        launch(["--history-change-on-recheck"])
        select("jellyfin")
        confirm()
        assertFailure(containing: "changed after the comparison")
    }

    func testScopeChangesDuringRecheckRejectAllWrites() {
        launch(["--history-revoke-on-recheck"])
        select("plex")
        confirm()
        assertFailure(containing: "tracker connection changed")
    }

    func testServerChangesAfterComparisonRejectAllWrites() {
        launch(["--history-server-change-on-recheck"])
        select("jellyfin")
        confirm()
        XCTAssertTrue(app.staticTexts["Not confirmed. Compare again before retrying."].waitForExistence(timeout: 5))
        assertReport(jellyfin: 0, plex: 0)
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.contains(
            "jellyfin=0,played=false,playback=0,resume=50"
        ))
    }

    func testLostWriteReplyUsesReadbackWithoutAnotherWriteOnReentry() {
        launch(["--history-lost-write-reply"])
        select("plex")
        confirm()
        XCTAssertTrue(app.staticTexts["Confirmed on server"].waitForExistence(timeout: 5), app.debugDescription)
        assertReport(jellyfin: 0, plex: 1)
        activate(app.buttons["fixture.history.close"])
        activate(app.buttons["fixture.history.open"])
        XCTAssertTrue(app.staticTexts["Already matches — no change"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("tracker-history.select.plex:movie").exists)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
        assertReport(jellyfin: 0, plex: 1)
    }

    private func verifySelectedServer(_ server: String) {
        launch()
        select(server)
        confirm()
        XCTAssertTrue(app.staticTexts["Confirmed on server"].waitForExistence(timeout: 5), app.debugDescription)
        assertReport(jellyfin: server == "jellyfin" ? 1 : 0, plex: server == "plex" ? 1 : 0)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "confirmed-\(server)-only"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launchExport(_ server: String, arguments: [String] = []) {
        app.launchArguments = [
            "--tracker-history-import-fixture", "--history-export", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        app.launch()
        openExport(server)
        XCTAssertFalse(app.buttons["tracker-export.apply"].isEnabled)
        assertExportReport(writes: 0)
    }

    private func openExport(_ server: String) {
        activate(app.buttons["fixture.history.open"])
        chooseExportValue("\(server) fixture · \(server) viewer", picker: "tracker-export.account")
        chooseExportValue("Movies", picker: "tracker-export.library")
        activate(app.buttons["tracker-export.preview"])
        XCTAssertTrue(app.buttons["tracker-export.apply"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func chooseExportValue(_ label: String, picker identifier: String) {
        let picker = element(identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 30), app.debugDescription)
        #if os(tvOS)
        let option = picker.buttons[label].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        activate(picker.buttons.element(boundBy: 0))
        for _ in 0..<picker.buttons.count {
            if option.wait(for: \.hasFocus, toEqual: true, timeout: 1) { break }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(option.hasFocus, app.debugDescription)
        XCTAssertTrue(option.isSelected, app.debugDescription)
        #else
        activate(picker)
        activate(app.buttons[label].firstMatch)
        #endif
    }

    private func confirmExport() {
        activate(element("tracker-export.select.movie"))
        activate(app.buttons["tracker-export.apply"])
        activate(app.buttons["Export selected titles"].firstMatch)
    }

    private func verifyExport(_ server: String) {
        launchExport(server)
        activate(element("tracker-export.select.movie"))
        activate(app.buttons["tracker-export.apply"])
        XCTAssertTrue(app.buttons["Export selected titles"].firstMatch.waitForExistence(timeout: 5))
        cancelConfirmation()
        assertExportReport(writes: 0)
        activate(app.buttons["tracker-export.apply"])
        activate(app.buttons["Export selected titles"].firstMatch)
        XCTAssertTrue(app.staticTexts["Confirmed on Fixture"].waitForExistence(timeout: 5), app.debugDescription)
        assertExportReport(writes: 1)
        XCTAssertFalse(app.buttons["tracker-export.apply"].isEnabled)
    }

    private func assertExportReport(writes: Int) {
        let report = app.staticTexts["fixture.history.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(report.label.contains(";trackers=\(writes);"), report.label)
        for kind in ["jellyfin", "plex"] {
            XCTAssertTrue(report.label.contains("\(kind)=0,played=true,playback=0"), report.label)
        }
    }

    func testWatchedOnlyManualSyncUsesSupportedControlsAndExplicitAction() {
        verifyOngoingSync("jellyfin", additionalArguments: ["--history-watched-only", "--history-manual-sync"])
    }

    private func verifyOngoingSync(_ server: String, additionalArguments: [String] = []) {
        launch(["--history-ongoing-sync"] + additionalArguments)
        activate(element("tracker-history.ongoing-sync"))
        let enable = app.buttons["tracker-history.enable-sync"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(enable.isEnabled)
        if additionalArguments.contains("--history-watched-only") {
            XCTAssertFalse(element("tracker-history.sync-resume").exists)
        }
        activate(element("tracker-history.sync-server.\(server)"))
        activate(element("tracker-history.sync-watched"))
        activate(enable)
        XCTAssertTrue(syncConfirmationButton.waitForExistence(timeout: 5))
        cancelConfirmation()
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.contains(";sync=false;"))
        assertReport(jellyfin: 0, plex: 0)
        activate(enable)
        activate(syncConfirmationButton)
        XCTAssertTrue(app.buttons["tracker-history.sync-now"].waitForExistence(timeout: 5), app.debugDescription)
        if additionalArguments.contains("--history-manual-sync") {
            XCTAssertTrue(app.staticTexts["Use Sync now to import new history. Conflicts stay unchanged."].exists)
        }
        XCTAssertFalse(element("tracker-history.sync-server.\(server)").exists,
                       "Enrollment must replace the editable destination toggle with a read-only summary")
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.contains(";destinations=\(server);"))
        assertReport(jellyfin: 0, plex: 0)
        activate(app.buttons["fixture.history.new-play"])
        activate(app.buttons["tracker-history.sync-now"])
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.app.staticTexts["fixture.history.report"].label.contains("\(server)=1,played=true")
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed, app.debugDescription)
        assertReport(jellyfin: server == "jellyfin" ? 1 : 0, plex: server == "plex" ? 1 : 0)
        activate(app.buttons["tracker-history.disable-sync"])
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.contains(";sync=false;"))
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = [
            "--tracker-history-import-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        app.launch()
        activate(app.buttons["fixture.history.open"])
        XCTAssertTrue(element("tracker-history.select.jellyfin:movie").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
        assertReport(jellyfin: 0, plex: 0)
    }

    private func select(_ server: String) {
        activate(element("tracker-history.select.\(server):movie"))
        XCTAssertTrue(app.buttons["tracker-history.apply"].isEnabled, app.debugDescription)
        assertReport(jellyfin: 0, plex: 0)
        XCTAssertTrue(app.staticTexts["fixture.history.report"].label.hasSuffix(";reads=1"))
    }

    private func openConfirmation() {
        activate(app.buttons["tracker-history.apply"])
        XCTAssertTrue(app.buttons["Apply selected changes"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func confirm() {
        openConfirmation()
        activate(app.buttons["Apply selected changes"].firstMatch)
    }

    private func cancelConfirmation() {
        #if os(iOS)
        if app.popovers.firstMatch.exists {
            // Native iPad confirmation popovers omit Cancel and dismiss on an outside tap.
            let outside = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95))
            XCTAssertFalse(app.popovers.firstMatch.frame.contains(outside.screenPoint))
            outside.tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !self.app.popovers.firstMatch.exists }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            return
        }
        #endif
        activate(app.buttons["Cancel"].firstMatch)
    }

    private func assertFailure(containing message: String) {
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5), app.debugDescription)
        assertReport(jellyfin: 0, plex: 0)
    }

    private func assertReport(jellyfin: Int, plex: Int) {
        let report = app.staticTexts["fixture.history.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), app.debugDescription)
        for (kind, count) in [("jellyfin", jellyfin), ("plex", plex)] {
            XCTAssertTrue(report.label.contains("\(kind)=\(count),played=\(count > 0),playback=0"), report.label)
        }
        XCTAssertTrue(report.label.contains(";trackers=0;"), report.label)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var syncConfirmationButton: XCUIElement {
        #if os(tvOS)
        app.sheets.buttons["Enable sync"].firstMatch
        #else
        app.buttons["tracker-history.confirm-sync"].firstMatch
        #endif
    }

    private func activate(_ target: XCUIElement) {
        #if os(tvOS)
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        if app.sheets.firstMatch.exists {
            for _ in 0..<2 where !target.hasFocus { XCUIRemote.shared.press(.left) }
            for _ in 0..<2 where !target.hasFocus { XCUIRemote.shared.press(.right) }
        }
        for _ in 0..<10 where !target.hasFocus { XCUIRemote.shared.press(.down) }
        if !target.hasFocus {
            for _ in 0..<12 where !target.hasFocus { XCUIRemote.shared.press(.up) }
        }
        XCTAssertTrue(target.hasFocus, "Unreachable \(target.identifier): \(app.debugDescription)")
        XCUIRemote.shared.press(.select)
        #else
        if !target.waitForExistence(timeout: 5) || !target.isHittable {
            let list = app.collectionViews.firstMatch
            for _ in 0..<5 {
                if target.exists && target.isHittable { break }
                guard list.exists else { break }
                list.swipeUp()
            }
        }
        XCTAssertTrue(target.exists && target.isHittable, app.debugDescription)
        if target.elementType == .switch, target.switches.firstMatch.exists {
            target.switches.firstMatch.tap()
        } else {
            target.tap()
        }
        #endif
    }
}
