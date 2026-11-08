import UIKit
import XCTest

@MainActor
final class EpisodeBreadcrumbRemoteTests: XCTestCase {
    func testNativeEpisodeMenuDoesNotReplaceOrFadeItsContentsOnOpening() throws {
        for descriptionsOnFocus in [false, true] {
            try exerciseEpisodeContextMenu(style: "--system", descriptionsOnFocus: descriptionsOnFocus, trace: true)
        }
    }

    func testEpisodeContextMenuKeepsActionsAndRestoresCardFocus() throws {
        for style in ["--system", "--highlight", "--outlined"] {
            for descriptionsOnFocus in [false, true] {
                try exerciseEpisodeContextMenu(style: style, descriptionsOnFocus: descriptionsOnFocus)
            }
        }
    }

    private func exerciseEpisodeContextMenu(style: String, descriptionsOnFocus: Bool, trace: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture", "--series-navigation", "--episode-menu", style]
            + (descriptionsOnFocus ? ["--descriptions-on-focus"] : [])
            + (trace ? ["--trace-menu-appearance"] : [])
        app.launch()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        waitFor { play.hasFocus }
        XCUIRemote.shared.press(.down)
        if app.buttons["Season 2"].exists && app.buttons["Season 2"].hasFocus { XCUIRemote.shared.press(.down) }
        var episode = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "E1 · Fixture Episode 1,")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10), app.debugDescription)
        func episodeHasFocus() -> Bool {
            episode.exists && (episode.hasFocus || episode.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
        }
        waitFor { episodeHasFocus() }
        if trace {
            for number in 2...3 {
                XCUIRemote.shared.press(.right)
                episode = app.descendants(matching: .any).matching(NSPredicate(
                    format: "label BEGINSWITH %@", "E\(number) · Fixture Episode \(number),"
                )).firstMatch
                waitFor { episodeHasFocus() }
            }
        }
        for iteration in 0..<3 {
            XCUIRemote.shared.press(.select, forDuration: 1)
            let navigation = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Go to Episode")).firstMatch
            XCTAssertTrue(navigation.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Mark as Watched")).firstMatch.exists)
            if trace {
                Thread.sleep(forTimeInterval: 3)
                XCUIRemote.shared.press(.menu)
                waitFor { episodeHasFocus() }
                let result = app.descendants(matching: .any)["episode-menu-appearance-result"]
                waitFor { result.exists && result.value as? String != "pending" }
                let json = try XCTUnwrap(result.value as? String)
                let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                XCTAssertGreaterThan(try XCTUnwrap(summary["samples"] as? Int), 30, json)
                XCTAssertEqual(summary["lists"] as? Int, 1, "The presented native list must not be replaced: \(json)")
                XCTAssertEqual(summary["labels"] as? Int, 4, "All four menu labels must retain their identities: \(json)")
                XCTAssertGreaterThan(try XCTUnwrap(summary["minimumOpacity"] as? Double), 0.99,
                                     "Menu contents must not fade independently of the opening presentation: \(json)")
                XCUIRemote.shared.press(.select, forDuration: 1)
                XCTAssertTrue(navigation.waitForExistence(timeout: 5))
                XCUIRemote.shared.press(.down)
                XCUIRemote.shared.press(.down)
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.staticTexts.matching(identifier: "breadcrumb-route")
                    .matching(NSPredicate(format: "label BEGINSWITH %@", "episode-3|"))
                    .firstMatch.waitForExistence(timeout: 8), app.debugDescription)
                return
            }
            attach(app.screenshot(), name: "episode-menu-\(style)-focus-\(descriptionsOnFocus)-\(iteration)")
            XCUIRemote.shared.press(.menu)
            waitFor { episodeHasFocus() }
        }
    }

    func testLoadingPrimaryQueuesOnePlayWithoutResizing() throws {
        let app = loadingSeriesApp()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        let before = play.frame
        XCUIRemote.shared.press(.select)
        waitFor { play.value as? String == "Loading" }
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["detail-entry-play-count"].label, "0")
        XCTAssertEqual(play.frame.width, before.width, accuracy: 1)
        XCTAssertEqual(play.frame.height, before.height, accuracy: 1)
        XCTAssertTrue(play.hasFocus)
        attach(app.screenshot(), name: "detail-primary-queued-spinner")
        waitUntilReady(app)
        waitFor { app.staticTexts["detail-entry-play-count"].label == "1" }
        XCTAssertNotEqual(play.value as? String, "Loading")
        XCTAssertTrue(play.hasFocus)
    }

    func testLoadingPrimaryCancelsOnContextChange() throws {
        let app = loadingSeriesApp(extraArguments: ["--change-context-on-watchlist"])
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        XCUIRemote.shared.press(.select)
        waitFor { play.value as? String == "Loading" }
        XCUIRemote.shared.press(.right)
        waitFor { app.buttons["detail-hero-watchlist"].hasFocus }
        XCUIRemote.shared.press(.select)
        waitFor { app.staticTexts["detail-entry-context"].label == "changed" }
        XCTAssertNotEqual(play.value as? String, "Loading")
        waitUntilReady(app)
        XCTAssertEqual(app.staticTexts["detail-entry-play-count"].label, "0")
    }

    func testLoadingPrimaryCancelsOnExit() throws {
        let app = loadingSeriesApp()
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        waitFor { app.buttons["detail-hero-play"].value as? String == "Loading" }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["Go to Episode"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 18)
        XCTAssertEqual(app.staticTexts["detail-entry-play-count"].label, "0")
    }

    func testLoadingPrimaryDoesNotStealLaterFocusWithoutAnEarlyPress() throws {
        let app = loadingSeriesApp()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        let watchlist = app.buttons["detail-hero-watchlist"]
        XCUIRemote.shared.press(.right)
        waitFor { watchlist.hasFocus }
        waitUntilReady(app)
        XCTAssertTrue(watchlist.hasFocus, "Readiness must not move the user back to Play.")
        XCTAssertEqual(app.staticTexts["detail-entry-play-count"].label, "0")
        XCUIRemote.shared.press(.left)
        waitFor { play.hasFocus }
        XCUIRemote.shared.press(.select)
        waitFor { app.staticTexts["detail-entry-play-count"].label == "1" }
    }

    func testLoadingRequestQueuesChooserNotSubmission() throws {
        let app = loadingRequestApp()
        defer { app.terminate() }
        let request = app.buttons["detail-hero-request"]
        let before = request.frame
        XCUIRemote.shared.press(.select)
        waitFor { request.value as? String == "Loading" }
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(request.frame.width, before.width, accuracy: 1)
        XCTAssertEqual(request.frame.height, before.height, accuracy: 1)
        attach(app.screenshot(), name: "detail-request-queued-spinner")
        let season = app.buttons.matching(identifier: "Request Season 1").firstMatch
        XCTAssertTrue(season.waitForExistence(timeout: 25))
        XCTAssertEqual(app.staticTexts["detail-entry-request-count"].label, "0")
        attach(app.screenshot(), name: "detail-request-ready-chooser")
        // A real explicit season selection is still required.
        for _ in 0..<5 where !season.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(season.hasFocus)
        XCUIRemote.shared.press(.select)
        waitFor { app.staticTexts["detail-entry-request-count"].label == "1" }
    }

    func testFailedSeasonLookupClearsQueuedSpinner() throws {
        let app = loadingRequestApp(extraArguments: ["--fail-season-lookup"])
        defer { app.terminate() }
        let request = app.buttons["detail-hero-request"]
        XCUIRemote.shared.press(.select)
        waitFor { request.value as? String == "Loading" }
        let retry = app.buttons.matching(identifier: "detail-hero-request")
            .matching(NSPredicate(format: "label == %@", "Retry Seasons")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 25))
        XCTAssertNotEqual(request.value as? String, "Loading")
        XCTAssertEqual(app.staticTexts["detail-entry-request-count"].label, "0")
        XCTAssertFalse(app.buttons["Request Season 1"].exists)
        attach(app.screenshot(), name: "detail-request-lookup-failed")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "detail-request-failed-focus"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCUIRemote.shared.press(.select)
        waitFor { request.label.hasPrefix("Loading Seasons") }
    }

    private func loadingSeriesApp(extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture", "--series-navigation", "--delayed-series-entry"] + extraArguments
        app.launch()
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertTrue(play.hasFocus, "The placeholder must already own focus when the page appears.")
        XCTAssertEqual(app.staticTexts["detail-entry-load-state"].label, "loading")
        return app
    }

    private func loadingRequestApp(extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture", "--series-navigation", "--request-primary"] + extraArguments
        app.launch()
        let request = app.buttons["detail-hero-request"]
        XCTAssertTrue(request.waitForExistence(timeout: 15))
        XCTAssertTrue(request.hasFocus)
        return app
    }

    private func waitUntilReady(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.staticTexts["detail-entry-load-state"].label == "ready" },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
    }

    func testEpisodeOpenedFromHomeCanOpenItsShow() throws {
        try verifyBreadcrumb(fromShow: false)
    }

    func testEpisodeOpenedFromShowCanOpenItsShow() throws {
        try verifyBreadcrumb(fromShow: true)
    }

    func testUpcomingEpisodeCanOpenItsShowWithoutAPlayButton() throws {
        try verifyBreadcrumb(fromShow: false, upcoming: true)
    }

    private func verifyBreadcrumb(fromShow: Bool, upcoming: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-breadcrumb-fixture"] + (fromShow ? ["--from-show"] : [])
        if upcoming { app.launchArguments.append("--upcoming") }
        app.launch()
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        let breadcrumb = app.buttons["Go to Fixture Show"]
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(identifier: "Go to Fixture Show").count, 1)
        if upcoming {
            XCTAssertFalse(play.exists)
        } else {
            XCTAssertTrue(play.waitForExistence(timeout: 15))
            waitFor { play.hasFocus }
            waitFor {
                (try? self.brightPixels(in: app.screenshot(), frame: breadcrumb.frame, viewport: app.frame)) ?? 0 > 100
            }
            let before = app.screenshot()
            attach(before, name: "episode-breadcrumb-before-focus")
            XCTAssertGreaterThan(try brightPixels(in: before, frame: breadcrumb.frame, viewport: app.frame), 100,
                                 "The show title must be visible before it is focused.")
            XCUIRemote.shared.press(.up)
        }
        waitFor { breadcrumb.hasFocus }
        let focused = app.screenshot()
        attach(focused, name: "episode-breadcrumb-focused")
        let focusedFrame = breadcrumb.frame
        let brightFraction = Double(try brightPixels(in: focused, frame: focusedFrame, viewport: app.frame))
            / Double(focusedFrame.width * focusedFrame.height)
        XCTAssertLessThan(brightFraction, 0.5, "The breadcrumb must remain text, not a filled focus chip.")
        XCUIRemote.shared.press(.select)
        waitFor { app.staticTexts["breadcrumb-route"].label == "show|season-2|breadcrumb-account" }
        attach(app.screenshot(), name: "episode-breadcrumb-opened-show")
        XCUIRemote.shared.press(.menu)
        waitFor { app.staticTexts["breadcrumb-route"].label == "episode|season-2|breadcrumb-account" }
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, file: file, line: line)
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func brightPixels(in screenshot: XCUIScreenshot, frame: CGRect, viewport: CGRect) throws -> Int {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scaleX = CGFloat(image.width) / viewport.width
        let scaleY = CGFloat(image.height) / viewport.height
        let pixels = CGRect(x: (frame.minX - viewport.minX) * scaleX, y: (frame.minY - viewport.minY) * scaleY,
                            width: frame.width * scaleX, height: frame.height * scaleY)
        guard let crop = image.cropping(to: pixels), !frame.isEmpty else {
            throw NSError(domain: "EpisodeBreadcrumbRemoteTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Breadcrumb is outside the screenshot: \(frame)"])
        }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let count = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 140 && bytes[$0 + 1] > 140 && bytes[$0 + 2] > 140
        }.count
        return Int(CGFloat(count) / (scaleX * scaleY))
    }
}
