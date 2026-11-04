import CoreImage
import XCTest

#if os(tvOS)
@MainActor
final class PublicMetaDBLiveTVTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
    private var authorizedLiveRun = false
    private var startedPlayback = false

    override func setUp() async throws {
        try await MainActor.run {
            continueAfterFailure = false
            let environment = ProcessInfo.processInfo.environment
            XCTAssertEqual(environment["PLOZZ_TRACKER_TV_LIVE"], "1")
            let simulator = try XCTUnwrap(environment["PLOZZ_TRACKER_TV_SIMULATOR"])
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
            if app.state == .runningForeground {
                let state = XCTAttachment(string: app.debugDescription)
                state.name = "live-tv-native-state"
                state.lifetime = .keepAlways
                add(state)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "live-tv-native-screen"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            if startedPlayback { app.terminate() }
        }
    }

    func testInspectLiveTVApp() {
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testPrepareSelectedNFSShowShare() throws {
        let (url, name) = try selectedNFSShowShare()
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettingsCategory("servers", in: app)
        XCTAssertTrue(app.buttons["Add Server"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
        try PublicMetaDBLiveNavigation.select(app.buttons["Add Server"], moving: .down)
        XCTAssertTrue(app.buttons["Media Share"].waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(app.buttons["Media Share"], moving: .down)
        try PublicMetaDBLiveNavigation.select(app.buttons["Enter an address manually"], moving: .down)
        try PublicMetaDBLiveNavigation.select(
            app.buttons.containing(.staticText, identifier: "SMB").firstMatch, moving: .up
        )
        try PublicMetaDBLiveNavigation.select(
            app.cells.containing(.any, identifier: "NFS").firstMatch, moving: .down
        )
        XCTAssertEqual(app.secureTextFields.count, 0)
        try enterNonsecretText(try XCTUnwrap(url.string),
                              into: app.textFields["e.g. 192.168.1.100 or mynas.local"])
        try PublicMetaDBLiveNavigation.select(app.buttons["Connect"], moving: .down)
        XCTAssertTrue(app.staticTexts[url.path].waitForExistence(timeout: 45))
        try enterNonsecretText(name, into: app.textFields["e.g. Family Movies"], moving: .up)
        try PublicMetaDBLiveNavigation.select(
            app.buttons.containing(.staticText, identifier: "Mixed (Automatic)").firstMatch, moving: .down
        )
        try PublicMetaDBLiveNavigation.select(
            app.cells.containing(.any, identifier: "TV Shows").firstMatch, moving: .down
        )
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "TV Shows").firstMatch.exists)
        XCTAssertTrue(app.buttons["Use This Folder"].exists)
        XCTAssertEqual(app.textFields["e.g. Family Movies"].value as? String, name)
    }

    func testConfirmSelectedNFSShowShare() throws {
        let (url, name) = try selectedNFSShowShare()
        XCTAssertTrue(app.staticTexts[url.path].exists)
        XCTAssertEqual(app.textFields["e.g. Family Movies"].value as? String, name)
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "TV Shows").firstMatch.exists)
        try PublicMetaDBLiveNavigation.select(app.buttons["Use This Folder"], moving: .down)
        XCTAssertTrue(app.buttons["Add Server"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch.waitForExistence(timeout: 30))
    }

    func testInspectShareSourceSettings() throws {
        let (_, name) = try selectedNFSShowShare()
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettingsCategory("myLibraries", in: app)
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "NFS, \(name), ")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertTrue(source.isEnabled)
    }

    func testDisableCrossServerWatchSync() throws {
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettingsCategory("integrations", in: app)
        let control = app.switches["Sync across servers"]
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        XCTAssertTrue(["0", "1"].contains(try XCTUnwrap(control.value as? String)))
        if control.value as? String == "1" {
            try PublicMetaDBLiveNavigation.select(control, moving: .down)
        }
        XCTAssertEqual(control.value as? String, "0")
    }

    func testSelectOnlyNFSShowShare() throws {
        let (_, name) = try selectedNFSShowShare()
        try testInspectShareSourceSettings()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*, (On|Off)")).count, 2)
        XCTAssertTrue(app.buttons["NFS, \(name), On"].exists)
        let otherSource = app.buttons["CubeBoi, On"]
        if otherSource.exists {
            try PublicMetaDBLiveNavigation.select(otherSource, moving: .down)
        }
        XCTAssertTrue(app.buttons["CubeBoi, Off"].waitForExistence(timeout: 10))
        assertOnlyNFSShowShareSelected(name: name)
    }

    private func assertOnlyNFSShowShareSelected(name: String) {
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".*, (On|Off)")).count, 2)
        XCTAssertTrue(app.buttons["CubeBoi, Off"].exists)
        XCTAssertTrue(app.buttons["NFS, \(name), On"].exists)
        XCTAssertTrue(app.buttons[name].isSelected)
    }

    func testRestoreSourcesAfterNFSShowShare() throws {
        let (_, name) = try selectedNFSShowShare()
        try testInspectShareSourceSettings()
        assertOnlyNFSShowShareSelected(name: name)
        try PublicMetaDBLiveNavigation.select(app.buttons["CubeBoi, Off"], moving: .down)
        XCTAssertTrue(app.buttons["CubeBoi, On"].waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(app.buttons["NFS, \(name), On"], moving: .down)
        XCTAssertTrue(app.buttons["NFS, \(name), Off"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["CubeBoi, On"].exists)
    }

    func testOpenSelectedNFSShow() throws {
        _ = try selectedNFSShowShare()
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        XCTAssertFalse(title.isEmpty)
        let card = try selectedTitleCard(title: title)
        try PublicMetaDBLiveNavigation.select(card, moving: .down)
        XCTAssertTrue(app.staticTexts["Season 1"].waitForExistence(timeout: 30))
    }

    func testInspectSelectedNFSSeasonUnwatched() throws {
        let action = try openSelectedNFSSeasonMenu(watched: false)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
        assertVisibleSeasonWatchState(false)
    }

    func testMarkSelectedNFSSeasonWatched() throws {
        let action = try openSelectedNFSSeasonMenu(watched: false)
        try PublicMetaDBLiveNavigation.select(action, moving: .down)
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
        assertVisibleSeasonWatchState(true)
    }

    func testInspectSelectedNFSSeasonWatched() throws {
        let action = try openSelectedNFSSeasonMenu(watched: true)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
        assertVisibleSeasonWatchState(true)
    }

    func testMarkSelectedNFSSeasonUnwatched() throws {
        let action = try openSelectedNFSSeasonMenu(watched: true)
        try PublicMetaDBLiveNavigation.select(action, moving: .down)
        XCTAssertTrue(action.waitForNonExistence(timeout: 5))
        assertVisibleSeasonWatchState(false)
    }

    private func assertVisibleSeasonWatchState(_ watched: Bool) {
        let episodes = app.otherElements.matching(NSPredicate(
            format: "label MATCHES %@", "E[0-9]+ · .*, (Watched|Unwatched)"
        ))
        let suffix = watched ? ", Watched" : ", Unwatched"
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let visible = episodes.allElementsBoundByIndex
            return !visible.isEmpty && visible.allSatisfy { $0.label.hasSuffix(suffix) }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 30), .completed)
    }

    private func openSelectedNFSSeasonMenu(watched: Bool) throws -> XCUIElement {
        XCTAssertEqual(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"], "The Crown")
        let (_, name) = try selectedNFSShowShare()
        try testInspectShareSourceSettings()
        assertOnlyNFSShowShareSelected(name: name)
        try testOpenSelectedNFSShow()
        let episode = app.otherElements.matching(NSPredicate(
            format: "label MATCHES %@", "E[0-9]+ · .*, (Watched|Unwatched)"
        )).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            episode.exists && episode.isEnabled
                && episode.buttons.firstMatch.exists && episode.buttons.firstMatch.isEnabled
                && episode.buttons.firstMatch.frame.width > 0
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        try PublicMetaDBLiveNavigation.focus(episode, moving: .down, maximumPresses: 4)
        let seasons = (1...6).map {
            app.buttons.containing(.staticText, identifier: "Season \($0)").firstMatch
        }
        let active = try XCTUnwrap(seasons.first { $0.exists && $0.isEnabled })
        try PublicMetaDBLiveNavigation.focus(active, moving: .up, maximumPresses: 4)
        let season = app.buttons.containing(.staticText, identifier: "Season 1").firstMatch
        try PublicMetaDBLiveNavigation.focus(season, moving: .left, maximumPresses: 6)
        XCUIRemote.shared.press(.select, forDuration: 1)
        let label = watched ? "Mark Season Unwatched" : "Mark Season Watched"
        let otherLabel = watched ? "Mark Season Watched" : "Mark Season Unwatched"
        let action = app.cells.containing(.any, identifier: label).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.containing(.any, identifier: otherLabel).firstMatch.exists)
        return action
    }

    private func selectedNFSShowShare() throws -> (URLComponents, String) {
        let environment = ProcessInfo.processInfo.environment
        let rawURL = try XCTUnwrap(environment["PLOZZ_TRACKER_SHARE_URL"])
        let url = try XCTUnwrap(URLComponents(string: rawURL))
        let name = try XCTUnwrap(environment["PLOZZ_TRACKER_SHARE_NAME"])
        XCTAssertEqual(environment["PLOZZ_TRACKER_SHARE_CONTENT"], "TV Shows")
        XCTAssertEqual(url.scheme, "nfs")
        XCTAssertNotNil(url.host)
        XCTAssertGreaterThanOrEqual(url.path.split(separator: "/").count, 3)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertFalse(name.isEmpty)
        return (url, name)
    }

    func testCancelServerAddressEntry() throws {
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.textFields["Server address"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["Emby"].waitForExistence(timeout: 10))
    }

    func testPasswordlessEmbyOnboarding() throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try XCTUnwrap(environment["PLOZZ_TRACKER_TV_SERVER"])
        let user = try XCTUnwrap(environment["PLOZZ_TRACKER_TV_USER"])
        let url = try XCTUnwrap(URLComponents(string: address))
        XCTAssertTrue(["http", "https"].contains(url.scheme ?? ""))
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.query)
        XCTAssertFalse(user.isEmpty)

        if app.buttons["Don't Share"].waitForExistence(timeout: 3) {
            try PublicMetaDBLiveNavigation.select(app.buttons["Don't Share"], moving: .right)
        }
        XCTAssertTrue(app.buttons["Emby"].waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(app.buttons["Emby"], moving: .down)
        let server = app.textFields["Server address"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(server, moving: .down)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.count, 1)
        app.textFields.firstMatch.typeText(address)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(server.value as? String, address)
        try PublicMetaDBLiveNavigation.select(app.buttons["Connect"], moving: .down)

        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 45))
        try PublicMetaDBLiveNavigation.select(username, moving: .down)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.count, 1)
        app.textFields.firstMatch.typeText(user)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(username.value as? String, user)
        try PublicMetaDBLiveNavigation.focus(app.buttons["Back"], moving: .down)
        try PublicMetaDBLiveNavigation.select(app.buttons["Sign In"], moving: .right)
        XCTAssertTrue(username.waitForNonExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Choose your libraries"].waitForExistence(timeout: 45))
    }

    func testFinishOnboarding() throws {
        XCTAssertTrue(app.staticTexts["Choose your libraries"].exists)
        XCTAssertEqual(app.switches["Movies"].value as? String, "1")
        XCTAssertEqual(app.switches["TV shows"].value as? String, "1")
        try PublicMetaDBLiveNavigation.select(app.buttons["Continue"], moving: .down)
        XCTAssertTrue(app.buttons["Looks good"].waitForExistence(timeout: 15))
        let user = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TV_USER"])
        XCTAssertTrue(app.staticTexts[user].exists)
        try PublicMetaDBLiveNavigation.select(app.buttons["Looks good"], moving: .right)
        XCTAssertTrue(app.staticTexts["Requests as"].waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(app.buttons["Not Now"], moving: .down)
        for heading in [
            "Choose theme for this profile",
            "Choose navigation for this profile",
            "Choose Home layout for this profile",
        ] {
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 10))
            try PublicMetaDBLiveNavigation.select(app.buttons["Continue"], moving: .down)
            XCTAssertTrue(app.staticTexts[heading].waitForNonExistence(timeout: 10))
        }
        XCTAssertFalse(app.buttons["Set up from another device"].exists)
    }

    func testOpenPublicMetaDBSettings() throws {
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        XCTAssertEqual(app.buttons["publicmetadb.pair"].label, "Enter API key")
        XCTAssertFalse(app.buttons["publicmetadb.browse"].exists)
    }

    func testConnectWithRealBrowserQR() throws {
        try testOpenPublicMetaDBSettings()
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.pair"], moving: .down)
        let codeLabel = app.staticTexts["publicmetadb.pair.code"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 50))
        let code = codeLabel.label.replacingOccurrences(of: " ", with: "")
        XCTAssertNotNil(code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression))
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let payloads = detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(payloads.count, 1)
        let url = try XCTUnwrap(payloads.first)
        let components = try XCTUnwrap(URLComponents(string: url))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "plozz.app")
        XCTAssertEqual(components.path, "/publicmetadb")
        let fragment = try XCTUnwrap(components.fragment)
        let parameters = try XCTUnwrap(URLComponents(string: "https://plozz.app/?" + fragment)?.queryItems)
        XCTAssertEqual(parameters.first(where: { $0.name == "code" })?.value, code)
        XCTAssertNotNil(parameters.first(where: { $0.name == "key" })?.value)
        let handoff = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_CONNECTION_HANDOFF"])
        XCTAssertTrue(handoff.hasPrefix("/") && handoff.hasSuffix("/browser-request.json"))
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url, "code": code, "decodedProductionQR": true,
        ])
        try data.write(to: URL(fileURLWithPath: handoff), options: .withoutOverwriting)
        try assertConnected()
        XCTAssertFalse(app.secureTextFields["publicmetadb.key"].exists)
    }

    func testSavedConnectionAfterRelaunch() throws {
        if app.buttons["Don't Share"].waitForExistence(timeout: 3) {
            try PublicMetaDBLiveNavigation.select(app.buttons["Don't Share"], moving: .right)
        }
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try assertConnected()
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try assertConnected()
    }

    func testReadActualAccountLists() throws {
        try assertConnected()
        try PublicMetaDBLiveNavigation.focus(app.buttons["settings-workspace-back"], moving: .up)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.browse"], moving: .down)
        try PublicMetaDBLiveNavigation.select(app.buttons["Lists"], moving: .down)
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_TEST_LIST_NAME"])
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Page 1 of 1"].exists)
        XCTAssertFalse(app.staticTexts["No records"].exists)
    }

    func testConnectionAndRatingPreferenceAfterRelaunch() throws {
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try assertConnected()
        try PublicMetaDBLiveNavigation.focus(app.buttons["settings-workspace-back"], moving: .up)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.browse"], moving: .down)
        let preference = app.switches["publicmetadb.ratings"]
        XCTAssertTrue(preference.waitForExistence(timeout: 10))
        XCTAssertEqual(preference.value as? String, "0")
    }

    func testEnablePlaybackReporting() throws {
        try openPlaybackReporting()
        XCTAssertTrue(app.buttons["publicmetadb.playback.enable"].exists)
        XCTAssertFalse(app.buttons["publicmetadb.playback.disable"].exists)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.playback.enable"], moving: .down)
        let confirm = app.sheets.buttons.matching(identifier: "Enable reporting").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        try PublicMetaDBLiveNavigation.select(confirm, moving: .right)
        XCTAssertTrue(app.staticTexts["Playback reporting enabled"].waitForExistence(timeout: 10))
    }

    func testPlaybackReportingIsDisabled() throws {
        try openPlaybackReporting()
        XCTAssertTrue(app.buttons["publicmetadb.playback.enable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["publicmetadb.playback.disable"].exists)
    }

    func testDisablePlaybackReporting() throws {
        try openPlaybackReporting()
        XCTAssertTrue(app.staticTexts["Playback reporting enabled"].exists)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.playback.disable"], moving: .down)
        XCTAssertTrue(app.buttons["publicmetadb.playback.enable"].waitForExistence(timeout: 10))
    }

    func testOpenSelectedMovie() throws {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_TITLE"])
        XCTAssertFalse(title.isEmpty)
        let card = try selectedTitleCard(title: title)
        try PublicMetaDBLiveNavigation.select(card, moving: .down)
        XCTAssertTrue(app.buttons.containing(.image, identifier: "play.fill").firstMatch.waitForExistence(timeout: 15))
    }

    func testPlaySelectedMovieToResume() async throws {
        let duration = try playbackRuntime()
        try await playSelectedMovie(
            targetElapsed: 30, minimumElapsed: Int(ceil(duration * 0.02)), maximumElapsed: Int(duration * 0.8)
        )
    }

    func testPlaySelectedMovieToCompletion() async throws {
        let duration = try playbackRuntime()
        try await playSelectedMovie(
            targetElapsed: Int(duration * 0.95),
            minimumElapsed: Int(ceil(duration * 0.9)), maximumElapsed: Int(ceil(duration))
        )
    }

    private func playbackRuntime() throws -> Double {
        let duration = try XCTUnwrap(Double(
            ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_RUNTIME_SECONDS"] ?? ""
        ))
        try requirePlayback(duration.isFinite && (100...86_400).contains(duration), "Expected a verified runtime")
        return duration
    }

    private func playSelectedMovie(targetElapsed: Int, minimumElapsed: Int, maximumElapsed: Int) async throws {
        try requirePlayback((1...240).contains(targetElapsed), "Expected bounded playback")
        let play = app.buttons["detail-hero-play"]
        try requirePlayback(play.exists, "Expected the selected movie's real play control")
        startedPlayback = true
        try PublicMetaDBLiveNavigation.select(play, moving: .down)
        try await Task.sleep(for: .seconds(2))
        XCUIRemote.shared.press(.playPause)
        let clock = app.staticTexts["player-timeline-current-time"]
        try requirePlayback(clock.waitForExistence(timeout: 10), "Expected the real player timeline")
        let initialElapsed = try playbackSeconds(clock)
        try requirePlayback(initialElapsed < targetElapsed, "Expected playback below the target before continuing")
        XCUIRemote.shared.press(.playPause)
        try await Task.sleep(for: .seconds(targetElapsed - initialElapsed))
        XCUIRemote.shared.press(.playPause)
        let elapsed = try playbackSeconds(clock)
        try requirePlayback(
            (minimumElapsed...maximumElapsed).contains(elapsed),
            "Expected playback in \(minimumElapsed)...\(maximumElapsed), observed \(elapsed)"
        )
        let state = XCTAttachment(string: app.debugDescription)
        state.name = "verified-real-tv-playback-position"
        state.lifetime = .keepAlways
        add(state)
        XCUIRemote.shared.press(.menu)
        try await Task.sleep(for: .milliseconds(500))
        XCUIRemote.shared.press(.menu)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            play.hasFocus && !clock.exists
        }, object: app)
        try requirePlayback(XCTWaiter.wait(for: [returned], timeout: 10) == .completed, "Expected return to movie detail")
        startedPlayback = false
    }

    private func playbackSeconds(_ clock: XCUIElement) throws -> Int {
        try requirePlayback(clock.label == "Elapsed time", "Expected elapsed time, not wall-clock time")
        let value = try XCTUnwrap(clock.value as? String)
        let parts = try value.split(separator: ":").map { try XCTUnwrap(Int($0)) }
        try requirePlayback((2...3).contains(parts.count), "Expected a formatted playback position")
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private func requirePlayback(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PlaybackFailure.precondition(message) }
    }

    private enum PlaybackFailure: Error {
        case precondition(String)
    }

    func testReadRealSeasonRatings() throws {
        let evidence = try openSelectedSeasonRatings()
        for episode in evidence.episodes.sorted(by: { $0.episode < $1.episode }) {
            let row = app.buttons.matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", "Episode \(episode.episode)", "Episode \(episode.episode),"
            )).firstMatch
            try PublicMetaDBLiveNavigation.focus(row, moving: .down)
            for aggregate in episode.aggregates.values {
                let expected = "\(aggregate.label): \(aggregate.average.formatted()) / 100 (\(aggregate.count) ratings)"
                XCTAssertTrue(row.label.contains(expected) || row.staticTexts[expected].exists)
            }
        }
    }

    func testPrepareRealEpisodeRatings() throws {
        let evidence = try openSelectedSeasonRatings()
        XCTAssertTrue([3, 4].allSatisfy { number in evidence.episodes.contains { $0.episode == number } })
        try PublicMetaDBLiveNavigation.select(app.buttons["Rate multiple episodes"], moving: .down)
        let label = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_RATING_LABEL"])
        XCTAssertEqual(label, "PlozzAcceptance1121bcf0")
        try enterNonsecretText(label, into: app.textFields["Rating label"], replacing: "Overall")
        let fields = app.textFields.matching(identifier: "TMDB episode number")
        try enterNonsecretText("3", into: fields.firstMatch)
        try PublicMetaDBLiveNavigation.select(app.buttons["Add an episode"], moving: .down)
        XCTAssertEqual(fields.count, 2)
        let second = fields.matching(NSPredicate(format: "value != %@", "3")).firstMatch
        try enterNonsecretText("4", into: second)
        try PublicMetaDBLiveNavigation.select(app.buttons["Review ratings"], moving: .down)
        XCTAssertTrue(app.sheets.buttons["Publish ratings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Publish 2 “\(label)” ratings for TMDB season 1. A partial result is not a full success and will not be automatically retried."
        )).firstMatch.exists)
    }

    func testEpisodeRatingScoreMenu() throws {
        _ = try openSelectedSeasonRatings()
        try PublicMetaDBLiveNavigation.select(app.buttons["Rate multiple episodes"], moving: .down)
        let score = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "publicmetadb.episode-rating.score."
        )).firstMatch
        try verifyScoreMenu(score)
        XCTAssertFalse(app.sheets.buttons["Publish ratings"].exists)
    }

    func testSingleRatingScoreMenu() throws {
        try openSelectedTitleControls()
        try PublicMetaDBLiveNavigation.select(app.buttons["Community and personal ratings"], moving: .down)
        try PublicMetaDBLiveNavigation.select(app.buttons["Submit a rating"], moving: .down)
        try verifyScoreMenu(app.buttons["publicmetadb.rating.score"])
        XCTAssertFalse(app.sheets.buttons["Publish rating"].exists)
    }

    private func verifyScoreMenu(_ score: XCUIElement) throws {
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        XCTAssertEqual(score.value as? String, "50")
        for value in [0, 100, 50] {
            try PublicMetaDBLiveNavigation.select(score, moving: .down)
            let choice = app.cells.containing(.any, identifier: String(value)).firstMatch
            try PublicMetaDBLiveNavigation.select(choice, moving: .down, maximumPresses: 105)
            XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
            XCTAssertEqual(score.value as? String, String(value))
            XCTAssertTrue(score.staticTexts[String(value)].exists)
        }
    }

    func testCancelPreparedEpisodeRatings() throws {
        XCTAssertTrue(app.sheets.buttons["Publish ratings"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Review ratings"].isEnabled)
        XCTAssertFalse(app.staticTexts["All selected episode ratings were confirmed on PublicMetaDB"].exists)
    }

    func testConfirmPreparedEpisodeRatings() throws {
        let confirm = app.sheets.buttons["Publish ratings"].firstMatch
        XCTAssertTrue(confirm.exists)
        try PublicMetaDBLiveNavigation.select(confirm, moving: .right)
        XCTAssertTrue(app.staticTexts[
            "All selected episode ratings were confirmed on PublicMetaDB"
        ].waitForExistence(timeout: 45))
        XCTAssertFalse(app.buttons["Review ratings"].exists)
    }

    func testPrepareRealEpisodeRatingDeletion() throws {
        let evidence = try openSelectedSeasonRatings()
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_HISTORY_SELECTED_IDS"])
        let identifiers = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(Set(identifiers).count, 2)
        var ordered: [(episode: Int, id: String)] = []
        for identifier in identifiers {
            let episodes = evidence.episodes.filter { $0.ratings.contains { $0.id == identifier } }
            XCTAssertEqual(episodes.count, 1)
            let episode = try XCTUnwrap(episodes.first)
            XCTAssertTrue([3, 4].contains(episode.episode))
            let record = try XCTUnwrap(episode.ratings.first { $0.id == identifier })
            XCTAssertEqual(record.label, "PlozzAcceptance1121bcf0")
            XCTAssertEqual(record.score, 50)
            ordered.append((episode.episode, identifier))
        }
        try PublicMetaDBLiveNavigation.select(app.buttons["Delete selected episode ratings"], moving: .down)
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 45))
        for record in ordered.sorted(by: { $0.episode < $1.episode }) {
            let control = app.switches["publicmetadb.episode-rating.record.\(record.id)"]
            try PublicMetaDBLiveNavigation.focus(
                control, moving: .down, maximumPresses: evidence.episodes.reduce(4) { $0 + $1.ratings.count }
            )
            XCTAssertEqual(control.value as? String, "0")
            try PublicMetaDBLiveNavigation.select(control, moving: .down)
            XCTAssertEqual(control.value as? String, "1")
        }
        try PublicMetaDBLiveNavigation.select(
            app.buttons["Delete selected ratings"], moving: .down,
            maximumPresses: evidence.episodes.reduce(4) { $0 + $1.ratings.count }
        )
        XCTAssertTrue(app.sheets.buttons["Delete selected ratings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Requests removal of 2 exact contributions, not all ratings for the season. PublicMetaDB verifies ownership. Server ratings and history are unchanged."
        )).firstMatch.exists)
    }

    func testCancelPreparedEpisodeRatingDeletion() throws {
        XCTAssertTrue(app.sheets.buttons["Delete selected ratings"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["All selected ratings were confirmed removed"].exists)
    }

    func testConfirmPreparedEpisodeRatingDeletion() throws {
        let confirm = app.sheets.buttons["Delete selected ratings"].firstMatch
        XCTAssertTrue(confirm.exists)
        try PublicMetaDBLiveNavigation.select(confirm, moving: .up)
        XCTAssertTrue(app.staticTexts["All selected ratings were confirmed removed"].waitForExistence(timeout: 45))
    }

    private func openSelectedSeasonRatings() throws -> SeasonRatingEvidence {
        let encoded = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_TRACKER_SEASON_RATINGS_EVIDENCE"])
        let evidence = try JSONDecoder().decode(SeasonRatingEvidence.self, from: Data(encoded.utf8))
        XCTAssertEqual(evidence.tmdbID, 65494)
        XCTAssertEqual(evidence.season, 1)
        try openSelectedTitleControls()
        try PublicMetaDBLiveNavigation.select(app.buttons["Season ratings"], moving: .down)
        try enterNonsecretText("1", into: app.textFields["TMDB season number"])
        try PublicMetaDBLiveNavigation.select(app.buttons["Load season"], moving: .down)
        XCTAssertTrue(app.staticTexts[
            "Episodes shown have community ratings; this is not a complete episode list."
        ].waitForExistence(timeout: 45))
        return evidence
    }

    private func openSelectedTitleControls() throws {
        let card = try selectedTitleCard(title: "The Crown")
        try PublicMetaDBLiveNavigation.focus(card, moving: .down)
        XCUIRemote.shared.press(.select, forDuration: 1)
        let action = app.cells.containing(.any, identifier: "PublicMetaDB").firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(action, moving: .down)
        XCTAssertTrue(app.buttons["publicmetadb.open-title"].waitForExistence(timeout: 20))
    }

    private func selectedTitleCard(title: String) throws -> XCUIElement {
        app.terminate()
        app.launch()
        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        for _ in 0..<4 {
            if search.isEnabled { break }
            XCUIRemote.shared.press(.menu)
        }
        XCTAssertTrue(search.isEnabled)
        try PublicMetaDBLiveNavigation.select(search, moving: .up)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText(title)
        let cards = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (value MATCHES %@)", title, "S[0-9]+ · E[0-9]+ · .*"
        ))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(cards.count, 1)
        return cards.element
    }

    private func openPlaybackReporting() throws {
        app.terminate()
        app.launch()
        try PublicMetaDBLiveNavigation.openSettings(in: app)
        try assertConnected()
        try PublicMetaDBLiveNavigation.focus(app.buttons["settings-workspace-back"], moving: .up)
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.browse"], moving: .down)
        XCTAssertTrue(app.buttons["publicmetadb.playback"].waitForExistence(timeout: 10))
        try PublicMetaDBLiveNavigation.select(app.buttons["publicmetadb.playback"], moving: .down)
        XCTAssertTrue(app.staticTexts["Playback reporting"].waitForExistence(timeout: 10))
    }

    private func enterNonsecretText(
        _ value: String, into field: XCUIElement, replacing previous: String = "",
        moving direction: XCUIRemote.Button = .down
    ) throws {
        if !previous.isEmpty { XCTAssertEqual(field.value as? String, previous) }
        try PublicMetaDBLiveNavigation.select(field, moving: direction)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let editing = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Hold "))
        XCTAssertEqual(editing.count, 1)
        editing.element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, value)
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

    private func assertConnected() throws {
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 120))
        XCTAssertEqual(app.buttons["publicmetadb.pair"].label, "Replace API key")
        XCTAssertTrue(app.staticTexts["Connected"].exists)
    }
}
#endif
