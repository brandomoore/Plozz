import XCTest

#if os(iOS)
import UIKit

@MainActor
final class PublicMetaDBLiveHistoryTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
    private var startedPlayback = false
    private var authorizedLiveRun = false
    private var preservesProcess: Bool {
        ProcessInfo.processInfo.environment["PLOZZ_TRACKER_PRESERVE_PROCESS"] == "1"
    }

    override func setUp() async throws {
        try await MainActor.run {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            XCTAssertEqual(environment["PLOZZ_TRACKER_HISTORY_LIVE"], "1")
            let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_SIMULATOR"])
            XCTAssertEqual(simulator, environment["SIMULATOR_UDID"])
            let returnsFromBackground = environment["PLOZZ_TRACKER_HISTORY_METHOD"]
                == "testReturnToForegroundWithoutManualSync"
            if returnsFromBackground {
                XCTAssertTrue([.runningBackground, .runningBackgroundSuspended].contains(app.state))
            } else {
                XCTAssertEqual(app.state, .runningForeground)
            }
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

    func testLeaveAppInBackground() throws {
        recordState()
        XCUIDevice.shared.press(.home)
        try require(app.wait(for: .runningBackground, timeout: 10), "Expected the actual app to enter background")
    }

    func testReturnToForegroundWithoutManualSync() throws {
        try require([.runningBackground, .runningBackgroundSuspended].contains(app.state),
                    "Expected the previously backgrounded installation")
        app.activate()
        try require(app.wait(for: .runningForeground, timeout: 15), "Expected a real foreground transition")
        try require(app.buttons["Search"].firstMatch.waitForExistence(timeout: 30), "Expected normal application UI")
        recordState()
    }

    func testOpenLibrarySettings() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-libraries"])
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 15))
    }

    func testInspectServerConnections() throws {
        try openSettings()
        try tapVisible(app.buttons["Servers"])
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 15))
        recordState()
    }

    func testConnectIndependentServerWithQuickConnect() throws {
        try testInspectServerConnections()
        let environment = ProcessInfo.processInfo.environment
        let server = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_SERVER"])
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_USER"])
        let url = try XCTUnwrap(URLComponents(string: server))
        XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertFalse(app.staticTexts["Signed in as \(user)"].exists)
        try tapVisible(app.buttons["Add Server"])
        let address = app.textFields["Server address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        try tapVisible(address)
        address.typeText(server + "\n")
        let codeLabel = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Quick Connect code "
        )).firstMatch
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts[server].exists)
        let code = String(codeLabel.label.dropFirst("Quick Connect code ".count))
        XCTAssertNotNil(code.range(of: "^[0-9]{6}$", options: .regularExpression))
        let handoff = try XCTUnwrap(environment["PLOZZ_TRACKER_SERVER_HANDOFF"])
        XCTAssertTrue(handoff.hasPrefix("/") && handoff.hasSuffix("/quickconnect-request.json"))
        let data = try JSONSerialization.data(withJSONObject: [
            "code": code, "server": server, "user": user, "displayedProductionCode": true,
        ])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        XCTAssertTrue(app.navigationBars["Choose Your Libraries"].waitForExistence(timeout: 120))
        recordState()
    }

    func testPrepareIndependentPlexLink() throws {
        try testInspectServerConnections()
        try require(!app.staticTexts["Signed in as Plozz Internal"].exists, "Expected no existing dedicated Plex account")
        try tapVisible(app.buttons["Add Server"])
        try tapVisible(app.buttons["Provider, Jellyfin"])
        try tapVisible(app.buttons["Plex"].firstMatch)
        try tapVisible(app.buttons["Link Plex account"])
        try require(app.buttons["Open Plex to link"].waitForExistence(timeout: 45), "Expected normal Plex authorization")
        let codeLabels = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[A-Z0-9]{4}$"))
        try require(codeLabels.count == 1, "Expected one real manual Plex link code")
        let handoff = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_SERVER_HANDOFF"])
        try require(handoff.hasPrefix("/") && handoff.hasSuffix("/plex-link-request.json"), "Expected scoped handoff")
        let data = try JSONSerialization.data(withJSONObject: [
            "code": codeLabels.element.label, "displayedProductionCode": true,
        ])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        recordState()
    }

    func testConnectIndependentSiloWithDeviceApproval() throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_SERVER"])
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_USER"])
        let profileID = try XCTUnwrap(environment["PLOZZ_TRACKER_SERVER_PROFILE"])
        let url = try XCTUnwrap(URLComponents(string: server))
        try require(["http", "https"].contains(url.scheme ?? "") && url.host != nil,
                    "Expected the independently verified Silo endpoint")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        try testInspectServerConnections()
        XCTAssertFalse(app.staticTexts["Signed in as \(user)"].exists)
        try tapVisible(app.buttons["Add Server"])
        try tapVisible(app.buttons["Provider, Jellyfin"])
        try tapVisible(app.buttons["Silo"].firstMatch)
        let address = app.textFields["Server address"]
        try tapVisible(address)
        address.typeText(server + "\n")
        try require(app.buttons["Open Silo to approve"].waitForExistence(timeout: 45),
                    "Expected native Silo device approval")
        try tapVisible(app.buttons["Use another device"])
        let code = app.staticTexts["connection-code"]
        try tapVisible(code, tapping: false)
        try require(code.label.hasPrefix("Sign-in code: "), "Expected the displayed Silo code")
        let value = String(code.label.dropFirst("Sign-in code: ".count))
            .filter { !$0.isWhitespace && $0 != "-" }
        try require(value.range(of: "^(?:[A-Z0-9]{6}|[A-Z0-9]{8})$", options: .regularExpression) != nil,
                    "Expected a supported public Silo user code")
        let handoff = try XCTUnwrap(environment["PLOZZ_TRACKER_SERVER_HANDOFF"])
        try require(handoff.hasPrefix("/") && handoff.hasSuffix("/silo-link-request.json"),
                    "Expected a scoped Silo approval handoff")
        let data = try JSONSerialization.data(withJSONObject: [
            "code": value, "server": server, "profileID": profileID,
            "displayedProductionCode": true,
        ])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        let profile = app.buttons["silo-profile-\(profileID)"]
        try require(profile.waitForExistence(timeout: 120), "Expected profiles after normal device approval")
        XCTAssertEqual(profile.label, user)
        XCTAssertEqual(profile.value as? String, "")
        try tapVisible(profile)
        try finishIndependentServerLibraries()
    }

    func testCancelIndependentPlexLink() throws {
        try require(app.buttons["Open Plex to link"].exists, "Expected the unlinked native Plex page")
        try tapVisible(app.navigationBars["Plex"].buttons["BackButton"])
        try tapVisible(app.navigationBars["Add Server"].buttons["Cancel"])
        try require(app.buttons["Open Plex to link"].waitForNonExistence(timeout: 10), "Expected cancelled linking")
        try testInspectServerConnections()
        try require(!app.staticTexts["Signed in as Plozz Internal"].exists, "Refused linking must not add an account")
        XCTAssertTrue(app.staticTexts["Signed in as plozztest"].exists)
        XCTAssertTrue(app.staticTexts["Signed in as plozz-internal"].exists)
        recordState()
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

    func testSelectOnlyPlexSource() throws {
        try selectSourceServers(onlyPlex: true)
    }

    func testRestoreAllSourceServers() throws {
        try selectSourceServers(onlyPlex: false)
    }

    func testSelectOnlySiloSource() throws {
        try selectSiloSourceServers(onlySilo: true)
    }

    func testRestoreSiloSourceServers() throws {
        try selectSiloSourceServers(onlySilo: false)
    }

    private func selectSiloSourceServers(onlySilo: Bool) throws {
        try testOpenLibrarySettings()
        try require(app.switches["Silo"].value as? String == "1",
                    "Keep the already-authorized dedicated Silo profile active")
        try require(!app.switches["Brandoland"].exists && !app.switches["Brandon's Jellyfin"].exists,
                    "Expected the dedicated Silo and Emby source configuration")
        try setSourceServer("CubeBoi", selected: !onlySilo)
        try testOpenLibrarySettings()
        XCTAssertEqual(app.switches["Silo"].value as? String, "1")
        XCTAssertEqual(app.switches["CubeBoi"].value as? String, onlySilo ? "0" : "1")
    }

    private func selectSourceServers(onlyPlex: Bool) throws {
        try testOpenLibrarySettings()
        try require(app.switches["Brandoland"].value as? String == "1",
                    "Keep the already-authorized dedicated Plex identity active")
        try require(app.buttons["Plozz Internal"].exists, "Expected the dedicated Plex user")
        for label in ["CubeBoi", "Brandon's Jellyfin"] {
            try setSourceServer(label, selected: !onlyPlex)
        }
        try testOpenLibrarySettings()
        for label in ["CubeBoi", "Brandon's Jellyfin", "Brandoland"] {
            XCTAssertEqual(app.switches[label].value as? String, label == "Brandoland" || !onlyPlex ? "1" : "0")
        }
        XCTAssertTrue(app.buttons["Plozz Internal"].exists)
    }

    private func setSourceServer(_ label: String, selected: Bool) throws {
        let control = app.switches[label]
        try tapVisible(control, tapping: false)
        let value = try XCTUnwrap(control.value as? String)
        try require(["0", "1"].contains(value), "Expected a native source-selection switch")
        let expected = selected ? "1" : "0"
        if value != expected {
            try tapVisible(control.switches.firstMatch)
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected), object: control
            )
            try require(XCTWaiter.wait(for: [changed], timeout: 15) == .completed,
                        "Expected the selected source scope")
        }
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
            let includeShows = ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_INCLUDE_SHOWS"] == "1"
            if (shows.value as? String == "1") != includeShows { shows.tap() }
            XCTAssertEqual(shows.value as? String, includeShows ? "1" : "0")
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

    func testPlaybackReportingIsDisabled() throws {
        try openPlaybackReporting()
        XCTAssertTrue(app.buttons["publicmetadb.playback.enable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["publicmetadb.playback.disable"].exists)
        recordState()
    }

    func testConnectWithRealBrowserCode() throws {
        let enter = app.buttons["publicmetadb.pair"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        XCTAssertEqual(enter.label, "Enter API key")
        XCTAssertFalse(app.buttons["publicmetadb.browse"].exists)
        enter.tap()
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 50))
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        XCTAssertNotNil(code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression))
        let handoff = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_CONNECTION_HANDOFF"])
        XCTAssertTrue(handoff.hasPrefix("/") && handoff.hasSuffix("/browser-request.json"))
        let data = try JSONSerialization.data(withJSONObject: [
            "url": "https://plozz.app/publicmetadb",
            "code": code,
            "displayedProductionCode": true,
        ])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 120))
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        XCTAssertFalse(app.secureTextFields["publicmetadb.key"].exists)
    }

    func testPrepareConnectionReplacement() throws {
        try prepareConnectionReplacement()
        recordState()
    }

    func testCancelConnectionReplacement() throws {
        XCTAssertTrue(app.popovers.buttons["Replace API key"].exists)
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        try assertSavedConnection()
        recordState()
    }

    func testCancelReplacementEntry() async throws {
        let code = try beginReplacementEntry()
        try tapVisible(app.buttons["publicmetadb.pair.cancel"])
        try await PublicMetaDBLiveConnectionTests.verifyRelayRevoked(code)
        try assertSavedConnection()
        recordState()
    }

    func testRejectInvalidReplacement() async throws {
        let code = try beginReplacementEntry()
        let field = app.secureTextFields["publicmetadb.key"]
        try tapVisible(field)
        field.typeText("pm-" + String(repeating: "a", count: 60) + "\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try tapVisible(app.buttons["publicmetadb.connect"])
        XCTAssertTrue(app.staticTexts["Your session has expired. Please sign in again."]
            .waitForExistence(timeout: 50))
        XCTAssertFalse(app.buttons["publicmetadb.browse"].exists)
        XCTAssertTrue(field.exists)
        try await PublicMetaDBLiveConnectionTests.verifyRelayRevoked(code)
        try tapVisible(app.buttons["publicmetadb.pair.cancel"])
        try assertSavedConnection()
        recordState()
    }

    func testDisconnectAndVerifyRelaunch() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-trackers"])
        try assertSavedConnection()
        try tapVisible(app.buttons["Disconnect"])
        let confirmation = app.popovers.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        try assertSavedConnection()
        try tapVisible(app.buttons["Disconnect"])
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        try assertDisconnectedConnection()
        try openSettings()
        try tapVisible(app.buttons["settings-category-trackers"])
        try assertDisconnectedConnection()
        recordState()
    }

    func testSavedConnectionAndListAfterRelaunch() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-trackers"])
        try assertSavedConnection()
        try tapVisible(app.buttons["publicmetadb.browse"])
        let preference = app.switches["publicmetadb.ratings"]
        try tapVisible(preference, tapping: false)
        XCTAssertEqual(preference.value as? String, "0")
        try tapVisible(app.buttons["Lists"])
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_NAME"])
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Page 1 of 1"].exists)
        XCTAssertFalse(app.staticTexts["No records"].exists)
        recordState()
    }

    func testInspectManualKeyPasteMenu() throws {
        _ = try beginReplacementEntry()
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.string = "Plozz paste inspection"
        let field = app.secureTextFields["publicmetadb.key"]
        try tapVisible(field)
        field.doubleTap()
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 5)
            || app.menuItems["Paste"].waitForExistence(timeout: 5))
        recordState()
    }

    func testManualKeyPasteConnection() async throws {
        let code = try beginReplacementEntry()
        let field = app.secureTextFields["publicmetadb.key"]
        try tapVisible(field)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let connect = app.buttons["publicmetadb.connect"]
        XCTAssertFalse(connect.isEnabled)
        let input = try await PublicMetaDBLiveConnectionTests.readManualInput()
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": input]],
            options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: 30)]
        )
        field.doubleTap()
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: connect)
        await fulfillment(of: [enabled], timeout: 5)
        UIPasteboard.general.items = previous
        XCTAssertTrue((UIPasteboard.general.items as NSArray).isEqual(to: previous))
        app.keyboards.buttons["Return"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try tapVisible(connect)
        try assertSavedConnection()
        try await PublicMetaDBLiveConnectionTests.verifyRelayRevoked(code)
        recordState()
    }

    private func assertSavedConnection() throws {
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 45))
        XCTAssertEqual(app.buttons["publicmetadb.pair"].label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        XCTAssertFalse(app.secureTextFields["publicmetadb.key"].exists)
    }

    private func assertDisconnectedConnection() throws {
        let enter = app.buttons["publicmetadb.pair"]
        try tapVisible(enter, tapping: false)
        XCTAssertEqual(enter.label, "Enter API key")
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
        XCTAssertFalse(app.buttons["publicmetadb.browse"].exists)
        XCTAssertFalse(app.secureTextFields["publicmetadb.key"].exists)
    }

    private func beginReplacementEntry() throws -> String {
        try prepareConnectionReplacement()
        let confirm = app.popovers.buttons["Replace API key"].firstMatch
        XCTAssertTrue(confirm.exists)
        confirm.tap()
        XCTAssertTrue(app.secureTextFields["publicmetadb.key"].waitForExistence(timeout: 5))
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 50))
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        XCTAssertNotNil(code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression))
        return code
    }

    private func prepareConnectionReplacement() throws {
        try openSettings()
        try tapVisible(app.buttons["settings-category-trackers"])
        let enter = app.buttons["publicmetadb.pair"]
        try tapVisible(enter, tapping: false)
        XCTAssertEqual(enter.label, "Replace API key")
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 45))
        enter.tap()
        XCTAssertTrue(app.popovers.buttons["Replace API key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["publicmetadb.key"].exists)
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
        try createAcceptanceList(isPublic: false)
    }

    func testCreatePublicAcceptanceList() throws {
        try createAcceptanceList(isPublic: true)
    }

    func testCreatePrivateWatchlistAcceptanceList() throws {
        try createAcceptanceList(isPublic: false, watchlist: true)
    }

    private func createAcceptanceList(isPublic: Bool, watchlist: Bool = false) throws {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_NAME"])
        try require(!name.isEmpty, "Expected the explicit test-list name")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Create a list"])
        let field = app.textFields["publicmetadb.list.name"]
        try tapVisible(field)
        field.typeText(name)
        XCTAssertEqual(app.switches["Public list"].value as? String, "0")
        if isPublic {
            try tapVisible(app.switches["Public list"].switches.firstMatch)
            XCTAssertEqual(app.switches["Public list"].value as? String, "1")
        }
        if watchlist {
            let kind = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "List type")).firstMatch
            try tapVisible(kind)
            try tapVisible(app.buttons["Watchlist"])
            XCTAssertTrue(kind.label.contains("Watchlist") || kind.value as? String == "Watchlist")
        }
        app.swipeUp()
        let confirm = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Create list", "publicmetadb.list.create"
        )).firstMatch
        try tapVisible(app.buttons["publicmetadb.list.create"])
        try require(confirm.waitForExistence(timeout: 5), "Expected list confirmation")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", isPublic ? "will be public" : "will be private"
        )).firstMatch.exists)
        try dismissConfirmation()
        try require(confirm.waitForNonExistence(timeout: 5), "Expected cancellation to dismiss confirmation")
        XCTAssertTrue(app.textFields["publicmetadb.list.name"].exists)
        try tapVisible(app.buttons["publicmetadb.list.create"])
        try require(confirm.waitForExistence(timeout: 5), "Expected the new list confirmation")
        try require(confirm.isHittable, "Expected the confirmation action, not the underlying form")
        confirm.tap()
        try require(app.staticTexts["List created on PublicMetaDB"].waitForExistence(timeout: 45),
                    "Expected independently confirmed list creation")
    }

    func testBrowseExactAcceptanceList() throws {
        try openAcceptanceList()
        XCTAssertTrue(app.staticTexts["Private"].exists)
        try tapVisible(app.buttons["Browse items"])
        try require(app.staticTexts["No records"].waitForExistence(timeout: 30), "Expected an empty new list")
    }

    func testBrowseEmptyPublicAcceptanceList() throws {
        try openAcceptanceList()
        XCTAssertTrue(app.staticTexts["Public"].exists)
        try tapVisible(app.buttons["Browse items"])
        try require(app.staticTexts["No records"].waitForExistence(timeout: 30), "Expected an empty public list")
    }

    func testPrepareAcceptanceListAddition() throws {
        try testBrowseUnknownHistoryPlay()
        try tapVisible(app.buttons["Title controls"])
        try tapVisible(app.buttons["Add to a list"])
        let choice = try acceptanceListChoice()
        try tapVisible(choice)
        try require(app.buttons["Add to list"].waitForExistence(timeout: 5), "Expected list-add confirmation")
        let disclosure = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "This list is public. Other people can see its contents."
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.contains("Changes to a watchlist destination can propagate"))
    }

    func testCancelAcceptanceListAddition() throws {
        try require(app.buttons["Add to list"].exists, "Expected the prepared list addition")
        try dismissConfirmation()
        XCTAssertTrue(app.buttons["Add to list"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(try acceptanceListChoice().isEnabled)
    }

    func testConfirmAcceptanceListAddition() throws {
        try require(app.buttons["Add to list"].exists, "Expected the prepared list addition")
        try tapVisible(app.buttons["Add to list"])
        try require(app.alerts["PublicMetaDB"].staticTexts["Added to list"].waitForExistence(timeout: 30),
                    "Expected confirmed list membership")
        try tapVisible(app.alerts["PublicMetaDB"].buttons["OK"])
    }

    func testPrepareAcceptanceListRemoval() throws {
        try openAcceptanceList()
        XCTAssertTrue(app.staticTexts["Public"].exists)
        try tapVisible(app.buttons["Browse items"])
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        let item = app.buttons.containing(.staticText, identifier: title)
        try require(item.firstMatch.waitForExistence(timeout: 30) && item.count == 1,
                    "Expected exactly the independently verified list item")
        try tapVisible(item.element)
        try tapVisible(app.buttons["Remove from list"])
        try require(app.popovers.buttons["Remove from list"].waitForExistence(timeout: 5),
                    "Expected the exact-entry removal confirmation")
    }

    func testCancelAcceptanceListRemoval() throws {
        try require(app.popovers.buttons["Remove from list"].exists, "Expected the prepared list removal")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove from list"].exists)
    }

    func testConfirmAcceptanceListRemoval() throws {
        try tapVisible(app.popovers.buttons["Remove from list"])
        try require(app.staticTexts["Item removed from this list"].waitForExistence(timeout: 30),
                    "Expected confirmed exact-entry removal")
    }

    func testOpenPublicAcceptanceListURL() throws {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_URL"])
        let url = try XCTUnwrap(URLComponents(string: value))
        try require(url.scheme == "https" && url.host == "publicmetadb.com"
                    && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil,
                    "Expected the verified public list URL")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Open a public list"])
        let field = app.textFields["PublicMetaDB list URL"]
        try tapVisible(field)
        field.typeText(value)
        try tapVisible(app.buttons["Open list"])
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try require(app.staticTexts[title].waitForExistence(timeout: 30), "Expected the real public-list item")
    }

    private func acceptanceListChoice() throws -> XCUIElement {
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_NAME"])
        let choices = app.buttons.containing(.staticText, identifier: name)
        try require(choices.firstMatch.waitForExistence(timeout: 10) && choices.count == 1,
                    "Expected exactly the named test-owned list")
        return choices.element
    }

    func testBrowseUnknownHistoryPlay() throws {
        try openHistoryPlay(expectedUnknownDate: true)
    }

    private func openHistoryPlay(expectedUnknownDate: Bool) throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RECORD_ID"])
        try require(!id.isEmpty, "Expected the independently read exact play ID")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.history"])
        let record = app.buttons["publicmetadb.history.record.\(id)"]
        try tapVisible(record, tapping: false)
        XCTAssertEqual(record.label.contains("Watch date unknown"), expectedUnknownDate)
        record.tap()
        try require(app.buttons["publicmetadb.history.action"].waitForExistence(timeout: 30),
                    "Expected the exact watch record, not a title-level history action")
        XCTAssertEqual(app.buttons["publicmetadb.history.action"].label, "Delete this play")
        XCTAssertEqual(app.staticTexts["Watch date unknown"].exists, expectedUnknownDate)
        XCTAssertTrue(app.buttons["Change watch date"].exists)
    }

    func testPrepareNewUnknownHistoryPlay() throws {
        try prepareHistoryPlay(adding: true, existingUnknown: true, newUnknown: true)
    }

    func testPrepareNewDatedHistoryPlay() throws {
        try prepareHistoryPlay(adding: true, existingUnknown: true, newUnknown: false)
    }

    func testPrepareUnknownToDatedHistoryChange() throws {
        try prepareHistoryPlay(adding: false, existingUnknown: true, newUnknown: false)
    }

    func testPrepareDatedToUnknownHistoryChange() throws {
        try prepareHistoryPlay(adding: false, existingUnknown: false, newUnknown: true)
    }

    func testPrepareUnknownHistoryDateNoop() throws {
        try prepareHistoryPlay(adding: false, existingUnknown: true, newUnknown: true)
    }

    func testPrepareDatedHistoryDateNoop() throws {
        try prepareHistoryPlay(adding: false, existingUnknown: false, newUnknown: false)
    }

    private func prepareHistoryPlay(adding: Bool, existingUnknown: Bool, newUnknown: Bool) throws {
        try openHistoryPlay(expectedUnknownDate: existingUnknown)
        try tapVisible(app.buttons[adding ? "Add another play" : "Change watch date"])
        let unknown = app.switches["Watch date unknown"]
        try tapVisible(unknown, tapping: false)
        XCTAssertEqual(unknown.value as? String, !adding && existingUnknown ? "1" : "0")
        if (unknown.value as? String == "1") != newUnknown {
            try tapVisible(unknown.switches.firstMatch)
        }
        XCTAssertEqual(unknown.value as? String, newUnknown ? "1" : "0")
        try tapVisible(app.buttons["publicmetadb.history.review-date"])
        try require(app.popovers.buttons["Save play"].waitForExistence(timeout: 5), "Expected the reviewed play")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the complete history disclosure")
        XCTAssertEqual(message.label.contains("Watch date unknown"), newUnknown)
        XCTAssertEqual(message.label.contains("This creates another play; it does not replace earlier plays."), adding)
    }

    func testConfirmPreparedHistoryPlay() throws {
        try tapVisible(app.popovers.buttons["Save play"])
        try require(app.staticTexts["Change confirmed on PublicMetaDB"].waitForExistence(timeout: 40),
                    "Expected the exact play change to be confirmed")
        XCTAssertFalse(app.buttons["publicmetadb.history.review-date"].exists)
    }

    func testPrepareExactPlayDeletion() throws {
        let unknown = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_EXPECT_UNKNOWN"])
        try require(["0", "1"].contains(unknown), "Expected independently observed date presence")
        try openHistoryPlay(expectedUnknownDate: unknown == "1")
        try tapVisible(app.buttons["publicmetadb.history.action"])
        try require(app.popovers.buttons["Delete this play"].waitForExistence(timeout: 5),
                    "Expected exact-play deletion, not a title-wide action")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the complete deletion disclosure")
        XCTAssertTrue(message.label.contains("Deletes only this play"))
    }

    func testCancelExactPlayDeletion() throws {
        try require(app.popovers.buttons["Delete this play"].exists, "Expected a prepared exact-play deletion")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.history.action"].isEnabled)
    }

    func testConfirmExactPlayDeletion() throws {
        try tapVisible(app.popovers.buttons["Delete this play"])
        try require(app.staticTexts["Change confirmed on PublicMetaDB"].waitForExistence(timeout: 40),
                    "Expected independently confirmed exact-play deletion")
        XCTAssertFalse(app.buttons["publicmetadb.history.action"].exists)
    }

    func testPrepareSelectedPlayDeletion() throws {
        let ids = try selectedHistoryIDs()
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.history.bulk"])
        try selectHistoryPlays(ids)
    }

    private func selectHistoryPlays(_ ids: [String]) throws {
        for (index, id) in ids.enumerated() {
            let control = app.switches["publicmetadb.history.select.\(id)"]
            try tapVisible(control, tapping: false)
            XCTAssertEqual(control.value as? String, "0")
            try tapVisible(control.switches.firstMatch)
            XCTAssertEqual(control.value as? String, "1")
            XCTAssertFalse(app.popovers.firstMatch.exists)
            for later in ids.dropFirst(index + 1) {
                let other = app.switches["publicmetadb.history.select.\(later)"]
                try tapVisible(other, tapping: false)
                XCTAssertEqual(other.value as? String, "0", "A sibling selection changed")
            }
        }
        try tapVisible(app.buttons["publicmetadb.history.bulk.review"])
        try require(app.popovers.buttons["Delete \(ids.count) plays"].waitForExistence(timeout: 5),
                    "Expected precisely the selected play count")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the complete bulk disclosure")
        XCTAssertTrue(message.label.contains("Only these \(ids.count) selected records will be removed."))
    }

    func testCancelSelectedPlayDeletion() throws {
        let ids = try selectedHistoryIDs()
        try require(app.popovers.buttons["Delete \(ids.count) plays"].exists, "Expected selected-play confirmation")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        let first = app.switches["publicmetadb.history.select.\(ids[0])"]
        for _ in 0..<8 {
            if first.exists && first.isHittable { break }
            app.swipeDown()
        }
        try require(first.exists && first.isHittable, "Expected the retained selections above the review action")
        for id in ids {
            let control = app.switches["publicmetadb.history.select.\(id)"]
            try tapVisible(control, tapping: false)
            XCTAssertEqual(control.value as? String, "1")
        }
    }

    func testConfirmSelectedPlayDeletion() throws {
        let ids = try selectedHistoryIDs()
        try tapVisible(app.popovers.buttons["Delete \(ids.count) plays"])
        try inspectConfirmedHistoryDeletion()
    }

    func testInspectConfirmedSelectedPlayDeletion() throws {
        try inspectConfirmedHistoryDeletion()
    }

    private func inspectConfirmedHistoryDeletion() throws {
        let confirmed = app.staticTexts["Selected plays confirmed removed on PublicMetaDB"]
        for _ in 0..<8 {
            if confirmed.exists && confirmed.isHittable { break }
            app.swipeDown()
        }
        try require(confirmed.waitForExistence(timeout: 45),
                    "Expected all selected plays to be confirmed removed")
        try tapVisible(app.buttons["publicmetadb.history.bulk.review"], tapping: false)
        XCTAssertFalse(app.buttons["publicmetadb.history.bulk.review"].isEnabled)
    }

    func testConfirmSelectedPlayDeletionWithConcurrentEdit() throws {
        let ids = try selectedHistoryIDs()
        try require(ids.count == 4, "Expected four separately verified disposable plays")
        try tapVisible(app.popovers.buttons["Delete 4 plays"])
        try inspectStoppedHistoryDeletion()
    }

    func testInspectStoppedSelectedPlayDeletion() throws {
        try inspectStoppedHistoryDeletion()
    }

    private func inspectStoppedHistoryDeletion() throws {
        let stopped = app.staticTexts[
            "2 selected plays were confirmed removed. Processing stopped at the next play; 1 later plays were not attempted."
        ]
        try require(stopped.waitForExistence(timeout: 45), "Expected deletion to stop at the concurrently changed third play")
        XCTAssertFalse(app.staticTexts["Selected plays confirmed removed on PublicMetaDB"].exists)
        XCTAssertFalse(app.buttons["publicmetadb.history.bulk.review"].isEnabled)
        try tapVisible(app.buttons["Refresh history"], tapping: false)
        XCTAssertTrue(app.buttons["Refresh history"].isEnabled)
    }

    func testRefreshStoppedSelectedPlayDeletion() throws {
        let ids = try selectedHistoryIDs()
        try inspectStoppedHistoryDeletion()
        try tapVisible(app.buttons["Refresh history"])
        try require(app.staticTexts[
            "2 selected plays were confirmed removed. Processing stopped at the next play; 1 later plays were not attempted."
        ].waitForNonExistence(timeout: 15), "Expected a fresh history snapshot after the stopped operation")
        let first = app.switches["publicmetadb.history.select.\(ids[0])"]
        for _ in 0..<8 {
            if first.exists && first.isHittable { break }
            app.swipeDown()
        }
        try require(first.exists && first.isHittable, "Expected the freshly read remaining plays")
        try selectHistoryPlays(ids)
    }

    private func selectedHistoryIDs() throws -> [String] {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SELECTED_IDS"])
        let ids = value.split(separator: ",").map(String.init)
        try require((1...4).contains(ids.count) && Set(ids).count == ids.count && ids.allSatisfy {
            $0.range(of: #"^[a-z0-9]{15}$"#, options: .regularExpression) != nil
        }, "Expected at most four distinct independently observed disposable play IDs")
        return ids
    }

    func testPrepareResumeClearing() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RECORD_ID"])
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        let progress = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RESUME_PERCENT"])
        try require(!id.isEmpty && !progress.isEmpty, "Expected the independently read resume record")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Resume points"])
        let record = app.buttons["publicmetadb.resume.record.\(id)"]
        try tapVisible(record, tapping: false)
        XCTAssertTrue(record.label.contains(title))
        XCTAssertTrue(record.label.contains(progress))
        record.tap()
        try tapVisible(app.buttons["publicmetadb.history.action"], tapping: false)
        XCTAssertEqual(app.buttons["publicmetadb.history.action"].label, "Clear this resume point")
        XCTAssertTrue(app.staticTexts[progress].exists)
        try tapVisible(app.buttons["publicmetadb.history.action"])
        try require(app.popovers.buttons["Clear this resume point"].waitForExistence(timeout: 5),
                    "Expected a reviewed exact resume clearing")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected complete resume-clearing disclosure")
        XCTAssertTrue(message.label.contains("Plozz does not clear the media server's position."))
    }

    func testCancelResumeClearing() throws {
        try require(app.popovers.buttons["Clear this resume point"].exists, "Expected the reviewed resume clearing")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.history.action"].isEnabled)
    }

    func testRejectStaleResumeClearing() throws {
        try tapVisible(app.popovers.buttons["Clear this resume point"])
        try require(app.staticTexts["The server already has a newer version of this."].waitForExistence(timeout: 30),
                    "Expected the independently changed or replaced resume to be protected")
        XCTAssertFalse(app.staticTexts["Change confirmed on PublicMetaDB"].exists)
        XCTAssertTrue(app.buttons["publicmetadb.history.action"].exists)
    }

    func testConfirmResumeClearing() throws {
        try tapVisible(app.popovers.buttons["Clear this resume point"])
        try require(app.staticTexts["Change confirmed on PublicMetaDB"].waitForExistence(timeout: 30),
                    "Expected the real resume to be confirmed cleared")
        XCTAssertFalse(app.buttons["publicmetadb.history.action"].exists)
    }

    func testClearedResumeRemainsAbsentAfterRelaunch() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RECORD_ID"])
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Resume points"])
        try require(app.staticTexts["Page 1 of 1"].waitForExistence(timeout: 30), "Expected the complete remaining resume page")
        XCTAssertFalse(app.buttons["publicmetadb.resume.record.\(id)"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "publicmetadb.resume.record.", title
        )).firstMatch.exists)
    }

    private func openSelectedTitleControls() throws {
        let card = try selectedTitleCard()
        recordState()
        card.press(forDuration: 1)
        try require(app.buttons["PublicMetaDB"].waitForExistence(timeout: 10),
                    "Expected PublicMetaDB in the native card menu")
        app.buttons["PublicMetaDB"].tap()
        try require(app.buttons["publicmetadb.open-title"].waitForExistence(timeout: 20),
                    "Expected the selected title's tracker controls")
    }

    func testCatalogShowRoundTrip() throws {
        for _ in 0..<2 {
            try openSelectedTitleControls()
            try require(app.staticTexts["TV show"].exists, "Expected show-level tracker controls")
            XCTAssertEqual(app.buttons["publicmetadb.open-title"].label, "Open title in Plozz")
            try openCatalogLibraryDetail()
            try require(app.scrollViews["series-season-tabs"].waitForExistence(timeout: 20),
                        "Expected the actual library show's seasons")
            recordState()
        }
    }

    func testCatalogEpisodeOpensParentShow() throws {
        try openHistoryPlay(expectedUnknownDate: true)
        try tapVisible(app.buttons["Title controls"])
        try require(app.staticTexts["Season 1, episode 3"].exists, "Expected exact episode coordinates")
        XCTAssertEqual(app.buttons["publicmetadb.open-title"].label, "Open show in Plozz")
        try openCatalogLibraryDetail()
        try require(app.scrollViews["series-season-tabs"].waitForExistence(timeout: 20),
                    "Expected the episode's parent library show")
        recordState()
    }

    func testCatalogMovieRoundTrip() throws {
        try openSelectedTitleControls()
        try require(app.staticTexts["Movie"].exists, "Expected movie-level tracker controls")
        XCTAssertEqual(app.buttons["publicmetadb.open-title"].label, "Open title in Plozz")
        try openCatalogLibraryDetail()
        XCTAssertFalse(app.scrollViews["series-season-tabs"].exists)
        recordState()
    }

    func testCatalogShowPreservesServerMetadata() throws {
        try openSelectedTitleControls()
        try openCatalogLibraryDetail()
        try assertCatalogLibraryShowMetadata()
    }

    func testCatalogListEntryOpensLibraryShow() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try openAcceptanceList()
        try tapVisible(app.buttons["Browse items"])
        let row = app.buttons.containing(.staticText, identifier: title)
        try require(row.firstMatch.waitForExistence(timeout: 30) && row.count == 1,
                    "Expected the independently verified real list entry")
        try tapVisible(row.element)
        try tapVisible(app.buttons["Title controls"])
        try require(app.staticTexts["TV show"].exists, "Expected the list entry's show identity")
        try openCatalogLibraryDetail()
        try assertCatalogLibraryShowMetadata()
    }

    private func assertCatalogLibraryShowMetadata() throws {
        let ids = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_CATALOG_SEASON_IDS"])
            .split(separator: ",").map { "season-\($0)" }
        let synopsis = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_CATALOG_SYNOPSIS"])
        try require(ids.count == 6 && !synopsis.isEmpty, "Expected independently read real server metadata")
        let seasons = app.scrollViews["series-season-tabs"]
        try require(seasons.waitForExistence(timeout: 20), "Expected library seasons")
        XCTAssertEqual(seasons.buttons.allElementsBoundByIndex.map(\.identifier), ids)
        XCTAssertTrue(app.buttons["More actions for Windsor"].exists)
        try tapVisible(app.staticTexts.matching(NSPredicate(format: "label == %@", synopsis)).firstMatch,
                       tapping: false)
        recordState()
    }

    func testReadRealRatings() throws {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATINGS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(RatingsEvidence.self, from: Data(encoded.utf8))
        try openSelectedRatings()
        try assertRealRatings(evidence)
        recordState()
    }

    func testReadRealSeasonRatings() throws {
        let evidence = try openSelectedSeasonRatings()
        for episode in evidence.episodes.sorted(by: { $0.episode < $1.episode }) {
            let row = app.buttons.matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", "Episode \(episode.episode)", "Episode \(episode.episode),"
            )).firstMatch
            try tapVisible(row, tapping: false)
            for aggregate in episode.aggregates.values {
                let expected = "\(aggregate.label): \(aggregate.average.formatted()) / 100 (\(aggregate.count) ratings)"
                try require(row.label.contains(expected) || row.staticTexts[expected].exists,
                            "Expected the exact independently read season aggregate")
            }
        }
        recordState()
    }

    func testEpisodeRatingScoreMenu() throws {
        _ = try openSelectedSeasonRatings()
        try tapVisible(app.buttons["Rate multiple episodes"])
        let score = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "publicmetadb.episode-rating.score."
        )).firstMatch
        try verifyRatingScoreMenu(score)
        XCTAssertFalse(app.popovers.buttons["Publish ratings"].exists)
        recordState()
    }

    func testSingleRatingScoreMenu() throws {
        try openSelectedTitleControls()
        try tapVisible(app.buttons["Community and personal ratings"])
        try tapVisible(app.buttons["Submit a rating"])
        try verifyRatingScoreMenu(app.buttons["publicmetadb.rating.score"])
        XCTAssertFalse(app.popovers.buttons["Publish rating"].exists)
        recordState()
    }

    private func verifyRatingScoreMenu(_ score: XCUIElement) throws {
        try tapVisible(score, tapping: false)
        XCTAssertEqual(score.value as? String, "50")
        for value in [49, 50] {
            try tapVisible(score)
            let choice = app.buttons[String(value)].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            try tapVisible(choice)
            XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
            XCTAssertEqual(score.value as? String, String(value))
        }
    }

    private func openSelectedSeasonRatings() throws -> SeasonRatingEvidence {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_SEASON_RATINGS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(SeasonRatingEvidence.self, from: Data(encoded.utf8))
        try require(evidence.tmdbID == 65494 && evidence.season == 1, "Expected independently verified Crown season one")
        try openSelectedTitleControls()
        try tapVisible(app.buttons["Season ratings"])
        let season = app.textFields["TMDB season number"]
        try tapVisible(season)
        season.typeText("\(evidence.season)\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        try tapVisible(app.buttons["Load season"])
        let disclosure = app.staticTexts["Episodes shown have community ratings; this is not a complete episode list."]
        try require(disclosure.waitForExistence(timeout: 45), "Expected real season ratings rather than a rejected snapshot")
        return evidence
    }

    func testPrepareRealEpisodeRatings() throws {
        let evidence = try openSelectedSeasonRatings()
        XCTAssertTrue([3, 4].allSatisfy { number in evidence.episodes.contains { $0.episode == number } })
        try tapVisible(app.buttons["Rate multiple episodes"])
        let label = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_LABEL"])
        XCTAssertEqual(label, "PlozzAcceptance1121bcf0")
        let field = app.textFields["Rating label"]
        try tapVisible(field)
        XCTAssertEqual(field.value as? String, "Overall")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Overall".count))
        field.typeText(label + "\n")
        XCTAssertEqual(field.value as? String, label)
        let first = app.textFields.matching(identifier: "TMDB episode number").firstMatch
        try tapVisible(first)
        first.typeText("3\n")
        XCTAssertEqual(first.value as? String, "3")
        try tapVisible(app.buttons["Add an episode"])
        let fields = app.textFields.matching(identifier: "TMDB episode number")
        XCTAssertEqual(fields.count, 2)
        let second = fields.element(boundBy: 1)
        try tapVisible(second)
        second.typeText("4\n")
        XCTAssertEqual(second.value as? String, "4")
        try tapVisible(app.buttons["Review ratings"])
        try require(app.popovers.buttons["Publish ratings"].waitForExistence(timeout: 10),
                    "Expected explicit batch publication confirmation")
        XCTAssertTrue(app.popovers.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Publish 2 “\(label)” ratings for TMDB season 1. A partial result is not a full success and will not be automatically retried."
        )).firstMatch.exists)
        recordState()
    }

    func testCancelPreparedEpisodeRatings() throws {
        XCTAssertTrue(app.popovers.buttons["Publish ratings"].exists)
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Review ratings"].isEnabled)
        XCTAssertFalse(app.staticTexts["All selected episode ratings were confirmed on PublicMetaDB"].exists)
        recordState()
    }

    func testEpisodeBatchRejectsInvalidInput() throws {
        _ = try openSelectedSeasonRatings()
        try tapVisible(app.buttons["Rate multiple episodes"])
        var previous = ""
        for value in ["", "0", "-1"] {
            if !value.isEmpty {
                let field = app.textFields.matching(identifier: "TMDB episode number").firstMatch
                try tapVisible(field)
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value + "\n")
                XCTAssertEqual(field.value as? String, value)
                previous = value
            }
            try tapVisible(app.buttons["Review ratings"])
            try tapVisible(app.staticTexts["Check the entered values."], tapping: false)
            XCTAssertFalse(app.popovers.buttons["Publish ratings"].exists)
            XCTAssertFalse(app.staticTexts["All selected episode ratings were confirmed on PublicMetaDB"].exists)
        }
        let first = app.textFields.matching(identifier: "TMDB episode number").firstMatch
        try tapVisible(first)
        first.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "3\n")
        try tapVisible(app.buttons["Add an episode"])
        let second = app.textFields.matching(identifier: "TMDB episode number").element(boundBy: 1)
        try tapVisible(second)
        second.typeText("3\n")
        try tapVisible(app.buttons["Review ratings"])
        try tapVisible(app.staticTexts["Check the entered values."], tapping: false)
        XCTAssertFalse(app.popovers.buttons["Publish ratings"].exists)
        try tapVisible(second)
        second.typeText(XCUIKeyboardKey.delete.rawValue + "4\n")
        XCTAssertEqual(second.value as? String, "4")
        let label = app.textFields["Rating label"]
        try tapVisible(label)
        XCTAssertEqual(label.value as? String, "Overall")
        label.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Overall".count) + "Two words\n")
        try tapVisible(app.buttons["Review ratings"])
        try tapVisible(app.staticTexts["Use a rating label without spaces."], tapping: false)
        XCTAssertFalse(app.popovers.buttons["Publish ratings"].exists)
        recordState()
    }

    func testEpisodeBatchEntryLimit() throws {
        _ = try openSelectedSeasonRatings()
        try tapVisible(app.buttons["Rate multiple episodes"])
        let add = app.buttons["Add an episode"]
        for _ in 1..<50 {
            try tapVisible(add, tapping: false)
            XCTAssertTrue(add.isEnabled)
            add.tap()
        }
        try tapVisible(add, tapping: false)
        XCTAssertFalse(add.isEnabled)
        let remove = app.buttons.matching(identifier: "Remove row")
            .allElementsBoundByIndex.last(where: \.isHittable)
        try XCTUnwrap(remove).tap()
        try tapVisible(add, tapping: false)
        XCTAssertTrue(add.isEnabled)
        add.tap()
        try tapVisible(add, tapping: false)
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.popovers.buttons["Publish ratings"].exists)
        XCTAssertFalse(app.staticTexts["All selected episode ratings were confirmed on PublicMetaDB"].exists)
        recordState()
    }

    func testConfirmPreparedEpisodeRatings() throws {
        XCTAssertTrue(app.popovers.buttons["Publish ratings"].exists)
        app.popovers.buttons["Publish ratings"].tap()
        try require(app.staticTexts["All selected episode ratings were confirmed on PublicMetaDB"]
            .waitForExistence(timeout: 45), "Expected independently reconciled batch publication")
        XCTAssertFalse(app.buttons["Review ratings"].exists)
        recordState()
    }

    func testPrepareRealEpisodeRatingDeletion() throws {
        try prepareRealEpisodeRatingDeletion(expectedCount: 2)
    }

    func testPrepareRealSingleEpisodeRatingDeletion() throws {
        try prepareRealEpisodeRatingDeletion(expectedCount: 1)
    }

    private func prepareRealEpisodeRatingDeletion(expectedCount: Int) throws {
        let evidence = try openSelectedSeasonRatings()
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SELECTED_IDS"])
        let identifiers = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        XCTAssertEqual(identifiers.count, expectedCount)
        XCTAssertEqual(Set(identifiers).count, expectedCount)
        for identifier in identifiers {
            let episodes = evidence.episodes.filter { $0.ratings.contains { $0.id == identifier } }
            XCTAssertEqual(episodes.count, 1)
            let episode = try XCTUnwrap(episodes.first)
            XCTAssertTrue([3, 4].contains(episode.episode))
            let record = try XCTUnwrap(episode.ratings.first { $0.id == identifier })
            XCTAssertEqual(record.label, "PlozzAcceptance1121bcf0")
            XCTAssertEqual(record.score, 50)
        }
        try tapVisible(app.buttons["Delete selected episode ratings"])
        for identifier in identifiers {
            let control = app.switches["publicmetadb.episode-rating.record.\(identifier)"]
            try tapVisible(control, tapping: false)
            XCTAssertEqual(control.value as? String, "0")
            try tapVisible(control.switches.firstMatch)
            XCTAssertEqual(control.value as? String, "1")
        }
        try tapVisible(app.buttons["Delete selected ratings"])
        try require(app.popovers.buttons["Delete selected ratings"].waitForExistence(timeout: 10),
                    "Expected exact batch deletion confirmation")
        XCTAssertTrue(app.popovers.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Requests removal of \(expectedCount) exact contributions, not all ratings for the season. PublicMetaDB verifies ownership. Server ratings and history are unchanged."
        )).firstMatch.exists)
        recordState()
    }

    func testCancelPreparedEpisodeRatingDeletion() throws {
        XCTAssertTrue(app.popovers.buttons["Delete selected ratings"].exists)
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["All selected ratings were confirmed removed"].exists)
        recordState()
    }

    func testConfirmPreparedEpisodeRatingDeletion() throws {
        XCTAssertTrue(app.popovers.buttons["Delete selected ratings"].exists)
        app.popovers.buttons["Delete selected ratings"].tap()
        try require(app.staticTexts["All selected ratings were confirmed removed"].waitForExistence(timeout: 45),
                    "Expected exact batch deletion and independent app readback")
        recordState()
    }

    private struct SeasonRatingEvidence: Decodable {
        struct Aggregate: Decodable {
            let label: String
            let average: Double
            let count: Int
        }
        struct Episode: Decodable {
            struct Record: Decodable {
                let id: String
                let label: String
                let score: Double
            }
            let episode: Int
            let aggregates: [String: Aggregate]
            let ratings: [Record]
        }
        let tmdbID: Int
        let season: Int
        let episodes: [Episode]
        enum CodingKeys: String, CodingKey {
            case tmdbID = "tmdb_id", season, episodes
        }
    }

    func testCommunityRatingLookupStartsDisabled() throws {
        try openPublicMetaDBAccount()
        let preference = app.switches["publicmetadb.ratings"]
        try tapVisible(preference, tapping: false)
        XCTAssertEqual(preference.value as? String, "0")
        try assertRealCommunityRatingLookup(enabled: false)
    }

    func testEnableCommunityRatingLookup() throws {
        try openPublicMetaDBAccount()
        let preference = app.switches["publicmetadb.ratings"]
        try tapVisible(preference, tapping: false)
        XCTAssertEqual(preference.value as? String, "0")
        try tapVisible(preference.switches.firstMatch)
        XCTAssertEqual(preference.value as? String, "1")
        recordState()
        try openPublicMetaDBAccount()
        XCTAssertEqual(app.switches["publicmetadb.ratings"].value as? String, "1")
        try assertRealCommunityRatingLookup(enabled: true)
    }

    func testReadEnabledCommunityRatingLookup() throws {
        try openPublicMetaDBAccount()
        XCTAssertEqual(app.switches["publicmetadb.ratings"].value as? String, "1")
        try assertRealCommunityRatingLookup(enabled: true)
    }

    func testReadCommunityRatingDetailSameProcess() throws {
        XCTAssertTrue(preservesProcess)
        try assertRealCommunityRatingLookup(enabled: true)
    }

    func testDisableCommunityRatingLookup() throws {
        try openPublicMetaDBAccount()
        let preference = app.switches["publicmetadb.ratings"]
        try tapVisible(preference, tapping: false)
        XCTAssertEqual(preference.value as? String, "1")
        try tapVisible(preference.switches.firstMatch)
        XCTAssertEqual(preference.value as? String, "0")
        recordState()
        try openPublicMetaDBAccount()
        XCTAssertEqual(app.switches["publicmetadb.ratings"].value as? String, "0")
        try assertRealCommunityRatingLookup(enabled: false)
    }

    private func assertRealCommunityRatingLookup(enabled: Bool) throws {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATINGS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(CommunityRatingLookupEvidence.self, from: Data(encoded.utf8))
        try require(evidence.overall.total >= 0, "Expected independently read Overall contributions")
        try openSelectedTitle()
        if ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_SCOPE"] == "episode" {
            let episode = try visibleSelectedEpisode()
            let title = episode.label
            try tapVisible(app.buttons["More actions for \(title)"])
            try tapVisible(app.buttons["Go to Episode"])
            try require(app.scrollViews["series-season-tabs"].waitForNonExistence(timeout: 20),
                        "Expected the episode's own page, not its parent series")
            try require(app.staticTexts[title].waitForExistence(timeout: 20),
                        "Expected the exact episode title")
            try require(detailPlayButton.exists, "Expected the real episode detail without starting playback")
        }
        let baseRating = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Community rating ", "TMDB rating "
        )).firstMatch
        if evidence.requiresBaseRating {
            try require(baseRating.waitForExistence(timeout: 30), "Expected actual server ratings to remain visible")
        }
        if enabled, evidence.overall.total > 0 {
            let average = try XCTUnwrap(evidence.overall.average)
            let score = "\(Int(average.rounded()))/100"
            let expected = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@ OR label == %@", "PublicMetaDB rating \(score)", "PublicMetaDB \(score)"
            )).firstMatch
            try require(expected.waitForExistence(timeout: 45), "Expected the exact independently read Overall score")
            try tapVisible(expected, tapping: false)
        } else {
            if enabled { XCTAssertNil(evidence.overall.average) }
            let unexpected = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label MATCHES %@",
                "PublicMetaDB rating ", "PublicMetaDB [0-9]+/100"
            )).firstMatch
            try require(!unexpected.waitForExistence(timeout: 10),
                        "Disabled lookup or an empty Overall result must not invent a badge")
        }
        recordState()
    }

    private struct CommunityRatingLookupEvidence: Decodable {
        struct Overall: Decodable { let total: Int; let average: Double? }
        let overall: Overall
        let requiresBaseRating: Bool
    }

    func testRefreshRealRatings() throws {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATINGS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(RatingsEvidence.self, from: Data(encoded.utf8))
        try openSelectedRatings()
        try assertRealRatings(evidence)
        try tapVisible(app.buttons["Refresh"])
        try assertRealRatings(evidence)
        recordState()
    }

    private func assertRealRatings(_ evidence: RatingsEvidence) throws {
        if evidence.items.isEmpty {
            try require(app.staticTexts["No ratings"].waitForExistence(timeout: 30),
                        "Expected the independently verified empty ratings")
        } else {
            try require(app.buttons["publicmetadb.rating.record.\(evidence.items[0].id)"].waitForExistence(timeout: 30),
                        "Expected the completed real contribution read")
            if evidence.items.count < evidence.total {
                try tapVisible(app.staticTexts["Showing \(evidence.items.count) of \(evidence.total) ratings"],
                               tapping: false)
            }
            for record in evidence.items {
                let row = app.buttons["publicmetadb.rating.record.\(record.id)"]
                try tapVisible(row, tapping: false)
                XCTAssertTrue(row.staticTexts[record.label].exists)
                XCTAssertTrue(row.staticTexts[record.displayScore].exists)
            }
        }
    }

    func testPrepareRealRating() throws {
        let label = try fillAndSubmitRealRatingForm()
        try require(app.popovers.buttons["Publish rating"].waitForExistence(timeout: 10),
                    "Expected explicit rating publication confirmation")
        XCTAssertTrue(app.popovers.staticTexts["Publish “\(label)”: 50 / 100 on PublicMetaDB."].exists)
        recordState()
    }

    func testRejectRatingLabelWithSpaces() throws {
        let label = try fillAndSubmitRealRatingForm()
        try require(label.contains(" "), "Expected the actual rejected label format")
        try require(app.staticTexts["Use a rating label without spaces."].waitForExistence(timeout: 10),
                    "Expected actionable validation before publication")
        XCTAssertFalse(app.popovers.buttons["Publish rating"].exists)
        XCTAssertFalse(app.staticTexts["Rating confirmed on PublicMetaDB"].exists)
        recordState()
    }

    private func fillAndSubmitRealRatingForm() throws -> String {
        try openSelectedRatings()
        try tapVisible(app.buttons["Submit a rating"])
        let field = app.textFields["publicmetadb.rating.label"]
        try tapVisible(field)
        let previous = try XCTUnwrap(field.value as? String)
        XCTAssertEqual(previous, "Overall")
        let label = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_LABEL"])
        try require(!label.isEmpty && label.count < 64, "Expected the explicit bounded test-account rating label")
        if label != previous {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
            field.typeText(label)
            XCTAssertEqual(field.value as? String, label)
        }
        field.typeText("\n")
        try tapVisible(app.staticTexts[
            "The rating and your PublicMetaDB contributor name will be public. This does not change your media server's rating."
        ], tapping: false)
        try tapVisible(app.buttons["publicmetadb.rating.submit"])
        return label
    }

    func testCancelPreparedRating() throws {
        try require(app.popovers.buttons["Publish rating"].exists, "Expected the prepared rating")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["publicmetadb.rating.submit"].isEnabled)
        XCTAssertFalse(app.staticTexts["Rating confirmed on PublicMetaDB"].exists)
        recordState()
    }

    func testConfirmPreparedRating() throws {
        try require(app.popovers.buttons["Publish rating"].exists, "Expected the prepared rating")
        app.popovers.buttons["Publish rating"].tap()
        try require(app.staticTexts["Rating confirmed on PublicMetaDB"].waitForExistence(timeout: 45),
                    "Expected exact rating publication and independent app readback")
        XCTAssertFalse(app.buttons["publicmetadb.rating.submit"].exists)
        recordState()
    }

    func testRejectRatingFromIncompleteSnapshot() throws {
        try require(app.popovers.buttons["Publish rating"].exists, "Expected the prepared rating")
        app.popovers.buttons["Publish rating"].tap()
        try require(app.staticTexts[
            "PublicMetaDB returned an incomplete result. The requested operation cannot be confirmed from this response."
        ].waitForExistence(timeout: 45), "Expected a capped snapshot to block publication")
        XCTAssertFalse(app.staticTexts["Rating confirmed on PublicMetaDB"].exists)
        recordState()
    }

    func testPrepareRealRatingDeletion() throws {
        let identifier = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_RECORD_ID"])
        try require(!identifier.isEmpty, "Expected the independently confirmed owned contribution")
        try openSelectedRatings()
        let row = app.buttons["publicmetadb.rating.record.\(identifier)"]
        try tapVisible(row)
        try tapVisible(app.staticTexts[
            "Only the author can delete a rating. PublicMetaDB verifies ownership using your API key."
        ], tapping: false)
        try tapVisible(app.buttons["Delete rating"])
        try require(app.popovers.buttons["Delete rating"].waitForExistence(timeout: 10),
                    "Expected exact contribution deletion confirmation")
        XCTAssertTrue(app.popovers.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Requests deletion of this exact contribution. PublicMetaDB rejects the request if it is not yours. Server ratings and watched history are unchanged."
        )).firstMatch.exists)
        recordState()
    }

    func testCancelPreparedRatingDeletion() throws {
        try require(app.popovers.buttons["Delete rating"].exists, "Expected prepared exact deletion")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Rating removed from PublicMetaDB"].exists)
        recordState()
    }

    func testConfirmPreparedRatingDeletion() throws {
        try require(app.popovers.buttons["Delete rating"].exists, "Expected prepared exact deletion")
        app.popovers.buttons["Delete rating"].tap()
        try require(app.staticTexts["Rating removed from PublicMetaDB"].waitForExistence(timeout: 45),
                    "Expected independently confirmed exact deletion")
        recordState()
    }

    private struct RatingsEvidence: Decodable {
        struct Record: Decodable { let id: String; let label: String; let displayScore: String }
        let total: Int
        let items: [Record]
    }

    private func openSelectedRatings() throws {
        let scope = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_SCOPE"])
        try require(["movie", "show", "episode"].contains(scope), "Expected an exact independently read rating scope")
        if scope == "episode" {
            try openHistoryPlay(expectedUnknownDate: true)
            try tapVisible(app.buttons["Title controls"])
            try require(app.staticTexts["Season 1, episode 3"].exists, "Expected the actual episode identity")
        } else {
            try openSelectedTitleControls()
            try require(app.staticTexts[scope == "movie" ? "Movie" : "TV show"].exists,
                        "Expected the exact movie/show namespace")
        }
        try tapVisible(app.buttons["Community and personal ratings"])
    }

    func testBrowseEmptyPicks() throws {
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Picks"])
        try require(app.staticTexts["No records"].waitForExistence(timeout: 30),
                    "Expected an explicit empty result for the independently verified empty recipe collection")
        XCTAssertTrue(app.staticTexts[
            "Picks are created on PublicMetaDB. Recommendations can remain cached there for up to 24 hours."
        ].exists)
        try tapVisible(app.buttons["Refresh"])
        try require(app.staticTexts["No records"].waitForExistence(timeout: 30), "Expected empty result after refresh")
        recordState()
    }

    func testBrowseRealPicksPage() throws {
        let environment = ProcessInfo.processInfo.environment
        let encoded = try XCTUnwrap(environment["PLOZZ_TRACKER_PICKS_EVIDENCE"])
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        try require(data.count < 100_000, "Expected bounded independent recipe evidence")
        let evidence = try JSONDecoder().decode(PicksEvidence.self, from: data)
        let page = try XCTUnwrap(Int(environment["PLOZZ_TRACKER_PICKS_PAGE"] ?? ""))
        try require(evidence.pages.map(\.page) == Array(1...5) && (1...5).contains(page),
                    "Expected the five actual exposed recommendation pages")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "independent-real-picks-expectations"
        attachment.lifetime = .keepAlways
        add(attachment)

        try openPicksRecipe(named: evidence.recipe.name)
        for current in 1...page {
            try tapVisible(app.staticTexts["Page \(current) of 5"], tapping: false)
            if current < page { try tapVisible(app.buttons["Next page"]) }
        }
        try assertPicksPage(evidence.pages[page - 1])
        if page == 3 {
            try tapVisible(app.buttons["publicmetadb.refresh"])
            try assertPicksPage(evidence.pages[page - 1])
        } else if page == 5 {
            XCTAssertFalse(app.buttons["Next page"].exists, "The API exposes five pages, not the uncapped total")
            try tapVisible(app.buttons["Previous page"])
            try tapVisible(app.staticTexts["Page 4 of 5"], tapping: false)
            try assertPicksPage(evidence.pages[3])
        }
    }

    func testPicksEntryOpensLibraryMovie() throws {
        let environment = ProcessInfo.processInfo.environment
        let title = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        let year = try XCTUnwrap(environment["PLOZZ_TRACKER_CATALOG_YEAR"])
        let encoded = try XCTUnwrap(environment["PLOZZ_TRACKER_PICKS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(PicksEvidence.self, from: Data(encoded.utf8))
        try require(evidence.pages.first?.items.contains { $0.title == title && $0.year == year } == true,
                    "Expected a genuine first-page recommendation independently matched to the servers")
        try openPicksRecipe(named: evidence.recipe.name)
        let row = app.buttons.containing(.staticText, identifier: title)
            .containing(.staticText, identifier: year)
        try tapVisible(row.firstMatch)
        try require(app.staticTexts["Movie"].waitForExistence(timeout: 15),
                    "Expected the recommendation's movie namespace")
        try openCatalogLibraryDetail()
        let metadata = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", year + "  ·")).firstMatch
        try require(metadata.waitForExistence(timeout: 15), "Expected the real library movie's release year")
        XCTAssertFalse(app.scrollViews["series-season-tabs"].exists)
        XCTAssertFalse(app.buttons["Close player"].exists, "Browsing must not start playback")
        recordState()
    }

    private func openPicksRecipe(named name: String) throws {
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Picks"])
        let recipe = app.buttons.containing(.staticText, identifier: name)
        try require(recipe.firstMatch.waitForExistence(timeout: 30) && recipe.count == 1,
                    "Expected the independently verified owned recipe")
        try tapVisible(recipe.element)
    }

    private struct PicksEvidence: Decodable {
        struct Recipe: Decodable { let name: String }
        struct Page: Decodable {
            struct Item: Decodable { let title: String; let year: String }
            let page: Int
            let items: [Item]
        }
        let recipe: Recipe
        let pages: [Page]
    }

    private func assertPicksPage(_ page: PicksEvidence.Page) throws {
        try require(page.items.count == 20, "Expected every real item on this page")
        let heading = app.staticTexts["Recommendations"]
        for _ in 0..<8 {
            if heading.exists && heading.isHittable { break }
            app.swipeDown()
        }
        try require(heading.exists && heading.isHittable, "Expected the recommendation page header")
        for (index, item) in page.items.enumerated() {
            let row = app.buttons.containing(.staticText, identifier: item.title)
                .containing(.staticText, identifier: item.year)
            try tapVisible(row.firstMatch, tapping: false)
            XCTAssertEqual(row.count, 1, "Expected exactly the independently read title and release year")
            if index == 0 || index == page.items.count - 1 { recordState() }
        }
        try tapVisible(app.staticTexts["Page \(page.page) of 5"], tapping: false)
        XCTAssertEqual(app.buttons["Previous page"].exists, page.page > 1)
        XCTAssertEqual(app.buttons["Next page"].exists, page.page < 5)
        XCTAssertFalse(app.staticTexts["No records"].exists)
        recordState()
    }

    func testUnownedCatalogTitleIsAbsentFromLibraries() throws {
        let title = try searchForSelectedTitle()
        let empty = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "No results")).firstMatch
        try require(empty.waitForExistence(timeout: 30), "Expected no library search results")
        XCTAssertFalse(app.buttons.containing(.staticText, identifier: title).firstMatch.exists)
        recordState()
    }

    func testCatalogUnownedListEntryOpensWithoutPlayback() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        let year = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_CATALOG_YEAR"])
        try require(Int(year) != nil && year.count == 4, "Expected the independently verified release year")
        try openAcceptanceList()
        try tapVisible(app.buttons["Browse items"])
        let row = app.buttons.containing(.staticText, identifier: title)
        try require(row.firstMatch.waitForExistence(timeout: 30) && row.count == 1,
                    "Expected the real external movie's resolved list label")
        try tapVisible(row.element)
        try tapVisible(app.buttons["Title controls"])
        try require(app.staticTexts["Movie"].exists, "Expected a movie, not an unrelated show sharing its number")
        try tapVisible(app.buttons["publicmetadb.open-title"])
        let name = app.staticTexts[title]
        try require(name.waitForExistence(timeout: 30) || app.images[title].exists,
                    "Expected real external title metadata")
        try require(app.buttons["publicmetadb.open-title"].waitForNonExistence(timeout: 10),
                    "Expected dismissal of tracker controls")
        let metadata = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", year + "  ·")).firstMatch
        try require(metadata.waitForExistence(timeout: 15), "Expected the real external movie's release year")
        XCTAssertTrue(app.buttons["Add to Watchlist"].exists)
        XCTAssertFalse(detailPlayButton.exists, "An unowned external title must not claim a playable library source")
        XCTAssertFalse(app.buttons["Close player"].exists)
        recordState()
    }

    private func openCatalogLibraryDetail() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try tapVisible(app.buttons["publicmetadb.open-title"])
        try require(detailPlayButton.waitForExistence(timeout: 30), "Expected a playable library detail, not an external placeholder")
        XCTAssertFalse(app.buttons["publicmetadb.open-title"].exists)
        XCTAssertTrue(app.images[title].exists || app.staticTexts[title].exists)
    }

    func testPrepareShowDrop() throws {
        try openSelectedTitleControls()
        try require(app.staticTexts["TV show"].exists, "Expected show-level identity, not the next episode")
        try tapVisible(app.buttons["Drop show on PublicMetaDB"])
        XCTAssertEqual(app.buttons["publicmetadb.history.action"].label, "Drop show")
        try tapVisible(app.buttons["publicmetadb.history.action"])
        try require(app.popovers.buttons["Drop show"].waitForExistence(timeout: 5), "Expected show-drop confirmation")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the full show-drop disclosure")
        XCTAssertTrue(message.label.contains("without deleting watch history"))
        XCTAssertTrue(message.label.contains("Recording another episode or adding the show to a list can automatically undrop it."))
        XCTAssertTrue(message.label.contains("Plozz does not change media-server state."))
    }

    func testCancelShowDrop() throws {
        try require(app.popovers.buttons["Drop show"].exists, "Expected the prepared show drop")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.history.action"].isEnabled)
    }

    func testConfirmShowDrop() throws {
        try tapVisible(app.popovers.buttons["Drop show"])
        try require(app.staticTexts["Change confirmed on PublicMetaDB"].waitForExistence(timeout: 30),
                    "Expected independently confirmed show drop")
        XCTAssertFalse(app.buttons["publicmetadb.history.action"].exists)
    }

    func testPrepareShowUndrop() throws {
        try openDroppedShow()
        XCTAssertEqual(app.buttons["publicmetadb.history.action"].label, "Undrop title")
        try tapVisible(app.buttons["publicmetadb.history.action"])
        try require(app.popovers.buttons["Undrop title"].waitForExistence(timeout: 5), "Expected exact undrop confirmation")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the full undrop disclosure")
        XCTAssertTrue(message.label.contains("Watched history and media-server state are unchanged."))
    }

    private func openDroppedShow() throws {
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RECORD_ID"])
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try require(!id.isEmpty, "Expected an independently observed dropped record")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["Dropped titles"])
        let record = app.buttons["publicmetadb.dropped.record.\(id)"]
        try tapVisible(record, tapping: false)
        XCTAssertTrue(record.label.contains(title))
        XCTAssertTrue(record.label.contains("TV show"))
        record.tap()
    }

    func testCancelShowUndrop() throws {
        try require(app.popovers.buttons["Undrop title"].exists, "Expected the prepared undrop")
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.history.action"].isEnabled)
    }

    func testConfirmShowUndrop() throws {
        try tapVisible(app.popovers.buttons["Undrop title"])
        try require(app.staticTexts["Change confirmed on PublicMetaDB"].waitForExistence(timeout: 30),
                    "Expected the exact dropped title to be restored")
        XCTAssertFalse(app.buttons["publicmetadb.history.action"].exists)
    }

    func testMovieHasNoShowDropControls() throws {
        try openSelectedTitleControls()
        try require(app.staticTexts["Movie"].exists, "Expected real movie identity")
        XCTAssertTrue(app.buttons["Add a watched play"].exists)
        XCTAssertFalse(app.buttons["Drop show on PublicMetaDB"].exists)
        try tapVisible(app.buttons["Community and personal ratings"], tapping: false)
        XCTAssertFalse(app.buttons["Drop show on PublicMetaDB"].exists)
    }

    func testPrepareShowListAddition() throws {
        try openSelectedTitleControls()
        try prepareShowListAddition()
    }

    func testPrepareDroppedShowListAddition() throws {
        try openDroppedShow()
        try tapVisible(app.buttons["Title controls"])
        try prepareShowListAddition()
    }

    private func prepareShowListAddition() throws {
        try require(app.staticTexts["TV show"].exists, "Expected the real show, not an episode")
        try tapVisible(app.buttons["Add to a list"])
        try tapVisible(acceptanceListChoice())
        try require(app.popovers.buttons["Add to list"].waitForExistence(timeout: 5), "Expected the reviewed show addition")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "PublicMetaDB may undrop shows when added."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected the automatic-undrop disclosure")
        XCTAssertTrue(message.label.contains("Changes to a watchlist destination can propagate"))
        XCTAssertFalse(message.label.contains("This list is public."))
    }

    func testCancelWatchlistDestinationConsent() throws {
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.watchlist"])
        try require(app.staticTexts["Not syncing a list"].exists, "Expected no existing watchlist grant")
        try tapVisible(app.buttons["publicmetadb.watchlist.choose"])
        try tapVisible(acceptanceListChoice())
        try require(app.popovers.buttons["Use this list"].waitForExistence(timeout: 5), "Expected separate sync consent")
        let message = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "PublicMetaDB may undrop shows when added."
        )).firstMatch
        try require(message.waitForExistence(timeout: 5), "Expected conditional upstream effects, not guaranteed undropping")
        XCTAssertTrue(message.label.contains("changes can propagate to your other enabled watchlist destinations"))
        XCTAssertTrue(message.label.contains("Watched history and progress are not imported."))
        XCTAssertTrue(message.label.contains("This list is currently private on PublicMetaDB."))
        try dismissConfirmation()
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 5))
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.watchlist"])
        XCTAssertTrue(app.staticTexts["Not syncing a list"].exists)
        XCTAssertFalse(app.buttons["publicmetadb.watchlist.disable"].exists)
    }

    func testEpisodeHasNoShowDropControls() throws {
        try openHistoryPlay(expectedUnknownDate: true)
        try tapVisible(app.buttons["Title controls"])
        try require(app.staticTexts["Season 1, episode 3"].exists, "Expected exact episode identity")
        XCTAssertTrue(app.buttons["Add a watched play"].exists)
        XCTAssertFalse(app.buttons["Drop show on PublicMetaDB"].exists)
        try tapVisible(app.buttons["Anime season mappings"], tapping: false)
        XCTAssertFalse(app.buttons["Drop show on PublicMetaDB"].exists)
    }

    func testCancelHistoryDateChange() throws {
        try cancelHistoryDateConfirmation(addingPlay: false)
    }

    func testCancelNewHistoryPlay() throws {
        try cancelHistoryDateConfirmation(addingPlay: true)
    }

    private func cancelHistoryDateConfirmation(addingPlay: Bool) throws {
        try testBrowseUnknownHistoryPlay()
        try tapVisible(app.buttons[addingPlay ? "Add another play" : "Change watch date"])
        let unknown = app.switches["Watch date unknown"]
        try tapVisible(unknown, tapping: false)
        if addingPlay {
            XCTAssertEqual(unknown.value as? String, "0")
            try tapVisible(unknown.switches.firstMatch)
        }
        XCTAssertEqual(unknown.value as? String, "1")
        try tapVisible(app.buttons["publicmetadb.history.review-date"])
        try require(app.buttons["Save play"].waitForExistence(timeout: 5), "Expected the reviewed play draft")
        let disclosure = app.popovers.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Other apps connected to PublicMetaDB may also react to this change."
        )).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.contains("Watch date unknown"))
        XCTAssertEqual(disclosure.label.contains("This creates another play; it does not replace earlier plays."),
                       addingPlay)
        try dismissConfirmation()
        XCTAssertTrue(app.buttons["Save play"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publicmetadb.history.review-date"].exists)
    }

    func testPrepareExactListDeletion() throws {
        try openAcceptanceList()
        try tapVisible(app.buttons["publicmetadb.list.delete"])
        try require(listDeletionConfirmation.waitForExistence(timeout: 5), "Expected exact-list confirmation")
    }

    func testCancelExactListDeletion() throws {
        try require(listDeletionConfirmation.exists, "Expected the pending exact-list confirmation")
        try dismissConfirmation()
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

    func testEnableOngoingWatchedImportFromCurrentSettings() throws {
        try enableOngoingImport(categories: [("watched", "Watched")], fromCurrentSettings: true)
    }

    func testOngoingImportIsDisabled() throws {
        try openOngoingImportSettings()
        try assertOngoingImportIsDisabled()
    }

    func testRefreshDisabledOngoingImportInCurrentProcess() throws {
        try require(app.buttons["tracker-history.enable-sync"].exists
            && !app.buttons["tracker-history.disable-sync"].exists,
                    "Expected the disabled ongoing-sync page")
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back"))
            .allElementsBoundByIndex.filter(\.isHittable)
        try require(back.count == 1, "Expected the frontmost native Back action")
        back[0].tap()
        try refreshHistoryComparison()
        try showOngoingImportSettings()
        try assertOngoingImportIsDisabled()
    }

    func testRetryComparisonAndInspectDisabledOngoingImport() throws {
        try retryHistoryComparison()
        try showOngoingImportSettings()
        try assertOngoingImportIsDisabled()
    }

    private func assertOngoingImportIsDisabled() throws {
        XCTAssertTrue(app.buttons["tracker-history.enable-sync"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["tracker-history.disable-sync"].exists)
        XCTAssertEqual(app.switches["tracker-history.sync-watched"].value as? String, "0")
        XCTAssertEqual(app.switches["tracker-history.sync-resume"].value as? String, "0")
        let destinations = app.switches.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "tracker-history.sync-server."
        )).allElementsBoundByIndex
        XCTAssertFalse(destinations.isEmpty)
        for destination in destinations {
            XCTAssertEqual(destination.value as? String, "0")
        }
        recordState()
    }

    func testEnableOngoingResumeImport() throws {
        try enableOngoingImport(categories: [("resume", "Resume points")])
    }

    func testEnableOngoingResumeImportFromCurrentSettings() throws {
        try enableOngoingImport(categories: [("resume", "Resume points")], fromCurrentSettings: true)
    }

    func testEnableOngoingWatchedAndResumeImport() throws {
        try enableOngoingImport(categories: [("watched", "Watched"), ("resume", "Resume points")])
    }

    func testEnableOngoingWatchedAndResumeImportFromCurrentSettings() throws {
        try enableOngoingImport(
            categories: [("watched", "Watched"), ("resume", "Resume points")],
            fromCurrentSettings: true
        )
    }

    private func enableOngoingImport(
        categories: [(id: String, label: String)], fromCurrentSettings: Bool = false
    ) throws {
        if !fromCurrentSettings { try openOngoingImportSettings() }
        try require(app.buttons["tracker-history.enable-sync"].exists
            && !app.buttons["tracker-history.disable-sync"].exists,
                    "Expected the disabled ongoing-sync settings before new consent")
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
        let destinations = app.switches.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "tracker-history.sync-server."
        )).allElementsBoundByIndex
        XCTAssertFalse(destinations.isEmpty)
        for candidate in destinations {
            XCTAssertEqual(candidate.value as? String, candidate.identifier == destination.identifier ? "1" : "0")
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

    func testSynchronizeOngoingImportFromCurrentSettings() throws {
        try synchronizeOngoingImport(expectingReview: false, fromCurrentSettings: true)
    }

    func testInspectOngoingImportWithoutManualSync() throws {
        try openOngoingImportSettings(relaunch: false)
        try require(app.buttons["tracker-history.disable-sync"].exists, "Expected the retained sync permission")
        recordState()
    }

    func testOngoingSyncReportsReviewRequirement() throws {
        try synchronizeOngoingImport(expectingReview: true)
    }

    private func synchronizeOngoingImport(
        expectingReview: Bool, fromCurrentSettings: Bool = false
    ) throws {
        if !fromCurrentSettings { try openOngoingImportSettings() }
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
        try openOngoingImportSettings()
        try disableOngoingImport()
    }

    func testDisableOngoingImportFromCurrentSettings() throws {
        try disableOngoingImport()
        let selections = app.switches.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "tracker-history.sync-"
        )).allElementsBoundByIndex.map(\.identifier)
        try require(!selections.isEmpty && Set(selections).count == selections.count,
                    "Expected unambiguous disabled-sync selections")
        for identifier in selections {
            let selection = app.switches[identifier]
            try require(["0", "1"].contains(selection.value as? String ?? ""),
                        "Expected an explicit sync selection state")
            if selection.value as? String == "1" {
                try tapVisible(selection.switches.firstMatch)
            }
        }
        try assertOngoingImportIsDisabled()
    }

    private func disableOngoingImport() throws {
        try require(app.buttons["tracker-history.disable-sync"].exists,
                    "Expected existing sync permission before revocation")
        try tapVisible(app.buttons["tracker-history.disable-sync"])
        try require(app.buttons["tracker-history.enable-sync"].waitForExistence(timeout: 10),
                    "Expected revoked ongoing-import permission")
    }

    private func openOngoingImportSettings(relaunch: Bool = true) throws {
        try openHistoryComparison(relaunch: relaunch)
        try showOngoingImportSettings()
    }

    private func showOngoingImportSettings() throws {
        try require(app.activityIndicators["Comparing or verifying history…"].waitForNonExistence(timeout: 75),
                    "Expected the comparison to finish before opening ongoing sync")
        let link = app.buttons["tracker-history.ongoing-sync"]
        try tapVisible(link, tapping: false, maximumSwipes: 32)
        try require(link.isEnabled, "Expected ongoing-sync navigation after a successful comparison")
        let collection = app.collectionViews.containing(.any, identifier: link.identifier).element
        try require(collection.exists, "Expected the ongoing-sync link in its comparison list")
        for _ in 0..<4 {
            if collection.frame.intersection(app.frame).insetBy(dx: 0, dy: 8).contains(link.frame) { break }
            collection.swipeUp(velocity: .slow)
        }
        try require(collection.frame.intersection(app.frame).insetBy(dx: 0, dy: 8).contains(link.frame),
                    "Expected the complete ongoing-sync link inside the visible list")
        link.tap()
        let consent = app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["tracker-history.enable-sync", "tracker-history.disable-sync"]
        )).firstMatch
        try require(consent.waitForExistence(timeout: 15), "Expected the ongoing-sync settings page")
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
        let names = app.switches.matching(NSPredicate(format: "label != ''"))
            .allElementsBoundByIndex.map(\.label)
        try require(!names.isEmpty && names.count <= 20 && Set(names).count == names.count,
                    "Expected a bounded, unambiguous library selection")
        for name in names where name != "Movies" {
            let library = app.switches.matching(NSPredicate(format: "label == %@", name)).element
            if library.value as? String == "0" { continue }
            try require(library.value as? String == "1", "Expected an explicit library selection state")
            try tapVisible(library.switches.firstMatch)
            let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: library)
            try require(XCTWaiter.wait(for: [disabled], timeout: 15) == .completed,
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

    func testInspectHistoryComparison() throws {
        try openHistoryComparison()
        recordState()
    }

    func testOpenHistoryComparison() throws {
        try openHistoryComparison()
        try tapVisible(importSelection, tapping: false, maximumSwipes: 32)
        XCTAssertTrue(importSelection.exists)
        XCTAssertEqual(importSelection.value as? String, "0")
        recordState()
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false, maximumSwipes: 32)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testPreviewServerHistoryExport() throws {
        let environment = ProcessInfo.processInfo.environment
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_USER"])
        let library = try XCTUnwrap(environment["PLOZZ_TRACKER_HISTORY_LIBRARY"])
        let mode = try XCTUnwrap(environment["PLOZZ_TRACKER_EXPORT_MODE"])
        let timeout = try XCTUnwrap(Double(environment["PLOZZ_TRACKER_EXPORT_PREVIEW_TIMEOUT_SECONDS"] ?? "120"))
        try require(["Watched titles", "Resume points"].contains(mode), "Expected an explicit export category")
        try require(timeout.isFinite && (30...600).contains(timeout), "Expected a bounded full-inventory deadline")
        try openPublicMetaDBAccount()
        try tapVisible(app.buttons["publicmetadb.export-history"])
        try tapVisible(app.buttons["publicmetadb.export.account"])
        let account = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " · \(user)"))
        try require(account.firstMatch.waitForExistence(timeout: 10) && account.count == 1,
                    "Expected the exact dedicated export user")
        account.element.tap()
        try tapVisible(app.buttons["publicmetadb.export.library"])
        try tapVisible(app.collectionViews.buttons[library])
        try tapVisible(app.buttons["publicmetadb.export.mode"])
        try tapVisible(app.collectionViews.buttons[mode])
        try tapVisible(app.buttons["publicmetadb.export.preview"])
        try require(app.buttons["publicmetadb.export.apply"].waitForExistence(timeout: timeout),
                    "Expected a complete real server-history comparison")
        XCTAssertFalse(app.buttons["publicmetadb.export.apply"].isEnabled)
    }

    func testInspectSelectedHistoryExport() throws {
        let expected = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_EXPORT_STATUS"])
        let row = try exportRow()
        try tapVisible(row, tapping: false)
        XCTAssertTrue(row.staticTexts[expected].exists)
        if expected == "Already present — no change"
            || expected == "No supported exact identity, date, runtime, or resume position — not exported" {
            XCTAssertEqual(row.switches.count, 0)
        }
    }

    func testCancelSelectedHistoryExport() throws {
        try selectHistoryExport()
        try dismissConfirmation()
        try require(app.buttons["Export selected titles"].waitForNonExistence(timeout: 5),
                    "Expected cancellation of the exact export")
        XCTAssertEqual(try exportSelection().value as? String, "1")
        try testPreviewServerHistoryExport()
        try tapVisible(try exportSelection(), tapping: false)
        XCTAssertEqual(try exportSelection().value as? String, "0")
    }

    func testConfirmSelectedHistoryExport() throws {
        try selectHistoryExport()
        try tapVisible(app.buttons["Export selected titles"])
        let row = try exportRow()
        try tapVisible(row, tapping: false)
        XCTAssertTrue(row.staticTexts["Confirmed on PublicMetaDB"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["publicmetadb.export.apply"].isEnabled)
    }

    func testPrepareSelectedHistoryExport() throws {
        try testPreviewServerHistoryExport()
        try selectHistoryExport()
    }

    func testRejectStaleHistoryExport() throws {
        let confirm = app.buttons["Export selected titles"]
        try require(confirm.exists, "Expected the previously prepared export confirmation")
        try tapVisible(confirm)
        try require(app.staticTexts[
            "Tracker or server history changed after the comparison. Compare again before applying changes."
        ].waitForExistence(timeout: 60), "Expected stale-source or stale-tracker rejection")
        XCTAssertFalse(try exportRow().staticTexts["Confirmed on PublicMetaDB"].exists)
    }

    private func exportRow() throws -> XCUIElement {
        let item = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ITEM"])
        return app.otherElements["publicmetadb.export.row.\(item)"]
    }

    private func exportSelection() throws -> XCUIElement {
        let item = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ITEM"])
        return app.switches["publicmetadb.export.select.\(item)"]
    }

    private func selectHistoryExport() throws {
        let selection = try exportSelection()
        try tapVisible(selection, tapping: false)
        XCTAssertEqual(selection.value as? String, "0")
        try tapVisible(selection.switches.firstMatch)
        XCTAssertEqual(selection.value as? String, "1")
        let apply = app.buttons["publicmetadb.export.apply"]
        try tapVisible(apply, tapping: false)
        XCTAssertEqual(apply.label, "Export 1 selected titles")
        XCTAssertTrue(apply.isEnabled)
        apply.tap()
        XCTAssertTrue(app.buttons["Export selected titles"].waitForExistence(timeout: 5))
    }

    func testCancelHistoryImportAndReopen() throws {
        try openHistoryComparison()
        try selectHistoryImport()
        try testCancelPreparedHistoryImport()
    }

    func testCancelPreparedHistoryImport() throws {
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForExistence(timeout: 5))
        try dismissConfirmation()
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForNonExistence(timeout: 5))
        for _ in 0..<32 {
            if importSelection.exists && importSelection.isHittable { break }
            let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app
            scroll.swipeDown(velocity: .slow)
        }
        try require(importSelection.exists && importSelection.isHittable, "Expected the retained selected import")
        XCTAssertEqual(importSelection.value as? String, "1")
        try openHistoryComparison()
        try tapVisible(importSelection, tapping: false, maximumSwipes: 32)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false, maximumSwipes: 32)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testConfirmSelectedHistoryImport() throws {
        try openHistoryComparison()
        try confirmSelectedHistoryImport()
    }

    func testPrepareSelectedHistoryImport() throws {
        try openHistoryComparison()
        try selectHistoryImport()
    }

    func testPrepareStaleHistoryImport() throws {
        try openHistoryComparison()
        try tapVisible(importSelection, tapping: false, maximumSwipes: 32)
        try inspectResumeConflict(seconds: 75)
        try selectHistoryImport()
        XCTAssertTrue(app.buttons["Apply selected changes"].waitForExistence(timeout: 5))
    }

    func testRejectStaleHistoryImport() throws {
        XCTAssertEqual(app.buttons["tracker-history.apply"].label, "Apply 1 selected changes")
        let confirm = app.buttons["Apply selected changes"]
        XCTAssertTrue(confirm.exists && confirm.isHittable)
        confirm.tap()
        try testInspectRejectedHistoryImport()
    }

    func testInspectRejectedHistoryImport() throws {
        let row = try revealHistoryImportRow(status: "Not confirmed. Compare again before retrying.")
        XCTAssertTrue(row.staticTexts["Not confirmed. Compare again before retrying."].waitForExistence(timeout: 60))
        XCTAssertFalse(row.staticTexts["Confirmed on server"].exists)
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false, maximumSwipes: 32)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    func testConfirmFreshHistoryConflict() throws {
        try openHistoryComparison()
        try confirmFreshHistoryConflict()
    }

    func testRetryFreshHistoryConflict() throws {
        try retryHistoryComparison()
        try confirmFreshHistoryConflict()
    }

    private func retryHistoryComparison() throws {
        let unreachable = app.staticTexts[
            "Can’t reach the server. Check that it’s online and on the same network."
        ].exists
        let rateLimited = app.staticTexts[
            "The service is asking us to slow down. Try again in a moment."
        ].exists
        XCTAssertTrue(unreachable || rateLimited)
        try refreshHistoryComparison()
    }

    private func refreshHistoryComparison() throws {
        try tapVisible(app.buttons["Compare again"])
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_USER"])
        try require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", user))
            .firstMatch.waitForExistence(timeout: 60), "Expected a new complete comparison after retry")
    }

    private func confirmFreshHistoryConflict() throws {
        try tapVisible(importSelection, tapping: false, maximumSwipes: 32)
        let expected = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_EXPECTED_RESUME_SECONDS"] ?? "90"
        ))
        try inspectResumeConflict(seconds: expected)
        try confirmSelectedHistoryImport()
    }

    private func inspectResumeConflict(seconds: Double) throws {
        let selection = importSelection
        let rows = app.cells.containing(NSPredicate(
            format: "identifier == %@ AND label == %@", selection.identifier, selection.label
        ))
        try require(rows.count == 1, "Expected the exact selected history action")
        let row = rows.element
        XCTAssertTrue(row.staticTexts[
            "Server resume: \(seconds.formatted(.number.precision(.fractionLength(0)))) seconds"
        ].exists)
        XCTAssertTrue(
            row.staticTexts["Different from server — selecting replaces its current state"].exists
                || row.staticTexts["Tracker records disagree — select only one change for this title"].exists
        )
    }

    private func confirmSelectedHistoryImport() throws {
        try selectHistoryImport()
        let confirm = app.buttons["Apply selected changes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        try testInspectConfirmedHistoryImport()
    }

    func testInspectConfirmedHistoryImport() throws {
        let row = try revealHistoryImportRow(status: "Confirmed on server")
        XCTAssertTrue(row.staticTexts["Confirmed on server"].waitForExistence(timeout: 60))
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false, maximumSwipes: 32)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    private func revealHistoryImportRow(status: String) throws -> XCUIElement {
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: app.buttons["Compare again"]
        )
        try require(XCTWaiter.wait(for: [finished], timeout: 75) == .completed,
                    "Expected import verification to finish before locating its resized result row")
        let rows = try historyImportRows(status: status)
        for _ in 0..<32 {
            if rows.firstMatch.exists && rows.firstMatch.isHittable { break }
            let scroll = app.collectionViews.allElementsBoundByIndex.last ?? app
            scroll.swipeDown(velocity: .slow)
        }
        try require(rows.count == 1 && rows.firstMatch.isHittable, "Expected the exact selected import row")
        return rows.firstMatch
    }

    func testImportedHistoryMatchesAfterRelaunch() throws {
        try openHistoryComparison()
        let rows = try historyImportRows(status: "Already matches — no change")
        try tapVisible(rows.firstMatch, tapping: false, maximumSwipes: 32)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.staticTexts["Already matches — no change"].exists)
        XCTAssertFalse(importSelection.exists)
        try tapVisible(app.buttons["tracker-history.apply"], tapping: false, maximumSwipes: 32)
        XCTAssertFalse(app.buttons["tracker-history.apply"].isEnabled)
    }

    private func historyImportRows(status: String) throws -> XCUIElementQuery {
        let environment = ProcessInfo.processInfo.environment
        let episodeTitle = environment["PLOZZ_TRACKER_HISTORY_EPISODE_TITLE"] ?? ""
        let title = try XCTUnwrap(
            episodeTitle.isEmpty ? environment["PLOZZ_TRACKER_HISTORY_TITLE"] : episodeTitle
        )
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_IMPORT_USER"])
        return app.cells.containing(.staticText, identifier: title)
            .containing(NSPredicate(format: "label ENDSWITH %@", " · \(user)"))
            .containing(.staticText, identifier: status)
    }

    private var importSelection: XCUIElement {
        let environment = ProcessInfo.processInfo.environment
        let accountID = environment["PLOZZ_TRACKER_IMPORT_ACCOUNT"] ?? "missing-import-account"
        let itemID = environment["PLOZZ_TRACKER_IMPORT_ITEM"] ?? "missing-import-item"
        var matches = app.switches.matching(NSPredicate(
            format: "identifier == %@", "tracker-history.select.\(accountID):\(itemID)"
        ))
        switch environment["PLOZZ_TRACKER_IMPORT_ACTION"] {
        case "watched":
            matches = matches.matching(NSPredicate(format: "label == %@", "Mark watched"))
        case "resume":
            matches = matches.matching(NSPredicate(format: "label BEGINSWITH %@", "Set resume to "))
        default:
            break
        }
        return matches.element
    }

    private func openHistoryComparison(relaunch: Bool = true) throws {
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_USER"])
        let item = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ITEM"])
        let account = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_IMPORT_ACCOUNT"])
        XCTAssertFalse(user.isEmpty || item.isEmpty || account.isEmpty)
        try openPublicMetaDBAccount(relaunch: relaunch)
        try tapVisible(app.buttons["publicmetadb.compare-history"])
        try require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", user))
            .firstMatch.waitForExistence(timeout: 60), "Expected the dedicated user's real comparison rows")
    }

    private func selectHistoryImport() throws {
        try tapVisible(importSelection, tapping: false, maximumSwipes: 32)
        XCTAssertEqual(importSelection.value as? String, "0")
        try tapVisible(importSelection.switches.firstMatch)
        XCTAssertEqual(importSelection.value as? String, "1")
        let apply = app.buttons["tracker-history.apply"]
        try tapVisible(apply, tapping: false, maximumSwipes: 32)
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

    func testRetrySelectedMovieSearch() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        try require(app.textFields["Search your libraries"].value as? String == title,
                    "Expected the exact failed source search")
        try require(app.staticTexts["Search unavailable"].exists
            && app.staticTexts["The service is asking us to slow down. Try again in a moment."].exists,
                    "Expected the retained rate-limited search")
        try tapVisible(app.buttons["Try Again"])
        try titleCard(matching: title).tap()
        try require(detailPlayButton.waitForExistence(timeout: 15), "Expected the recovered movie detail")
    }

    func testOpenSelectedSeries() throws {
        try openSelectedTitle()
    }

    private func openSelectedTitle() throws {
        try selectedTitleCard().tap()
        XCTAssertTrue(detailPlayButton.waitForExistence(timeout: 15))
    }

    private func selectedTitleCard() throws -> XCUIElement {
        let title = try searchForSelectedTitle()
        return try titleCard(matching: title)
    }

    private func titleCard(matching title: String) throws -> XCUIElement {
        let matches = app.buttons.containing(.staticText, identifier: title).matching(NSPredicate(
            format: "NOT (label MATCHES %@)", ".*, S[0-9]+ · E[0-9]+ · .*"
        ))
        try require(matches.firstMatch.waitForExistence(timeout: 30), "Expected the exact source title card")
        try require(matches.count == 1, "Expected one exact title card in the selected libraries")
        return matches.element
    }

    private func searchForSelectedTitle() throws -> String {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        let search = app.buttons["Search"].firstMatch
        let query = app.textFields["Search your libraries"]
        if preservesProcess {
            try openTabRoot(search, anchor: query)
        } else {
            app.terminate()
            app.launch()
            XCTAssertTrue(search.waitForExistence(timeout: 30))
            search.tap()
        }
        XCTAssertTrue(query.waitForExistence(timeout: 10))
        query.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            query.tap()
        }
        try require(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                    "Expected the search keyboard before entering the selected title")
        if preservesProcess, let previous = query.value as? String, previous != "Search your libraries" {
            query.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        query.typeText(title + "\n")
        return title
    }

    private func openTabRoot(_ tab: XCUIElement, anchor: XCUIElement) throws {
        try require(!app.popovers.firstMatch.exists, "Dismiss the pending confirmation before navigating")
        for _ in 0..<7 where !tab.isHittable {
            if app.switches["publicmetadb.ratings"].isHittable {
                try tapVisible(app.buttons["Done"])
            } else if app.buttons["Close"].firstMatch.isHittable {
                try tapVisible(app.buttons["Close"].firstMatch)
            } else if app.buttons["publicmetadb.open-title"].exists {
                try tapVisible(app.buttons["publicmetadb.open-title"])
            } else {
                try tapVisible(try XCTUnwrap(app.buttons.matching(identifier: "BackButton")
                    .allElementsBoundByIndex.first(where: \.isHittable)))
            }
        }
        try tapVisible(tab)
        for _ in 0..<7 where !anchor.isHittable {
            try tapVisible(try XCTUnwrap(app.buttons.matching(identifier: "BackButton")
                .allElementsBoundByIndex.first(where: \.isHittable)))
        }
        try require(anchor.isHittable, "Expected the actual tab root without relaunching the app")
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

    func testPlayMovieBelowResumeThreshold() async throws {
        let duration = try verifiedRuntime()
        let maximum = Int(floor(duration * 0.02)) - 1
        try require(maximum > 5, "Expected room below the resume threshold")
        try await seekAndPlay(
            fraction: 0, minimumElapsedSeconds: 1, maximumElapsedSeconds: maximum,
            playSeconds: min(27, maximum - 5)
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

    func testPlayMovieAboveResumeRange() async throws {
        let duration = try verifiedRuntime()
        try await seekAndPlay(
            fraction: 0.82, minimumElapsedSeconds: Int(duration * 0.8) + 1,
            maximumElapsedSeconds: Int(duration * 0.9) - 1
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
        let episode = try visibleSelectedEpisode()
        startedPlayback = true
        episode.tap()
        try require(app.buttons["Close player"].waitForExistence(timeout: 45), "Expected real episode playback")
    }

    private func visibleSelectedEpisode() throws -> XCUIElement {
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
        return episode.element
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
        fraction: Double, minimumElapsedSeconds: Int, maximumElapsedSeconds: Int? = nil,
        playSeconds: Int = 27
    ) async throws {
        try require(detailPlayButton.exists && detailPlayButton.isHittable, "Expected the exact movie detail")
        startedPlayback = true
        detailPlayButton.tap()
        try require(app.buttons["Close player"].waitForExistence(timeout: 45), "Expected real playback")
        try await seekActivePlayback(
            fraction: fraction, minimumElapsedSeconds: minimumElapsedSeconds,
            maximumElapsedSeconds: maximumElapsedSeconds, playSeconds: playSeconds
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
        if app.buttons["Play"].exists && app.buttons["Play"].isHittable { return }
        if !app.buttons["Pause"].exists || !app.buttons["Pause"].isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            let controls = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.app.buttons["Pause"].isHittable || self.app.buttons["Play"].isHittable
            }, object: app)
            try require(XCTWaiter.wait(for: [controls], timeout: 10) == .completed,
                        "Expected playback controls after revealing them")
        }
        if app.buttons["Play"].exists && app.buttons["Play"].isHittable { return }
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

    private func openPublicMetaDBAccount(relaunch: Bool = true) throws {
        try openSettings(relaunch: relaunch)
        try tapVisible(app.buttons["settings-category-trackers"])
        try tapVisible(app.buttons["publicmetadb.browse"])
    }

    private func openSettings(relaunch: Bool = true) throws {
        try require(!preservesProcess, "Use detail-only navigation for same-process cache checks")
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_USER"])
        let settings = app.buttons["Settings for \(user)"]
        if relaunch {
            app.terminate()
            app.launch()
        } else {
            try tapVisible(app.buttons["Home"].firstMatch)
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
    }

    private func dismissConfirmation() throws {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 1), cancel.isHittable {
            cancel.tap()
            return
        }
        let region = try XCTUnwrap(app.otherElements.matching(identifier: "PopoverDismissRegion")
            .allElementsBoundByIndex.last)
        let popover = app.popovers.firstMatch
        try require(region.exists && popover.exists, "Expected the native popup dismissal surface")
        let bounds = region.frame.intersection(app.frame)
        let popup = popover.frame.insetBy(dx: -8, dy: -8)
        // Nested iPad forms have their own backdrops; use the frontmost one outside the action.
        let offsets = [CGVector(dx: 0.1, dy: 0.5), CGVector(dx: 0.9, dy: 0.5),
                       CGVector(dx: 0.5, dy: 0.9), CGVector(dx: 0.5, dy: 0.1)]
        let point = try XCTUnwrap(offsets.map {
            CGPoint(x: bounds.minX + bounds.width * $0.dx, y: bounds.minY + bounds.height * $0.dy)
        }.first { bounds.contains($0) && !popup.contains($0) })
        region.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.x - region.frame.minX, dy: point.y - region.frame.minY
        )).tap()
    }

    private func tapVisible(_ target: XCUIElement, tapping: Bool = true, maximumSwipes: Int = 8) throws {
        _ = target.waitForExistence(timeout: 5)
        for _ in 0..<maximumSwipes {
            if target.exists && target.isHittable { break }
            var scroll = app.collectionViews.allElementsBoundByIndex.last
                ?? app.scrollViews.allElementsBoundByIndex.last ?? app
            let identifier = target.exists ? (target.identifier.isEmpty ? target.label : target.identifier) : ""
            if !identifier.isEmpty {
                let collection = app.collectionViews.containing(.any, identifier: identifier).firstMatch
                let container = app.scrollViews.containing(.any, identifier: identifier).firstMatch
                if collection.exists {
                    scroll = collection
                } else if container.exists {
                    scroll = container
                }
            }
            if target.exists && !target.frame.isEmpty && target.frame.midY < scroll.frame.midY {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
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
        guard app.state == .runningForeground else {
            let state = XCTAttachment(string: "Application state: \(app.state.rawValue)")
            state.name = "live-history-native-app-state"
            state.lifetime = .keepAlways
            add(state)
            return
        }
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
