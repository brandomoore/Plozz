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
        XCTAssertFalse(app.buttons["tracker-history.apply"].exists)
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

    func testWetrakrExportProductionAdapterAndServerIsolation() {
        for server in ["Jellyfin", "Plex"] {
            verifyExport(server, arguments: ["--history-wetrakr-export"], trackerName: "WeTrakr")
            app.terminate()
        }
    }

    func testSimklExportProductionAdapterAndServerIsolation() {
        for server in ["Jellyfin", "Plex"] {
            verifyExport(server, arguments: ["--history-simkl-export"], trackerName: "Simkl")
            app.terminate()
        }
    }

    func testTraktExportProductionAdapterAndServerIsolation() {
        for server in ["Jellyfin", "Plex"] {
            verifyExport(server, arguments: ["--history-trakt-export"], trackerName: "Trakt")
            app.terminate()
        }
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
        XCTAssertTrue(element("tracker-export.account").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tracker-export.preview"].exists)
        XCTAssertFalse(element("tracker-export.select.movie").exists)
        assertExportReport(writes: 0)
    }

    func testServerOnlyComparisonHasNoOngoingSyncOption() {
        launch(["--history-ongoing-sync", "--history-servers-only"])
        XCTAssertFalse(element("tracker-history.ongoing-sync").exists)
        select("plex")
    }

    func testDirectSyncReadsNothingUntilShareEnrollment() {
        app.launchArguments = ["--tracker-history-import-fixture", "--history-ongoing-sync", "--history-direct-sync"]
        app.launch()
        activate(app.buttons["fixture.history.open"])
        activate(element("tracker-history.ongoing-sync"))
        let master = element("tracker-history.sync-enabled")
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        waitForReport(";reads=0")
        activate(master)
        XCTAssertTrue(app.buttons["Enable beta sync"].firstMatch.waitForExistence(timeout: 5))
        cancelConfirmation()
        waitForReport(";sync=false;")
        waitForReport(";reads=0")
        activate(master)
        activate(app.buttons["Enable beta sync"].firstMatch)
        waitForReport(";sync=true;destinations=cedar,mariner;categories=resume,watched;")
        assertReport(jellyfin: 0, plex: 0, cedar: 0, mariner: 0)
    }

    func testIncompleteTraktEnrollmentNamesSourceAndLeavesSharesUnchanged() {
        app.launchArguments = ["--tracker-history-import-fixture", "--history-ongoing-sync", "--history-direct-sync",
                               "--history-incomplete-trakt", "--history-watched-only"]
        app.launch()
        activate(app.buttons["fixture.history.open"])
        activate(element("tracker-history.ongoing-sync"))
        let master = element("tracker-history.sync-enabled")
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        XCTAssertEqual(master.label, "Apply new activity from Trakt")
        activate(master)
        activate(app.buttons["Enable beta sync"].firstMatch)
        XCTAssertTrue(app.staticTexts["Sync is off. Plozz couldn’t verify your full Trakt history. Try again later."]
            .waitForExistence(timeout: 5))
        XCTAssertEqual(master.value as? String, "0")
        waitForReport(";sync=false;")
        assertReport(jellyfin: 0, plex: 0, cedar: 0, mariner: 0)
    }

    func testOngoingShareDefaultsAndEditsLeaveUnselectedSourcesUnchanged() {
        verifyOngoingShareSync()
    }

    #if os(iOS)
    func testReviewedConsentNamesOnlySelectedHistoryOwners() {
        launch(["--history-ongoing-sync"])
        select("jellyfin")
        openConfirmation()
        XCTAssertTrue(app.staticTexts["Change server history?"].exists)
        let warning = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps and profiles using these server users see the changes."
        ))
        XCTAssertTrue(warning.firstMatch.exists)
        cancelConfirmation()
        assertReport(jellyfin: 0, plex: 0, cedar: 0, mariner: 0)

        activate(element("tracker-history.select.jellyfin:movie"))
        select("cedar")
        openConfirmation()
        XCTAssertTrue(app.staticTexts["Change share history in Plozz?"].exists)
        XCTAssertFalse(warning.firstMatch.exists)
        activate(app.buttons["Apply selected changes"].firstMatch)
        XCTAssertTrue(app.staticTexts["Confirmed in Plozz"].waitForExistence(timeout: 5))
        assertReport(jellyfin: 0, plex: 0, cedar: 1, mariner: 0)
    }

    func testLargeComparisonFiltersWithoutSelectingOrWritingHiddenRows() {
        launch(["--history-many-records"])
        let summary = element("tracker-history.summary")
        XCTAssertTrue(summary.label.contains("240 unavailable"))
        select("plex")
        chooseExportValue("Unavailable (240)", picker: "tracker-history.filter")
        XCTAssertFalse(element("tracker-history.select.plex:movie").exists)
        XCTAssertFalse(element("tracker-history.select.jellyfin:movie").exists)
        chooseExportValue("Selected (1)", picker: "tracker-history.filter")
        XCTAssertTrue(element("tracker-history.select.plex:movie").exists)
        XCTAssertFalse(element("tracker-history.select.jellyfin:movie").exists)
        confirm()
        XCTAssertTrue(app.staticTexts["Confirmed on server"].waitForExistence(timeout: 5))
        assertReport(jellyfin: 0, plex: 1)
    }

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
        XCTAssertFalse(app.buttons["tracker-export.apply"].exists)
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
        XCTAssertFalse(app.buttons["tracker-history.apply"].exists)
        assertReport(jellyfin: 0, plex: 1)
    }

    private func verifySelectedServer(_ server: String) {
        launch()
        select(server)
        confirm()
        XCTAssertTrue(app.staticTexts["Confirmed on server"].waitForExistence(timeout: 5), app.debugDescription)
        assertReport(jellyfin: server == "jellyfin" ? 1 : 0, plex: server == "plex" ? 1 : 0)
        XCTAssertFalse(app.buttons["tracker-history.apply"].exists)
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
        XCTAssertFalse(app.buttons["tracker-export.apply"].exists)
        assertExportReport(writes: 0)
    }

    private func openExport(_ server: String) {
        activate(app.buttons["fixture.history.open"])
        chooseExportValue(server == "Plex" ? "Northbank Cinema · Theo" : "Lantern House · Mara", picker: "tracker-export.account")
        chooseExportValue("Movies", picker: "tracker-export.library")
        activate(app.buttons["tracker-export.preview"])
        XCTAssertTrue(element("tracker-export.summary").waitForExistence(timeout: 5), app.debugDescription)
    }

    private func chooseExportValue(_ label: String, picker identifier: String) {
        let picker = element(identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 30), app.debugDescription)
        activate(picker)
        activate(app.buttons[label].firstMatch)
    }

    private func confirmExport() {
        activate(element("tracker-export.select.movie"))
        activate(app.buttons["tracker-export.apply"])
        activate(app.buttons["Export selected titles"].firstMatch)
    }

    private func verifyExport(_ server: String, arguments: [String] = [], trackerName: String = "Fixture") {
        launchExport(server, arguments: arguments)
        activate(element("tracker-export.select.movie"))
        activate(app.buttons["tracker-export.apply"])
        XCTAssertTrue(app.buttons["Export selected titles"].firstMatch.waitForExistence(timeout: 5))
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Titles to export: 1.")).firstMatch
        XCTAssertTrue(message.exists)
        XCTAssertTrue(message.label.contains("Copy history from Movies to \(trackerName)?"))
        XCTAssertTrue(message.label.contains("Servers and sync settings stay unchanged."))
        cancelConfirmation()
        assertExportReport(writes: 0)
        activate(app.buttons["tracker-export.apply"])
        activate(app.buttons["Export selected titles"].firstMatch)
        XCTAssertTrue(app.staticTexts["Confirmed on \(trackerName)"].waitForExistence(timeout: 5), app.debugDescription)
        assertExportReport(writes: 1)
        XCTAssertFalse(app.buttons["tracker-export.apply"].exists)
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
        verifyOngoingShareSync(additionalArguments: ["--history-watched-only", "--history-manual-sync"])
    }

    private func verifyOngoingShareSync(additionalArguments: [String] = []) {
        launch(["--history-ongoing-sync"] + additionalArguments)
        activate(element("tracker-history.ongoing-sync"))
        let master = element("tracker-history.sync-enabled")
        let watchedOnly = additionalArguments.contains("--history-watched-only")
        let defaults = watchedOnly ? "watched" : "resume,watched"
        let watched = element("tracker-history.sync-watched")
        let resume = element("tracker-history.sync-resume")
        let cedar = element("tracker-history.sync-server.cedar")
        let mariner = element("tracker-history.sync-server.mariner")
        let syncNow = app.buttons["tracker-history.sync-now"]
        func assertOff() {
            waitForReport(";sync=false;")
            XCTAssertTrue(master.exists && master.isEnabled)
            #if os(iOS)
            XCTAssertEqual(master.value as? String, "0")
            #endif
            for option in [watched, resume, cedar, mariner, syncNow] { XCTAssertFalse(option.exists) }
        }
        XCTAssertTrue(master.waitForExistence(timeout: 5), app.debugDescription)
        assertOff()
        activate(master)
        activate(app.buttons["Enable beta sync"].firstMatch)
        waitForReport(";sync=true;destinations=cedar,mariner;categories=\(defaults);")
        for option in [cedar, mariner, watched, syncNow] { XCTAssertTrue(option.exists && option.isEnabled) }
        XCTAssertEqual(resume.exists, !watchedOnly)
        #if os(iOS)
        for option in [master, cedar, mariner, watched] + (watchedOnly ? [] : [resume]) {
            XCTAssertEqual(option.value as? String, "1", option.identifier)
        }
        #endif
        XCTAssertTrue(cedar.label.contains("Cedar Loft"))
        XCTAssertTrue(mariner.label.contains("Mariner Archive"))
        for server in ["jellyfin", "plex"] {
            XCTAssertFalse(element("tracker-history.sync-server.\(server)").exists)
        }
        if watchedOnly {
            XCTAssertTrue(app.staticTexts["Use Sync now to import new history."].exists)
        } else {
            activate(master)
            assertOff()
            activate(master)
            activate(app.buttons["Enable beta sync"].firstMatch)
            waitForReport(";sync=true;destinations=cedar,mariner;categories=\(defaults);")
            activate(resume)
            waitForReport(";sync=true;destinations=cedar,mariner;categories=watched;")
        }
        activate(mariner)
        waitForReport(";sync=true;destinations=cedar;categories=watched;")
        #if os(iOS)
        XCTAssertEqual(mariner.value as? String, "0")
        if !watchedOnly { XCTAssertEqual(resume.value as? String, "0") }
        #endif
        assertReport(jellyfin: 0, plex: 0, cedar: 0, mariner: 0)
        activate(app.buttons["fixture.history.new-play"])
        activate(syncNow)
        waitForReport("cedar=1,played=true")
        assertReport(jellyfin: 0, plex: 0, cedar: 1, mariner: 0)
        XCTAssertTrue(syncNow.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        activate(watchedOnly ? watched : cedar)
        assertOff()
    }

    private func waitForReport(_ text: String) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text),
                                                object: app.staticTexts["fixture.history.report"])
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed, app.debugDescription)
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = [
            "--tracker-history-import-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        app.launch()
        activate(app.buttons["fixture.history.open"])
        XCTAssertTrue(element("tracker-history.select.jellyfin:movie").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tracker-history.apply"].exists)
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

    private func assertReport(jellyfin: Int, plex: Int, cedar: Int? = nil, mariner: Int? = nil) {
        let report = app.staticTexts["fixture.history.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5), app.debugDescription)
        var counts = [("jellyfin", jellyfin), ("plex", plex)]
        if let cedar { counts.append(("cedar", cedar)) }
        if let mariner { counts.append(("mariner", mariner)) }
        for (kind, count) in counts {
            XCTAssertTrue(report.label.contains("\(kind)=\(count),played=\(count > 0),playback=0"), report.label)
        }
        XCTAssertTrue(report.label.contains(";trackers=0;"), report.label)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
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
            let scroll = app.scrollViews.containing(.any, identifier: target.identifier).firstMatch
            let list = scroll.exists ? scroll : app.collectionViews.firstMatch
            for _ in 0..<8 {
                if target.exists && target.isHittable { break }
                guard list.exists else { break }
                if target.exists && !target.frame.isEmpty && target.frame.midY < list.frame.midY {
                    list.swipeDown()
                } else {
                    list.swipeUp()
                }
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
