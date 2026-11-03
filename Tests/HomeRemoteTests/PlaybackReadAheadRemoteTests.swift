import XCTest

@MainActor
final class PlaybackReadAheadRemoteTests: XCTestCase {
    func testSDHPreferenceIsAvailableWithoutSubtitleDownloads() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--read-ahead-settings-fixture", "--subtitle-settings-workspace"]
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["settings-group-subtitle-sdh"]
        XCTAssertTrue(app.staticTexts["read-ahead-saved"].waitForExistence(timeout: 10))
        for _ in 0..<20 {
            if hasFocus(menu) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(hasFocus(menu))
        XCTAssertFalse(app.staticTexts["Downloading subtitles"].exists)
        XCTAssertGreaterThan(menu.frame.width, 800)
        XCTAssertEqual(menu.frame.width, app.buttons["Subtitle language"].frame.width, accuracy: 1)
        XCTAssertTrue(menu.isHittable)
        XCUIRemote.shared.press(.select)
        let prefer = app.cells.containing(.any, identifier: "Prefer SDH").firstMatch
        XCTAssertTrue(prefer.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if prefer.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        if !prefer.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(waitUntil { prefer.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil {
            app.staticTexts["Use SDH when available; otherwise use regular subtitles."].exists
        })
        XCUIRemote.shared.press(.select)
        let strict = app.cells.containing(.any, identifier: "Only SDH").firstMatch
        XCTAssertTrue(strict.waitForExistence(timeout: 5))
        let regular = app.cells.containing(.any, identifier: "Prefer Non-SDH").firstMatch
        for _ in 0..<4 {
            if regular.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(waitUntil { regular.hasFocus })
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { strict.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil {
            app.staticTexts["Use only SDH. Leave subtitles off if unavailable."].exists
        })
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "SDH selection for network shares"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFocusOnlyPreviewsAndSelectPersistsAcrossLaunches() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--read-ahead-settings-fixture", "--playback-settings-workspace", "--reset-read-ahead"
        ]
        app.launch()
        defer { app.terminate() }
        let row = app.buttons["settings-group-read-ahead"]
        XCTAssertTrue(app.staticTexts["read-ahead-saved"].waitForExistence(timeout: 10))
        for _ in 0..<35 {
            if hasFocus(row) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(hasFocus(row))
        XCTAssertTrue(row.label.contains("Video buffer"))
        XCTAssertLessThan(row.frame.height, 160)
        XCTAssertEqual(row.value as? String, "Automatic")
        XCTAssertFalse(app.buttons["Maximum available"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Larger buffers use more temporary storage. Duration depends on the video and available space. Unavailable with Apple’s native player."
        )).firstMatch.exists)
        let choices = ["Automatic", "1 minute", "5 minutes", "10 minutes", "Maximum available"]
        XCUIRemote.shared.press(.select)
        let automatic = app.cells.containing(.any, identifier: "Automatic").firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        for _ in 0..<choices.count {
            if automatic.hasFocus { break }
            XCTAssertEqual(app.staticTexts["read-ahead-saved"].label, "automatic")
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(waitUntil { automatic.hasFocus })
        for title in choices.dropFirst() {
            XCUIRemote.shared.press(.down)
            let choice = app.cells.containing(.any, identifier: title).firstMatch
            XCTAssertTrue(waitUntil { choice.hasFocus })
            XCTAssertEqual(app.staticTexts["read-ahead-saved"].label, "automatic")
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["read-ahead-saved"].label == "maximumAvailable" })
        XCTAssertTrue(waitUntil { self.hasFocus(row) })
        XCTAssertEqual(row.value as? String, "Maximum available")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Compact video buffer selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchArguments = ["--read-ahead-settings-fixture", "--playback-settings-workspace"]
        app.launch()
        XCTAssertTrue(app.staticTexts["read-ahead-saved"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["read-ahead-saved"].label, "maximumAvailable")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        ], timeout: 5) == .completed
    }

    func testLiveBufferOnlyPersistsOnSelectAndKeepsVideoBufferIndependent() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--read-ahead-settings-fixture", "--playback-settings-workspace", "--reset-read-ahead"
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["live-buffer-saved"].waitForExistence(timeout: 10))
        let row = app.buttons["settings-group-live-buffer"]
        for _ in 0..<40 {
            if hasFocus(row) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(hasFocus(row))
        XCTAssertLessThan(row.frame.height, 160)
        XCTAssertEqual(row.value as? String, "Automatic")
        XCTAssertFalse(app.buttons["45 seconds"].exists)
        XCUIRemote.shared.press(.select)
        let choices = ["Automatic", "10 seconds", "20 seconds", "30 seconds", "45 seconds"]
        let automatic = app.cells.containing(.any, identifier: "Automatic").firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        for _ in 0..<choices.count {
            if automatic.hasFocus { break }
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(waitUntil { automatic.hasFocus })
        XCUIRemote.shared.press(.down)
        let tenSeconds = app.cells.containing(.any, identifier: "10 seconds").firstMatch
        XCTAssertTrue(waitUntil { tenSeconds.hasFocus })
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { self.hasFocus(row) })
        XCTAssertEqual(app.staticTexts["live-buffer-saved"].label, "automatic")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { automatic.hasFocus })
        for title in choices.dropFirst() {
            XCUIRemote.shared.press(.down)
            let choice = app.cells.containing(.any, identifier: title).firstMatch
            XCTAssertTrue(waitUntil { choice.hasFocus })
            XCTAssertEqual(app.staticTexts["live-buffer-saved"].label, "automatic")
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["live-buffer-saved"].label == "fortyFiveSeconds" })
        XCTAssertEqual(app.staticTexts["read-ahead-saved"].label, "automatic")
        XCTAssertTrue(waitUntil { self.hasFocus(row) })
        XCTAssertEqual(row.value as? String, "45 seconds")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Compact Live TV buffer selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchArguments = ["--read-ahead-settings-fixture", "--playback-settings-workspace"]
        app.launch()
        XCTAssertTrue(app.staticTexts["live-buffer-saved"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["live-buffer-saved"].label, "fortyFiveSeconds")
        XCTAssertEqual(app.staticTexts["read-ahead-saved"].label, "automatic")
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && (element.hasFocus || element.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
    }

    func testPlaybackAudioRowNoLongerOffersHeightConversion() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--read-ahead-settings-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["read-ahead-saved"].waitForExistence(timeout: 10))
        let row = app.buttons["settings-master-lossless-surround"]
        for _ in 0..<40 {
            if hasFocus(row) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(hasFocus(row))
        XCUIRemote.shared.press(.right)
        let lossless = app.descendants(matching: .any).matching(identifier: "lossless-surround-toggle").firstMatch
        XCTAssertTrue(waitUntil { self.hasFocus(lossless) })
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "spatial-audio-toggle").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Spatial audio (height channel support)"].exists)
    }
}
