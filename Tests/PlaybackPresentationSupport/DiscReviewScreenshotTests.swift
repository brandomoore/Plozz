import XCTest
#if os(iOS)
import UIKit
#endif

@MainActor
final class DiscReviewScreenshotTests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
        app.launchArguments = ["--disc-review-fixture", scenario]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Wait for native menu/rotation animation, then capture the screen rather
        // than cropping with an application's potentially stale rotated bounds.
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Disc review - \(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCaptureDiscNavigationAndActions() {
        let app = launch("menu")
        #if os(tvOS)
        XCTAssertTrue(app.buttons["disc-menu-select"].waitForExistence(timeout: 10))
        capture(app, "Navigation")
        XCUIRemote.shared.press(.menu)
        #else
        XCTAssertTrue(app.buttons["disc-menu-control-circle"].waitForExistence(timeout: 10))
        capture(app, "Navigation")
        app.buttons["disc-menu-control-opticaldisc"].tap()
        #endif
        XCTAssertTrue(app.buttons["Try another region"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "watched")).firstMatch.exists)
        #if os(iOS)
        XCTAssertTrue(app.collectionViews.buttons["Close player"].isHittable,
                      "All native menu actions must fit on screen")
        #endif
        capture(app, "Menu actions")
        activate(app.buttons["Disc videos"], in: app)
        let playlist = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 10), "Actions must dismiss before the picker opens")
        activate(app.buttons["Close"].firstMatch, in: app)
        #if os(tvOS)
        XCTAssertTrue(app.buttons["disc-menu-select"].waitForExistence(timeout: 5))
        focus(app.buttons["disc-menu-select"], in: app)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["disc-menu-control-opticaldisc"].tap()
        #endif
        XCTAssertTrue(app.buttons["Try another region"].waitForExistence(timeout: 5))
        #if os(tvOS)
        activate(app.buttons["Close"].firstMatch, in: app)
        #else
        activate(app.collectionViews.buttons["Close player"], in: app)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["Try another region"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        #endif
    }

    func testCaptureMenuFailure() {
        let app = launch("failure")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        capture(app, "Menu unavailable")
    }

    func testCaptureMenuLoading() {
        let app = launch("loading")
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 10))
        capture(app, "Loading")
    }

    func testCaptureVideoPicker() {
        let app = launch("videos")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("2:00:00 \u{00B7} 18 chapters"),
                      "Duration and chapter count should form one compact metadata line")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "watched")).firstMatch.exists)
        #if os(tvOS)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        for id in ["00800", "00801", "00012"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist \(id)"))
                .firstMatch.isHittable)
        }
        #endif
        capture(app, "Disc videos")
        activate(app.buttons["Close"].firstMatch, in: app)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
    }

    func testCaptureAudioNotice() {
        let app = launch("notice")
        XCTAssertTrue(app.staticTexts["The disc's selected audio track is unavailable."]
            .waitForExistence(timeout: 10))
        capture(app, "Shared audio toast")
    }

    func testCaptureTransportAction() {
        let app = launch("transport")
        #if os(tvOS)
        XCUIRemote.shared.press(.playPause)
        let more = app.buttons["player-control-ellipsis"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.up)
        focus(more, in: app)
        XCUIRemote.shared.press(.select)
        let button = app.buttons["Disc videos"]
        #else
        let options = app.buttons[app.frame.width > app.frame.height ? "player-settings" : "player-playback-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        let button = app.buttons["Disc videos"]
        #endif
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        capture(app, "Player disc action")
    }

    private func detail(_ scenario: String, _ title: String) {
        let app = launch(scenario)
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        capture(app, "Detail hero")
        #if os(tvOS)
        focus(play, in: app)
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        #else
        play.press(forDuration: 1.2)
        #endif
        let expected = scenario == "detail-unavailable" ? "This disc's menu format is not supported."
            : scenario == "detail-menu-default" ? "Play video" : "Open disc menu"
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", expected))
            .firstMatch.waitForExistence(timeout: 5))
        capture(app, title)
    }

    func testCaptureDetailMenuAlternative() { detail("detail-video-default", "Play menu - open disc menu") }
    func testCaptureDetailVideoAlternative() { detail("detail-menu-default", "Play menu - play video") }
    func testCaptureUnsupportedMenuExplanation() { detail("detail-unavailable", "Play menu - unsupported Java") }

    #if os(iOS)
    func testResumePromptStaysBesidePlayButton() {
        verifyResumePrompt(scenario: "detail-resume", playIdentifier: "detail-hero-play")
    }

    func testHomeResumePromptStaysBesidePlayButton() {
        verifyResumePrompt(scenario: "detail-home-resume", playIdentifier: "home-hero-play")
    }

    private func verifyResumePrompt(scenario: String, playIdentifier: String) {
        let app = launch(scenario)
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == orientation.isLandscape
                },
                object: app
            )
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            let play = app.buttons[playIdentifier]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            if !play.isHittable { app.swipeUp() }
            let playFrame = play.frame
            play.tap()
            let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume")).firstMatch
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            let restart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Over")).firstMatch
            XCTAssertTrue(restart.exists)
            XCTAssertLessThan(abs(resume.frame.midY - playFrame.midY), 320,
                              "Resume choices must remain near the Play button.")
            capture(app, "Resume prompt \(orientation == .portrait ? "portrait" : "landscape")")
            restart.tap()
            XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
        }
    }
    #endif

    func testCapturePlaybackSetting() {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--read-ahead-settings-fixture", "--playback-settings-workspace"]
        #else
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--playback-settings-fixture", "--share-only-playback"]
        #endif
        app.launch()
        defer { app.terminate() }
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Disc playback")).firstMatch
        let notice = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "HDMV menus only. BD-J plays video.\nVideos played from disc menus don't update watch progress."
        )).firstMatch
        #if os(iOS)
        let contentTop = app.navigationBars.firstMatch.frame.maxY + 24
        let visibleFrame = CGRect(x: app.frame.minX, y: contentTop,
                                  width: app.frame.width, height: app.frame.maxY - contentTop - 24)
        for _ in 0..<20 {
            if picker.exists && picker.isHittable && notice.exists && notice.isHittable
                && visibleFrame.contains(picker.frame.union(notice.frame)) { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(visibleFrame.contains(picker.frame.union(notice.frame)),
                      "The setting and complete note must be visible below the navigation bar")
        #endif
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        #if os(tvOS)
        focus(picker, in: app)
        XCTAssertEqual(picker.value as? String, "Play video")
        XCTAssertFalse(app.segmentedControls.containing(.button, identifier: "Play video").firstMatch.exists)
        #endif
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        capture(app, "Playback setting")
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #else
        picker.tap()
        #endif
        let openMenu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Open disc menu")).firstMatch
        XCTAssertTrue(openMenu.waitForExistence(timeout: 5))
        capture(app, "Playback setting choices")
        #if os(tvOS)
        focus(openMenu, in: app)
        XCUIRemote.shared.press(.select)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Open disc menu"), object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        focus(picker, in: app)
        XCUIRemote.shared.press(.select)
        focus(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Play video")).firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(picker.value as? String, "Play video")
        #endif
    }

    private func activate(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        #if os(tvOS)
        focus(button, in: app)
        XCUIRemote.shared.press(.select)
        #else
        button.tap()
        #endif
    }

    #if os(tvOS)
    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            if target.hasFocus || target.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists { return }
            let current = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if current.exists, current.elementType == .cell, current.frame.contains(target.frame) { return }
            let direction: XCUIRemote.Button
            if !current.exists { direction = .down }
            else if target.frame.minX > current.frame.maxX { direction = .right }
            else if target.frame.maxX < current.frame.minX { direction = .left }
            else { direction = target.frame.midY < current.frame.midY ? .up : .down }
            XCUIRemote.shared.press(direction)
        }
        XCTFail("Could not focus \(target.label)")
    }
    #endif
}

@MainActor final class AtlasUI: XCTestCase {
    #if os(tvOS)
    let app = XCUIApplication(bundleIdentifier:"com.thatcube.Plozz.FocusHost")
    #else
    let app = XCUIApplication(bundleIdentifier:"com.thatcube.Plozz.PresentationHost")
    #endif
    func start(_ mode:String, _ args:[String] = []) {
        continueAfterFailure = false
        app.launchArguments = ["--disc-review-fixture","detail-atlas","-AtlasPage",mode,"-AppleLanguages","(en)","-AppleLocale","en_US"]+args
        app.launch()
    }
    func el(_ id:String)->XCUIElement { app.descendants(matching:.any).matching(identifier:id).firstMatch }
    func shot(_ name:String) {
        Thread.sleep(forTimeInterval:0.45)
        let a = XCTAttachment(data:XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier:"public.png"); a.name="atlas-"+name; a.lifetime = .keepAlways; add(a)
        let t=XCTAttachment(string:app.debugDescription); t.name="tree-"+name; t.lifetime = .keepAlways; add(t)
    }
    func go(_ e:XCUIElement) {
        XCTAssertTrue(e.waitForExistence(timeout:4),app.debugDescription)
        #if os(iOS)
        if !e.isHittable { app.swipeUp() }; if e.elementType == .switch && e.switches.firstMatch.exists { e.switches.firstMatch.tap() } else { e.tap() }
        #else
        for _ in 0..<8 where !e.hasFocus { XCUIRemote.shared.press(.down) }; if !e.hasFocus { for _ in 0..<8 where !e.hasFocus { XCUIRemote.shared.press(.up) } }; XCTAssertTrue(e.hasFocus,app.debugDescription); XCUIRemote.shared.press(.select)
        #endif
    }
    func testComparison() {
        start("comparison")
        let first=el("tracker-history.select.jellyfin:movie"), apply=el("tracker-history.apply")
        XCTAssertTrue(first.waitForExistence(timeout:8),app.debugDescription); shot("comparison-01-populated"); go(first); XCTAssertTrue(apply.isEnabled); shot("comparison-02-selected"); go(apply); XCTAssertTrue(app.buttons["Apply selected changes"].firstMatch.waitForExistence(timeout:5)); shot("comparison-03-confirmation"); app.terminate()
    }
    func testSync() {
        start("sync",["--history-ongoing-sync"]); let enabled=el("tracker-history.sync-enabled"); XCTAssertTrue(enabled.waitForExistence(timeout:6)); shot("ongoing-sync-off"); go(enabled)
        let confirm = app.buttons["Enable beta sync"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); shot("ongoing-sync-beta-consent"); go(confirm)
        XCTAssertTrue(el("tracker-history.sync-watched").waitForExistence(timeout:8)); shot("ongoing-sync-on"); app.terminate()
    }
}

extension AtlasUI {
    func act(_ text:String) -> XCUIElement {
        if text.hasPrefix("@") { return el(String(text.dropFirst())) }
        return app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@",text)).firstMatch
    }
    func expect(_ text:String) -> Bool {
        if text.hasPrefix("@") { return el(String(text.dropFirst())).waitForExistence(timeout:4) }
        return app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS[c] %@",text)).firstMatch.waitForExistence(timeout:4)
    }
    func frame(_ name:String,_ text:String) {
        if name.hasSuffix("-confirm") || name.hasSuffix("-consent") {
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout:4) || app.alerts.firstMatch.exists,app.debugDescription)
        } else { XCTAssertTrue(expect(text),app.debugDescription) }
        shot(name)
    }
    func next(_ text:String,_ name:String,_ visible:String) { go(act(text)); frame(name,visible) }
    func scenario(_ page:String,_ steps:[(String,String,String)]) {
        start(page)
        for (tap,name,marker) in steps {
            if tap.isEmpty { frame(name,marker) } else { next(tap,name,marker) }
        }
        app.terminate()
    }
    func testAccount() {
        start("connected", ["--history-ongoing-sync"])
        defer { app.terminate() }
        go(el("publicmetadb.browse"))
        XCTAssertTrue(el("publicmetadb.playback").waitForExistence(timeout: 5))
        XCTAssertTrue(el("tracker-history.ongoing-sync").exists)
        for id in ["publicmetadb.ratings", "publicmetadb.watchlist", "publicmetadb.compare-history",
                   "publicmetadb.export-history", "publicmetadb.history", "publicmetadb.history.bulk"] {
            XCTAssertFalse(el(id).exists, id)
        }
        for label in ["Lists", "Picks", "Choose a list", "Create a list", "Look up an external ID", "Dropped titles"] {
            XCTAssertFalse(app.buttons[label].exists, label)
        }
        shot("tracking-only-account")
        go(el("tracker-history.ongoing-sync"))
        XCTAssertTrue(el("tracker-history.sync-enabled").waitForExistence(timeout: 5))
    }
    func testDisconnect() { scenario("connected",[("","account-connected","Tracking settings"),("Disconnect","account-disconnect-confirm","Disconnect PublicMetaDB?")]) }
    func testReplace() { scenario("connected",[("Replace API key","account-replace-confirm","Replace this profile")]) }
    func testPairing() {
        #if os(tvOS)
        continueAfterFailure = false
        app.launchArguments = ["--publicmetadb-pairing-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        go(app.buttons["fixture.open-publicmetadb"])
        #else
        start("disconnected")
        #endif
        defer { app.terminate() }
        let entry = app.buttons["publicmetadb.pair"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "Connect PublicMetaDB")
        shot("account-disconnected")
        go(entry)

        let field = app.secureTextFields["publicmetadb.key"]
        let manual = app.buttons["publicmetadb.pair.manual"]
        XCTAssertTrue(app.buttons["publicmetadb.pair.cancel"].isEnabled)
        let code = app.staticTexts["publicmetadb.pair.code"]
        let website = app.staticTexts["plozz.app/pmdb"]
        let qr = app.images["QR code"]
        #if os(tvOS)
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        XCTAssertTrue(website.exists)
        XCTAssertTrue(qr.exists)
        XCTAssertTrue(manual.isEnabled && manual.wait(for: \.hasFocus, toEqual: true, timeout: 5))
        XCTAssertGreaterThanOrEqual(manual.frame.minY, qr.frame.maxY)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(field.exists)
        XCTAssertFalse(app.buttons["publicmetadb.connect"].exists)
        shot("pairing")
        go(manual)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(manual.exists || website.exists || code.exists || qr.exists || app.keyboards.firstMatch.exists)
        shot("manual-key-entry")
        #else
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(manual.exists)
        let section = app.cells.containing(.secureTextField, identifier: "publicmetadb.key").firstMatch
        XCTAssertEqual(section.buttons.allElementsBoundByIndex.map(\.identifier),
                       ["publicmetadb.connect", "publicmetadb.pair.cancel"])
        XCTAssertEqual(section.links.count, 0)
        XCTAssertFalse(code.exists)
        XCTAssertFalse(website.exists)
        XCTAssertFalse(qr.exists)
        shot("key-entry")
        #endif
        let connect = app.buttons["publicmetadb.connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled)
    }
    func testReport() { scenario("reporting",[("","reporting-off","Enable playback reporting"),("Enable playback reporting","reporting-consent","Enable reporting")]); scenario("reporting-on",[("","reporting-on","Stop reporting playback")]) }
    func testWatchlist() { scenario("watchlist",[("","watchlist-off","Choose a list"),("Choose a list","watchlist-picker","Weekend matinees"),("Weekend matinees","watchlist-private-consent","Use this list")]); scenario("watchlist-on",[("","watchlist-on","Stop syncing this list")]) }
    func testPublicConsent() { scenario("watchlist",[("Choose a list","watchlist-picker","Harbor lights"),("Harbor lights","watchlist-public-consent","Use this list")]) }
    func testDrop() { scenario("drop-record",[("","drop-show","Drop show"),("@publicmetadb.history.action","drop-show-confirm","Change this PublicMetaDB record?")]) }
    func testDate() { scenario("new-play",[("","add-play","Watch date unknown"),("@publicmetadb.history.review-date","add-play-confirm","Save play")]) }
    func testBulk() { scenario("bulk",[("","bulk-delete","@publicmetadb.history.select.harbor"),("@publicmetadb.history.select.harbor","bulk-selected","Review deletion"),("@publicmetadb.history.bulk.review","bulk-delete-confirm","Delete the selected")]) }
    func testListDelete() { scenario("list-detail",[("@publicmetadb.list.delete","list-delete-confirm","Delete this PublicMetaDB list?")]) }
    func testAddList() { scenario("add-to-list",[("","add-to-list","Weekend matinees"),("Weekend matinees","list-add-confirm","Add to list")]) }
    func testListForms() { scenario("create-list",[("","list-create","@publicmetadb.list.name")]); scenario("open-list",[("","public-list-open","Open list")]) }
    func testTitles() { scenario("movie",[("","movie-controls","The Last Lantern")]); scenario("show",[("","series-controls","The Mariner's Almanac")]); scenario("episode",[("","episode-controls","The Mariner's Almanac")]) }
    func testRatings() { scenario("ratings",[("","ratings","@publicmetadb.rating.record.score"),("@publicmetadb.rating.record.score","rating-record","Delete rating"),("Delete rating","rating-delete-confirm","Delete this rating?")]) }
    func testSubmitRating() { scenario("ratings",[("Submit a rating","rating-submit","@publicmetadb.rating.submit"),("@publicmetadb.rating.submit","rating-submit-confirm","Publish rating")]) }
    func testVote() { scenario("ratings",[("@publicmetadb.rating.record.score","rating-record","Vote on this contribution"),("Vote on this contribution","votes","upvotes"),("Upvote","vote-confirm","Confirm vote")]) }
    func testSeason() { scenario("season",[("","season-ratings","Rate multiple episodes"),("Rate multiple episodes","season-rating-editor","Add an episode")]); scenario("season",[("Delete selected episode ratings","season-rating-delete","@publicmetadb.episode-rating.record.pilot"),("@publicmetadb.episode-rating.record.pilot","season-rating-selected","Delete selected ratings"),("Delete selected ratings","season-rating-delete-confirm","Delete these exact ratings?")]) }
    func testMappings() { scenario("mappings",[("","external-ids","tt4082150"),("Submit an external ID","external-id-editor","Review mapping")]); scenario("lookup",[("","external-id-lookup","Look up ID")]) }
    func testAnime() { scenario("anime",[("","anime-mappings","Spring Tide"),("Publish or replace my mapping","anime-editor","Review replacement")]); scenario("anime",[("Delete my mapping for a logical season","anime-delete","Review season")]) }
    func testListening() { scenario("lastfm",[("","lastfm-listening-history","Eastbound Ferry")]) }
    func choose(_ id:String,_ label:String) {
        let p=el(id)
        go(p); go(app.buttons[label].firstMatch)
    }
    func export(_ provider:String) {
        let key=provider == "public" ? "publicmetadb.export":"tracker-export", route=provider+"-export"
        start(route,["--history-export","--history-"+route]); frame(route+"-setup","Server user")
        choose(key+".account","Lantern House · Mara"); choose(key+".library","Movies"); go(el(key+".preview"))
        frame(route+"-preview","The Last Lantern"); go(el(key+".select.movie")); frame(route+"-selected","Review 1 selected"); go(el(key+".apply")); frame(route+"-confirm","Export selected titles"); app.terminate()
    }
    func testPublicExport() { export("public") }
    func testTraktExport() { export("trakt") }
    func testSimklExport() { export("simkl") }
    func testWetrakrExport() { export("wetrakr") }
}

extension AtlasUI {
    func testAniListExport() { export("anilist") }
    func testMALExport() { export("mal") }
    func testOnboarding() {
        #if os(iOS)
        app.launchArguments=["--onboarding-page=welcome","-AppleLanguages","(en)","-AppleLocale","en_US"]; app.launch()
        #else
        start("onboarding")
        #endif
        frame("onboarding-provider-chooser","Free forever and open source."); app.terminate()
    }
    #if os(tvOS)
    func testTrackerHome() { scenario("trackers",[("","trackers","@settings-page-trakt")]) }
    func provider(_ id:String,_ marker:String) {scenario("trackers",[("@settings-page-"+id,"tracker-"+id,marker)])}
    private func checkTrackingAccount(_ id: String, supportsSync: Bool = true, serversOnly: Bool = false) {
        start("trackers", ["--history-ongoing-sync"] + (serversOnly ? ["--history-servers-only"] : []))
        defer { app.terminate() }
        go(el("settings-page-\(id)"))
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 5))
        XCTAssertFalse(el("\(id).compare-history").exists)
        XCTAssertFalse(el("\(id).export-history").exists)
        XCTAssertFalse(el("lastfm.history").exists)
        let sync = el("\(id == "mal" ? "myanimelist" : id).ongoing-sync")
        if supportsSync && !serversOnly {
            XCTAssertTrue(sync.waitForExistence(timeout: 5))
            shot("tracker-\(id)")
            go(sync)
            XCTAssertTrue(el("tracker-history.sync-enabled").waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(sync.exists)
            shot("tracker-\(id)" + (serversOnly ? "-servers-only" : ""))
        }
    }

    func testTrackerTrakt() {
        checkTrackingAccount("trakt")
        checkTrackingAccount("trakt", serversOnly: true)
    }
    func testTrackerSimkl() { checkTrackingAccount("simkl") }
    func testTrackerWetrakr() { checkTrackingAccount("wetrakr") }
    func testTrackerAni() { checkTrackingAccount("anilist") }
    func testTrackerMAL() { checkTrackingAccount("mal") }
    func testTrackerLast() { checkTrackingAccount("lastfm", supportsSync: false) }
    func testTrackerPub() {provider("publicmetadb","Tracking settings")}
    #endif
    func field(_ label:String,_ value:String) {
        let e=label.hasPrefix("@") ? el(String(label.dropFirst())) : app.textFields[label].firstMatch
        XCTAssertTrue(e.waitForExistence(timeout:4),app.debugDescription)
        #if os(iOS)
        if !e.isHittable { app.swipeUp() }; e.tap(); e.typeText(value)
        if app.keyboards.firstMatch.exists && app.buttons["Return"].exists { app.buttons["Return"].tap() }
        #else
        go(e); let k=app.keyboards.firstMatch; XCTAssertTrue(k.waitForExistence(timeout:3)); k.typeText(value); XCUIRemote.shared.press(.menu)
        #endif
    }
    func testCreateListReview() {
        start("create-list"); field("@publicmetadb.list.name","Lantern festival"); next("@publicmetadb.list.create","list-create-confirm","Create list"); app.terminate()
    }
    func testPublicListRead() {
        start("open-list"); field("PublicMetaDB list URL","https://publicmetadb.com/lists/u/theo/harbor-lights"); next("Open list","public-list-items","The Last Lantern"); app.terminate()
    }
    func testMappingReview() {
        start("mappings"); go(act("Submit an external ID")); field("@publicmetadb.mapping.value","tt4082150"); next("Review mapping","external-id-review","Existing mappings for this title"); next("Publish mapping","external-id-publish-confirm","Publish mapping");app.terminate()
    }
    func testLookupResults() {
        start("lookup"); field("External ID","tt4082150"); next("Look up ID","external-id-results","The Last Lantern"); app.terminate()
    }
    func testMappingRecord() { scenario("mappings",[("tt4082150","mapping-contribution","Delete contribution"),("Delete contribution","mapping-delete-confirm","Delete contribution")]) }
    func testSeasonPublish() {
        start("season"); go(act("Rate multiple episodes")); field("TMDB episode number","1"); next("Review ratings","season-publish-confirm","Publish ratings"); app.terminate()
    }
    func testAnimePublish() {
        start("anime"); go(act("Publish or replace my mapping")); field("Logical anime season (1 or greater)","1"); field("TMDB season (0 for specials)","1"); next("Review replacement","anime-review","Replace my mapping"); next("Replace my mapping","anime-replace-confirm","Publish replacement"); app.terminate()
    }
    func testAnimeRemove() {
        start("anime"); go(act("Delete my mapping for a logical season")); field("Logical anime season (1 or greater)","1"); next("Review season","anime-delete-review","Delete my mapping"); next("Delete my mapping","anime-delete-confirm","Delete my mapping");app.terminate()
    }
}
