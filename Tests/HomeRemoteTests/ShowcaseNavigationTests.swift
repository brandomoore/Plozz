import XCTest
import UIKit
import notify

@MainActor
final class ShowcaseNavigationTests: XCTestCase {
    func testDiscoverUsesCachedCardsBeforeTheLiveRequestFinishes() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        let notification = "com.thatcube.Plozz.HomeFixtureDiscover.\(UUID().uuidString)"
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--showcase-discover-fixture", "--cached-showcase-discover"
        ]
        app.launchEnvironment["PLOZZ_HOME_DISCOVER_RELEASE_NOTIFICATION"] = notification
        app.launch()
        defer { notify_post(notification); app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        XCTAssertTrue(app.staticTexts["Discover"].exists)
        XCUIRemote.shared.press(.down)
        waitForStableCard(in: app)
        let card = focusedCard(in: app)
        XCTAssertEqual(card.label, "Fixture movie 34", "The first Down must reach cached Discover without the network.")
        let before = card.frame
        XCTAssertEqual(notify_post(notification), UInt32(NOTIFY_STATUS_OK))
        let fresh = NSPredicate { _, _ in app.staticTexts["home-fixture-discover-state"].label == "ready" }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: fresh, object: nil)], timeout: 10
        ), .completed)
        waitForStableCard(in: app)
        XCTAssertEqual(focusedCard(in: app).label, card.label)
        XCTAssertEqual(focusedCard(in: app).frame.minY, before.minY, accuracy: 0.5)
    }

    func testDiscoverReservesItsHeadingBeforeAnUncachedRequestFinishes() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        let notification = "com.thatcube.Plozz.HomeFixtureDiscover.\(UUID().uuidString)"
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home", "--showcase-discover-fixture"
        ]
        app.launchEnvironment["PLOZZ_HOME_DISCOVER_RELEASE_NOTIFICATION"] = notification
        app.launch()
        defer { notify_post(notification); app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let heading = app.staticTexts["Discover"]
        XCTAssertTrue(heading.exists, "An uncached row reserves its slot instead of inserting after navigation begins.")
        let before = heading.frame
        let focus = focusedCard(in: app).label
        XCTAssertEqual(notify_post(notification), UInt32(NOTIFY_STATUS_OK))
        let ready = NSPredicate { _, _ in app.staticTexts["home-fixture-discover-state"].label == "ready" }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10
        ), .completed)
        waitForStableCard(in: app)
        XCTAssertEqual(heading.frame.minY, before.minY, accuracy: 0.5)
        XCTAssertEqual(focusedCard(in: app).label, focus)
    }

    func testLowerRowArrivalDoesNotMoveFocusOrTheContinueWatchingAnchor() throws {
        try checkUnrequestedRowArrival(showcase: true)
    }

    func testLowerRowArrivalDoesNotMoveFocusOrTheFullscreenHero() throws {
        try checkUnrequestedRowArrival(showcase: false)
    }

    func testLowerRowArrivalDoesNotMoveFocusOrTheClassicStartingRow() throws {
        try checkUnrequestedRowArrival(showcase: false, heroDisabled: true)
    }

    private func checkUnrequestedRowArrival(showcase: Bool, heroDisabled: Bool = false) throws {
        continueAfterFailure = false
        let fullscreen = !showcase && !heroDisabled
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        let resumeNotification = "com.thatcube.Plozz.HomeFixtureRows.\(UUID().uuidString)"
        let recentNotification = "com.thatcube.Plozz.HomeFixtureRecent.\(UUID().uuidString)"
        app.launchArguments = ["--production-home-fixture", "--pinned-home", "--progressive-home-load"]
        app.launchArguments.append(heroDisabled ? "--hero-disabled-home" : showcase ? "--immersive-home" : "--cached-home-hero")
        app.launchEnvironment["PLOZZ_HOME_ROWS_RELEASE_NOTIFICATION"] = resumeNotification
        app.launchEnvironment["PLOZZ_HOME_RECENT_RELEASE_NOTIFICATION"] = recentNotification
        app.launch()
        defer {
            notify_post(recentNotification)
            notify_post(resumeNotification)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let heading = app.staticTexts["Continue Watching"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let hero = app.buttons["home-hero-action-row"]
        if fullscreen {
            XCTAssertTrue(hero.waitForExistence(timeout: 10), "This must exercise the real full-screen hero.")
        }
        let before = heading.frame
        let heroBefore = fullscreen ? hero.frame : .zero
        let heroWasFocused = fullscreen && hero.hasFocus
        let focusedButtons = app.buttons.matching(NSPredicate(format: "hasFocus == true"))
        let initialFocus = focusedButtons.firstMatch.exists ? focusedButtons.firstMatch.label : nil
        XCTAssertGreaterThan(before.minY, 0)
        XCTAssertLessThan(before.maxY, app.frame.maxY)

        XCTAssertEqual(notify_post(recentNotification), UInt32(NOTIFY_STATUS_OK))
        let recentReady = NSPredicate { _, _ in app.staticTexts["home-fixture-latest-state"].label == "ready" }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: recentReady, object: nil)], timeout: 5
        ), .completed, "Readiness must be verified even when the fullscreen hero leaves that row off-screen.")
        XCTAssertEqual(app.staticTexts["home-fixture-resume-state"].label, "pending")
        let afterFocus = focusedButtons.firstMatch.exists ? focusedButtons.firstMatch.label : nil
        XCTAssertEqual(afterFocus, initialFocus, "No remote input was sent; fresh data must not choose a different row.")
        XCTAssertEqual(heading.frame.minY, before.minY, accuracy: 0.5)
        XCTAssertEqual(heading.frame.maxY, before.maxY, accuracy: 0.5)
        XCTAssertFalse(focusedCard(in: app).elementType == .button)
        if fullscreen {
            XCTAssertEqual(hero.hasFocus, heroWasFocused)
            XCTAssertEqual(hero.frame.minY, heroBefore.minY, accuracy: 0.5)
        }
        let waiting = XCTAttachment(screenshot: app.screenshot())
        waiting.name = "home-waiting-with-ready-lower-row-\(heroDisabled ? "classic" : showcase ? "showcase" : "fullscreen")"
        waiting.lifetime = .keepAlways
        add(waiting)

        XCTAssertEqual(notify_post(resumeNotification), UInt32(NOTIFY_STATUS_OK))
        let finished = NSPredicate { _, _ in app.staticTexts["home-fixture-resume-state"].label == "ready" }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 10
        ), .completed)
        XCTAssertEqual(heading.frame.minY, before.minY, accuracy: 0.5)
        if fullscreen {
            XCTAssertTrue(hero.exists)
            XCTAssertEqual(hero.hasFocus, heroWasFocused)
            XCTAssertEqual(hero.frame.minY, heroBefore.minY, accuracy: 0.5)
        } else {
            let card = focusedCard(in: app)
            if card.elementType == .button {
                let index = try XCTUnwrap(Int(card.label.split(separator: " ").last ?? ""))
                XCTAssertTrue((0..<24).contains(index), "Finishing Continue Watching must not select a lower row.")
            }
        }
    }

    func testFreshMergedRowsAreUsableBeforeResumeInShowcase() throws {
        try checkProgressiveRows(layout: "--immersive-home", libraryRows: false)
    }

    func testLoadingFocusRespectsEveryStyleAndContinueWatchingCardVariation() throws {
        for focusStyle in ["system", "highlight", "outlined"] {
            for framed in [false, true] {
                for seriesArtwork in [true, false] {
                    try XCTContext.runActivity(named: "\(focusStyle), framed=\(framed), series=\(seriesArtwork)") { _ in
                        try checkProgressiveRows(
                            layout: "--immersive-home", libraryRows: false,
                            focusStyle: focusStyle, framed: framed, seriesArtwork: seriesArtwork
                        )
                    }
                }
            }
        }
    }

    func testFreshMergedRowsAreUsableBeforeResumeWithoutHero() throws {
        try checkProgressiveRows(layout: "--hero-disabled-home", libraryRows: false)
    }

    func testFreshMergedRowsAreUsableBeforeResumeWithCarousel() throws {
        try checkProgressiveRows(layout: nil, libraryRows: false)
    }

    func testManualNavigationBelowFullscreenHeroSurvivesLateResume() throws {
        try checkProgressiveRows(layout: "--cached-home-hero", libraryRows: false)
    }

    func testTwentyLibraryRowsDoNotBlockTheFirstReadyShowcaseRow() throws {
        try checkProgressiveRows(layout: "--immersive-home", libraryRows: true)
    }

    func testTwentyLibraryRowsDoNotBlockTheFirstReadyClassicRow() throws {
        try checkProgressiveRows(layout: "--hero-disabled-home", libraryRows: true)
    }

    func testEmptyResumeResultKeepsTheManuallyFocusedShowcaseCardStable() throws {
        try checkProgressiveRows(layout: "--immersive-home", libraryRows: false, emptyResume: true)
    }

    func testEmptyResumeResultKeepsTheManuallyFocusedClassicCardSelected() throws {
        try checkProgressiveRows(layout: "--hero-disabled-home", libraryRows: false, emptyResume: true)
    }

    func testEmptyResumeResultKeepsTheManuallyFocusedFullscreenCardStable() throws {
        try checkProgressiveRows(layout: "--cached-home-hero", libraryRows: false, emptyResume: true)
    }

    private func checkProgressiveRows(
        layout: String?, libraryRows: Bool, emptyResume: Bool = false,
        focusStyle: String = "system", framed: Bool = false, seriesArtwork: Bool = true
    ) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        let notification = "com.thatcube.Plozz.HomeFixtureRows.\(UUID().uuidString)"
        app.launchArguments = ["--production-home-fixture", "--pinned-home", "--progressive-home-load"]
        if let layout { app.launchArguments.append(layout) }
        if libraryRows { app.launchArguments.append("--progressive-library-rows") }
        if emptyResume { app.launchArguments.append("--empty-home-resume") }
        app.launchArguments.append("--focus-style=\(focusStyle)")
        if framed { app.launchArguments.append("--framed-cards") }
        if !seriesArtwork { app.launchArguments.append("--episode-home-artwork") }
        app.launchEnvironment["PLOZZ_HOME_ROWS_RELEASE_NOTIFICATION"] = notification
        app.launch()
        defer {
            notify_post(notification)
            app.terminate()
        }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let resumeState = app.staticTexts["home-fixture-resume-state"]
        XCTAssertEqual(resumeState.label, "pending")
        if layout == nil || layout == "--cached-home-hero" {
            if layout == "--cached-home-hero" {
                XCTAssertTrue(app.buttons["home-hero-action-row"].waitForExistence(timeout: 10))
            }
            XCUIRemote.shared.press(.right)
            XCUIRemote.shared.press(.down)
        } else {
            XCUIRemote.shared.press(.down)
        }
        try enterMediaRow(in: app)
        waitForStableCard(in: app)
        let enteredIndex = try XCTUnwrap(Int(focusedCard(in: app).label.split(separator: " ").last ?? ""))
        XCTAssertTrue((24..<43).contains(enteredIndex), "Focus must enter the already loaded Recently Added row.")
        XCUIRemote.shared.press(.right)
        waitForStableCard(in: app)
        let selected = focusedCard(in: app)
        let label = selected.label
        let frame = selected.frame
        XCTAssertEqual(label, "Fixture movie \(enteredIndex + 1)")
        XCTAssertEqual(resumeState.label, "pending", "A real card must be usable before the slow requests finish.")

        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "focused-card-before-late-rows"
        before.lifetime = .keepAlways
        add(before)
        XCTAssertEqual(notify_post(notification), UInt32(NOTIFY_STATUS_OK))
        let settled = NSPredicate { [self] _, _ in
            let card = focusedCard(in: app)
            // Without a hero, removing an empty first row reaches the scroll
            // view's top boundary. Its selection and horizontal position survive;
            // its old vertical position no longer exists in the shorter page.
            let keepsVerticalAnchor = emptyResume && layout == "--hero-disabled-home"
                ? card.frame.minY >= 0 && card.frame.maxY <= app.frame.maxY
                : abs(card.frame.minY - frame.minY) < 0.5
            return resumeState.label == "ready" && card.label == label
                && abs(card.frame.minX - frame.minX) < 0.5
                && keepsVerticalAnchor
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10
        ), .completed, "Late rows must preserve the focused card and its on-screen position.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "progressive-home-\(layout ?? "carousel")-\(focusStyle)-framed-\(framed)-series-\(seriesArtwork)-libraries-\(libraryRows)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNativeSidebarButtonRemainsVisibleWithCarousel() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--native-sidebar-home"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15))
        if !hero.hasFocus { XCUIRemote.shared.press(.select) }
        try assertNativeSidebarButtonPainted(in: app, name: "carousel-native-sidebar")
    }

    func testNativeSidebarButtonRemainsVisibleInShowcase() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--native-sidebar-home", "--immersive-home",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        try assertNativeSidebarButtonPainted(in: app, name: "showcase-native-sidebar-initial")
        XCUIRemote.shared.press(.down)
        try assertNativeSidebarButtonPainted(in: app, name: "showcase-native-sidebar-lower-row", visible: false)
        XCUIRemote.shared.press(.up)
        try assertNativeSidebarButtonPainted(in: app, name: "showcase-native-sidebar-back-at-top")
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let detail = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Detail fixture")
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        try enterMediaRow(in: app)
        XCUIRemote.shared.press(.up)
        try assertNativeSidebarButtonPainted(in: app, name: "showcase-native-sidebar-after-detail")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        try enterMediaRow(in: app)
        try assertNativeSidebarButtonPainted(in: app, name: "showcase-native-sidebar-return")
    }

    private func assertNativeSidebarButtonPainted(
        in app: XCUIApplication, name: String, visible: Bool = true
    ) throws {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let region = CGRect(x: 20 * scale, y: 20 * scale, width: 480 * scale, height: 140 * scale)
        let crop = try XCTUnwrap(image.cropping(to: region))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let visiblePixels = try bytes.withUnsafeMutableBytes { buffer -> Int in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return stride(from: 0, to: buffer.count, by: 4).filter {
                min(buffer[$0], buffer[$0 + 1], buffer[$0 + 2]) > 160
            }.count
        }
        if visible {
            XCTAssertGreaterThan(visiblePixels, 100,
                                 "The native sidebar label must be visibly painted, not merely present in accessibility.")
        } else {
            XCTAssertLessThanOrEqual(visiblePixels, 100,
                                     "Preserve native chrome auto-hiding when browsing below the first row.")
        }
    }

    func testScheduleBadgeClearsTallLogoDuringHorizontalNavigation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--showcase-schedule-fixture",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        for _ in 0..<4 {
            let badge = app.descendants(matching: .any)["showcase-schedule"].firstMatch
            let logo = app.images["showcase-title-logo"].firstMatch
            XCTAssertTrue(badge.waitForExistence(timeout: 5))
            XCTAssertTrue(logo.waitForExistence(timeout: 5), "Measure decoded artwork, not the fallback title.")
            XCTAssertLessThanOrEqual(logo.frame.height, 124.5)
            XCTAssertGreaterThanOrEqual(logo.frame.minY - badge.frame.maxY, 15.5)
            XCTAssertGreaterThanOrEqual(badge.frame.minY, app.frame.minY)
            XCUIRemote.shared.press(.right)
            Thread.sleep(forTimeInterval: 0.2)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "showcase-schedule-above-tall-logo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLargerPostersAndCompactHeadingsWithNativeFocus() throws {
        try checkGeometry(focusStyle: "system")
    }

    func testLargerPostersAndCompactHeadingsWithHighlightFocus() throws {
        try checkGeometry(focusStyle: "highlight")
    }

    func testDelayedHomeLoadFinishesAfterBackgrounding() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home", "--slow-home-load",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.scrollViews["showcase-rows"].label, "Loading")
        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture movie")
        ).firstMatch.waitForExistence(timeout: 20), "Wait for real cards, not the loading row's heading.")
        try enterMediaRow(in: app)
        XCTAssertTrue(focusedCard(in: app).label.contains("Fixture movie"))
        XCTAssertLessThan(app.staticTexts["Continue Watching"].frame.maxY, focusedCard(in: app).frame.minY)
    }

    func testNativeVerticalReversalsKeepAnchorsAndHorizontalFocus() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let viewport = app.scrollViews["showcase-rows"]
        XCTAssertTrue(viewport.exists, "Rows move inside a native scroll viewport, not a translated stack.")
        XCTAssertEqual(viewport.frame.maxY, app.frame.maxY, accuracy: 0.5)
        XCTAssertTrue(viewport.staticTexts.matching(identifier: "media-row-title").count >= 2)
        for _ in 0..<8 { XCUIRemote.shared.press(.right) }
        waitForStableCard(in: app)
        let first = focusedCard(in: app)
        var firstLabel = first.label
        var firstFrame = first.frame
        let firstHeading = app.staticTexts["Continue Watching"].frame
        let description = app.staticTexts["A locally supplied movie for measuring the production Home view."].firstMatch
        let firstHeroY = description.frame.minY
        XCUIRemote.shared.press(.down)
        for _ in 0..<3 { XCUIRemote.shared.press(.right) }
        waitForStableCard(in: app)
        let second = focusedCard(in: app)
        var secondLabel = second.label
        var secondFrame = second.frame
        let secondHeading = app.staticTexts["Recently Added"].frame
        let secondHeroY = description.frame.minY
        XCTAssertNotEqual(firstLabel, secondLabel)
        // Ordinary Home rows use native column-aligned entry. Establish the
        // reciprocal pair after moving horizontally on the lower row.
        XCUIRemote.shared.press(.up)
        waitForStableCard(in: app)
        firstLabel = focusedCard(in: app).label
        firstFrame = focusedCard(in: app).frame
        XCUIRemote.shared.press(.down)
        waitForStableCard(in: app)
        secondLabel = focusedCard(in: app).label
        secondFrame = focusedCard(in: app).frame
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            XCTAssertEqual(focusedCard(in: app).label, secondLabel, "The last row must retain focus without drift.")
        }
        for _ in 0..<8 {
            XCUIRemote.shared.press(.up)
            XCUIRemote.shared.press(.down)
        }
        waitForCard(in: app, label: secondLabel, frame: secondFrame)
        XCTAssertEqual(focusedCard(in: app).label, secondLabel)
        XCTAssertEqual(focusedCard(in: app).frame.minX, secondFrame.minX, accuracy: 0.5)
        XCTAssertEqual(focusedCard(in: app).frame.minY, secondFrame.minY, accuracy: 0.5)
        XCTAssertEqual(app.staticTexts["Recently Added"].frame.minY, secondHeading.minY, accuracy: 0.5)
        XCTAssertEqual(description.frame.minY, secondHeroY, accuracy: 0.5)
        XCUIRemote.shared.press(.up)
        waitForCard(in: app, label: firstLabel, frame: firstFrame)
        XCTAssertEqual(focusedCard(in: app).label, firstLabel)
        XCTAssertEqual(focusedCard(in: app).frame.minX, firstFrame.minX, accuracy: 0.5)
        XCTAssertEqual(focusedCard(in: app).frame.minY, firstFrame.minY, accuracy: 0.5)
        XCTAssertEqual(app.staticTexts["Continue Watching"].frame.minY, firstHeading.minY, accuracy: 0.5)
        XCTAssertEqual(description.frame.minY, firstHeroY, accuracy: 0.5)

        XCUIRemote.shared.press(.down)
        let detailLabel = focusedCard(in: app).label
        XCTAssertNotEqual(detailLabel, firstLabel)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Detail fixture \(detailLabel)"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        let returned = NSPredicate { [self] _, _ in focusedCard(in: app).label == detailLabel }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 10
        ), .completed, "Returning from detail preserves the same card and horizontal window.")
        XCTAssertEqual(app.staticTexts["Recently Added"].frame.minY, secondHeading.minY, accuracy: 0.5)
    }

    func testEnteringFromSidebarPinsTheRowWhereReturningDoes() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--pinned-home", "--immersive-home"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let heading = app.staticTexts["Continue Watching"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20))
        let resting = heading.frame.minY
        if focusedCard(in: app).elementType == .button { XCUIRemote.shared.press(.left) }
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 1)
        let entered = heading.frame.minY
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 1)
        XCUIRemote.shared.press(.up)
        Thread.sleep(forTimeInterval: 1)
        let returned = heading.frame.minY
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "showcase-entered-from-sidebar"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(entered, returned, accuracy: 0.5, "resting=\(resting) entered=\(entered) returned=\(returned)")
        XCTAssertEqual(resting, returned, accuracy: 0.5, "resting=\(resting) entered=\(entered) returned=\(returned)")
    }

    func testHorizontalNavigationHitches() throws {
        try measureNavigation(vertical: false)
    }

    func testVerticalNavigationHitches() throws {
        try measureNavigation(vertical: true)
    }

    func testCarouselHeroGradientNavigationHitches() throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Presented-frame metrics require tvOS 26.") }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--home-performance-fixture", "--distinct-home-artwork",
            "--gradient-performance", "--gradient-black"
        ]
        if ProcessInfo.processInfo.environment["PLOZZ_GRADIENT_DISABLED"] == "1" {
            app.launchArguments.append("--gradient-off")
        }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        XCTAssertTrue(hero.hasFocus)
        let initial = hero.label
        for _ in 0..<6 { XCUIRemote.shared.press(.right); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertNotEqual(hero.label.components(separatedBy: ",").first, initial.components(separatedBy: ",").first,
                          "Measure actual hero slide changes, not just movement between action buttons.")
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            startMeasuring()
            for _ in 0..<6 { XCUIRemote.shared.press(.right); Thread.sleep(forTimeInterval: 0.5) }
            stopMeasuring()
            XCTAssertTrue(hero.hasFocus)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Carousel gradient after hero navigation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHorizontalRowAndHeroAnchorsStayFixed() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--home-performance-fixture", "--distinct-home-artwork",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let title = app.staticTexts["Continue Watching"]
        let description = app.staticTexts["A locally supplied movie for measuring the production Home view."].firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        var rowPositions = [title.frame.minY]
        var heroPositions = [description.frame.minY]
        for direction in [XCUIRemote.Button.right, .left] {
            for _ in 0..<16 {
                XCUIRemote.shared.press(direction)
                Thread.sleep(forTimeInterval: 0.65)
                rowPositions.append(title.frame.minY)
                heroPositions.append(description.frame.minY)
            }
        }
        let evidence = XCTAttachment(string: "rowY=\(rowPositions)\nheroY=\(heroPositions)")
        evidence.name = "showcase-horizontal-anchors"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertLessThanOrEqual((rowPositions.max() ?? 0) - (rowPositions.min() ?? 0), 0.5)
        XCTAssertLessThanOrEqual((heroPositions.max() ?? 0) - (heroPositions.min() ?? 0), 0.5)
    }

    func testDeepHorizontalTraversalKeepsRowAndHeroAnchorsFixed() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--home-performance-fixture", "--distinct-home-artwork",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let heading = app.staticTexts["Continue Watching"]
        let description = app.staticTexts["A locally supplied movie for measuring the production Home view."].firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let headingY = heading.frame.minY
        let heroY = description.frame.minY
        let initialLabel = focusedCard(in: app).label
        // A held press does not produce a fixed repeat count. Verify the actual
        // endpoint as well as the anchors, rather than assuming three holds suffice.
        for _ in 0..<4 {
            XCUIRemote.shared.press(.right, forDuration: 4)
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertEqual(heading.frame.minY, headingY, accuracy: 0.5)
            XCTAssertEqual(description.frame.minY, heroY, accuracy: 0.5)
            if focusedCard(in: app).label == "Fixture movie 74" { break }
        }
        XCTAssertEqual(focusedCard(in: app).label, "Fixture movie 74",
                       "Traverse the entire long row, beyond its initially realized native posters.")
        for _ in 0..<4 {
            XCUIRemote.shared.press(.left, forDuration: 4)
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertEqual(heading.frame.minY, headingY, accuracy: 0.5)
            XCTAssertEqual(description.frame.minY, heroY, accuracy: 0.5)
            if focusedCard(in: app).label == initialLabel { break }
        }
        XCTAssertEqual(focusedCard(in: app).label, initialLabel)
    }

    private func measureNavigation(vertical: Bool) throws {
        guard #available(tvOS 26.0, *) else {
            throw XCTSkip("Presented-frame measurements require tvOS 26.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--home-performance-fixture", "--distinct-home-artwork",
        ]
        if ProcessInfo.processInfo.environment["PLOZZ_GRADIENT_COMPARISON"] == "1" {
            app.launchArguments += ["--gradient-performance", "--gradient-black"]
            if ProcessInfo.processInfo.environment["PLOZZ_GRADIENT_DISABLED"] == "1" {
                app.launchArguments.append("--gradient-off")
            }
        }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let first = focusedCard(in: app)
        let originalLabel = first.label
        XCTAssertTrue(originalLabel.contains("Fixture movie"), "The workload must start on a real card.")
        XCUIRemote.shared.press(.down)
        XCTAssertNotEqual(focusedCard(in: app).label, originalLabel, "The lower row must be reachable.")
        XCUIRemote.shared.press(.up)
        XCTAssertEqual(focusedCard(in: app).label, originalLabel)

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            startMeasuring()
            if vertical {
                for _ in 0..<6 {
                    XCUIRemote.shared.press(.down)
                    XCUIRemote.shared.press(.up)
                }
            } else {
                XCUIRemote.shared.press(.right, forDuration: 3)
            }
            stopMeasuring()
            if !vertical {
                XCTAssertNotEqual(focusedCard(in: app).label, originalLabel)
                XCUIRemote.shared.press(.left, forDuration: 4)
            }
            XCTAssertEqual(focusedCard(in: app).label, originalLabel, "Navigation must return to the same card.")
        }
    }

    private func checkGeometry(focusStyle: String) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", "--pinned-home", "--immersive-home",
            "--focus-style=\(focusStyle)",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        try enterMediaRow(in: app)
        let first = focusedCard(in: app)
        let initialLabel = first.label
        let currentTitle = app.staticTexts["Continue Watching"]
        XCTAssertLessThan(currentTitle.frame.maxY, first.frame.minY, "The active title must clear focused artwork.")
        let inactiveTitle = app.staticTexts["Recently Added"]
        let preview = app.buttons.allElementsBoundByIndex
            .filter {
                $0.frame.height > 100 && $0.frame.width > 200 && $0.frame.width < 400
                    && $0.frame.minY > inactiveTitle.frame.minY
                    && $0.frame.minY < inactiveTitle.frame.maxY + 100
            }
            .min { $0.frame.minX < $1.frame.minX }
        if preview == nil {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Missing Showcase preview card"
            tree.lifetime = .keepAlways
            add(tree)
        }
        let next = try XCTUnwrap(preview)
        let inactiveGap = next.frame.minY - inactiveTitle.frame.maxY
        let gapAboveHeading = inactiveTitle.frame.minY - first.frame.maxY
        // Native button frames include 20pt vertical focus margins at rest.
        XCTAssertEqual(gapAboveHeading, focusStyle == "system" ? 30 : 44, accuracy: 0.5)
        XCTAssertEqual(inactiveGap, focusStyle == "system" ? -10 : 10, accuracy: 0.5)
        let previewScreenshot = XCTAttachment(screenshot: app.screenshot())
        previewScreenshot.name = "showcase-preview-spacing-\(focusStyle)"
        previewScreenshot.lifetime = .keepAlways
        add(previewScreenshot)
        XCTAssertGreaterThan(app.frame.maxY - next.frame.minY, 20, "Down needs real visible card area.")
        XCUIRemote.shared.press(.down)
        waitForStableCard(in: app)
        let poster = focusedCard(in: app)
        let activeGap = poster.frame.minY - inactiveTitle.frame.maxY
        XCTAssertGreaterThanOrEqual(poster.frame.width, 280, "Showcase uses full-size posters instead of 70% artwork.")
        // A 280pt slot includes two 10pt side margins; the 2:3 artwork is 260x390.
        // Native focus expands its AX frame; custom focus keeps the layout frame.
        XCTAssertGreaterThanOrEqual(poster.frame.height, 390)
        XCTAssertEqual(poster.label, "Fixture movie 24", "Hidden captions must retain the media title.")
        XCTAssertGreaterThan(activeGap, 8, "Focus growth must leave clear space beneath the row label.")
        XCTAssertEqual(activeGap, focusStyle == "system" ? 10 : 30, accuracy: 0.5,
                       "More resting space must preserve the existing focused heading clearance.")
        XCTAssertGreaterThan(activeGap, inactiveGap, "The active heading makes room for focus; previews stay compact.")
        let spacing = XCTAttachment(string: "above=\(gapAboveHeading)\nbelow=\(inactiveGap)\nactive=\(activeGap)")
        spacing.name = "showcase-heading-spacing-\(focusStyle)"
        spacing.lifetime = .keepAlways
        add(spacing)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "showcase-poster-\(focusStyle)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for _ in 0..<4 {
            XCUIRemote.shared.press(.up)
            XCTAssertEqual(focusedCard(in: app).label, initialLabel)
            XCUIRemote.shared.press(.down)
            XCTAssertEqual(focusedCard(in: app).label, poster.label)
        }
    }

    private func enterMediaRow(in app: XCUIApplication) throws {
        if focusedCard(in: app).elementType != .button {
            XCUIRemote.shared.press(.right)
        }
        let ready = NSPredicate { [self] _, _ in focusedCard(in: app).elementType == .button }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 5)
        if result != .completed {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "showcase-focus-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "showcase-focus-failure"
            image.lifetime = .keepAlways
            add(image)
            XCTAssertEqual(result, .completed, "The workload requires actual media focus.")
            throw NSError(domain: "ShowcaseNavigationTests", code: 1)
        }
    }

    private func waitForStableCard(in app: XCUIApplication) {
        var previousLabel = ""
        var previousFrame = CGRect.zero
        var unchangedSince = Date()
        let settled = NSPredicate { [self] _, _ in
            let card = focusedCard(in: app)
            let frame = card.frame
            guard card.elementType == .button, card.label == previousLabel,
                  abs(frame.minX - previousFrame.minX) < 0.5,
                  abs(frame.minY - previousFrame.minY) < 0.5 else {
                previousLabel = card.label
                previousFrame = frame
                unchangedSince = Date()
                return false
            }
            return Date().timeIntervalSince(unchangedSince) >= 0.2
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5
        ), .completed, "Capture anchor geometry only after native focus scrolling settles.")
    }

    private func waitForCard(in app: XCUIApplication, label: String, frame: CGRect) {
        let settled = NSPredicate { [self] _, _ in
            let card = focusedCard(in: app)
            return card.label == label && abs(card.frame.minX - frame.minX) < 0.5
                && abs(card.frame.minY - frame.minY) < 0.5
        }
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 3
        ), .completed, "Native scrolling must settle at the same focused-card anchor.")
    }

    private func focusedCard(in app: XCUIApplication) -> XCUIElement {
        let native = app.buttons.matching(
            NSPredicate(format: "hasFocus == true AND label MATCHES %@", "Fixture movie [0-9]+")
        ).firstMatch
        if native.exists { return native }
        return app.buttons.allElementsBoundByIndex
            .filter {
                $0.label.contains("Fixture movie") && $0.frame.width > 100 && $0.frame.height > 100
                    && ($0.hasFocus || $0.descendants(matching: .any)
                        .matching(NSPredicate(format: "hasFocus == true")).count > 0)
            }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app
    }
}
