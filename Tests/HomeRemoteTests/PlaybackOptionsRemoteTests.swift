import XCTest

@MainActor
final class PlaybackOptionsRemoteTests: XCTestCase {
    func testAudioSyncResetAndBack() throws {
        try checkSyncPanel(category: "Audio", syncLabel: "Audio Sync", valueID: "audio-sync-milliseconds", step: 10)
    }

    func testSubtitleSyncResetAndBack() throws {
        try checkSyncPanel(category: "Subtitles", syncLabel: "Subtitle Sync", valueID: "subtitle-sync-milliseconds", step: 50)
    }

    private func checkSyncPanel(category: String, syncLabel: String, valueID: String, step: Int) throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--subtitle-style-input-fixture", "--production-player-input", "--sync-controls"]
        app.launch()
        defer { app.terminate() }
        let toolbar = app.buttons[category]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.up)
        for _ in 0..<12 where !toolbar.hasFocus { XCUIRemote.shared.press(.left) }
        for _ in 0..<12 where !toolbar.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(toolbar.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        let sync = app.buttons[syncLabel]
        func openSync() {
            XCTAssertTrue(sync.waitForExistence(timeout: 5))
            for _ in 0..<4 where !sync.hasFocus { XCUIRemote.shared.press(.up) }
            for _ in 0..<2 where !sync.hasFocus { XCUIRemote.shared.press(.left) }
            XCTAssertTrue(sync.hasFocus, app.debugDescription)
            XCUIRemote.shared.press(.select)
        }
        openSync()
        let control = app.buttons.matching(NSPredicate(format: "value MATCHES %@", "[-+0-9.]+s")).firstMatch
        let back = app.buttons["player-options-back"]
        let reset = app.buttons["Reset"]
        let value = app.staticTexts[valueID]
        XCTAssertTrue(waitUntil { control.exists && control.hasFocus }, app.debugDescription)
        XCTAssertTrue(reset.isEnabled, "A nonzero offset must not make Reset steal entry focus.")
        for _ in 0..<3 {
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(waitUntil { back.hasFocus }, app.debugDescription)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitUntil { control.hasFocus }, app.debugDescription)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(waitUntil { reset.hasFocus }, app.debugDescription)
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(waitUntil { control.hasFocus }, app.debugDescription)
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { value.label == String(200 + step) })
        XCTAssertTrue(control.hasFocus)
        XCUIRemote.shared.press(.right, forDuration: 0.8)
        XCTAssertGreaterThan(try XCTUnwrap(Int(value.label)), 200 + step * 2)
        XCTAssertTrue(control.hasFocus)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { reset.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { value.label == "0" }, "Reset did not clear the \(category) offset.")
        XCTAssertFalse(reset.isEnabled)
        XCTAssertTrue(waitUntil { control.hasFocus },
                      "Reset cleared \(category) but did not return focus to the stepper. \(app.debugDescription)")
        capture("\(category) Sync after Reset")
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitUntil { back.hasFocus }, app.debugDescription)
        XCUIRemote.shared.press(.select)
        openSync()
        XCTAssertTrue(waitUntil { control.exists && control.hasFocus }, "Reopening at zero must focus the stepper.")
        XCTAssertEqual(value.label, "0")
        XCTAssertFalse(reset.isEnabled)
        XCTAssertEqual(app.staticTexts["subtitle-navigation-open-attempts"].label, "0")
        capture("\(category) Sync native focus")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(sync.waitForExistence(timeout: 5), "Remote Back must return to \(category).")
    }

    func testRemoteInlineSpeedZoomSubmenuAndBackUseTheProductionPlayer() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--subtitle-style-input-fixture", "--production-player-input", "--playback-options"]
        app.launch()
        defer { app.terminate() }
        let playback = app.buttons["player-control-ellipsis"]
        let rate = app.buttons["player-control-speedometer"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.up)
        for _ in 0..<3 where !rate.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(waitUntil { rate.hasFocus }, app.debugDescription)
        XCUIRemote.shared.press(.select)

        let zoom = app.buttons["player-settings-row-0"]
        let speed = app.buttons["player-settings-row-2"]
        XCTAssertTrue(waitUntil { speed.hasFocus })
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { app.staticTexts["player-options-speed"].label == "1.55" })
        XCTAssertTrue(speed.hasFocus)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { rate.hasFocus && (rate.value as? String) == "1.55×" })
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { playback.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { zoom.hasFocus })
        XCUIRemote.shared.press(.select)
        let fit = app.buttons["player-option-row-10"]
        let fill = app.buttons["player-option-row-11"]
        let stretch = app.buttons["player-option-row-12"]
        let custom = app.buttons["player-settings-row-13"]
        XCTAssertTrue(waitUntil { fit.exists && fit.hasFocus })
        XCTAssertTrue(fit.label.contains("Normal"))
        XCTAssertEqual(fill.label, "Crop")
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { fill.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["player-zoom-mode"].label == "fill" && zoom.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { fill.exists && fill.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { stretch.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["player-zoom-mode"].label == "stretch" && zoom.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { stretch.exists && stretch.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { custom.hasFocus })
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitUntil { app.staticTexts["player-zoom-percent"].label == "99" })
        XCTAssertTrue(custom.hasFocus)
        XCTAssertTrue(fit.exists && fill.exists, "Custom adjusts in the same Zoom Mode list.")
        XCUIRemote.shared.press(.right, forDuration: 0.8)
        let percent = try XCTUnwrap(Int(app.staticTexts["player-zoom-percent"].label))
        XCTAssertGreaterThan(percent, 101)
        XCTAssertTrue(custom.hasFocus)
        XCTAssertEqual(app.staticTexts["subtitle-navigation-open-attempts"].label, "0")

        XCTAssertFalse(zoom.exists, "The Zoom Mode list replaces the parent menu.")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitUntil { app.staticTexts["player-options-play-pause"].label == "1" },
                      "The native input host must not swallow the player's Play/Pause command.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { zoom.exists && zoom.hasFocus && !speed.exists },
                      "Back returns to More with Zoom Mode focused; speed has its own button.")
        XCTAssertEqual(app.staticTexts["player-zoom-percent"].label, String(percent))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { app.staticTexts["player-options-panel-open"].label == "false" && playback.hasFocus },
                      "The next Back closes only the menu and restores its toolbar control.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { zoom.exists && zoom.hasFocus })
        XCTAssertEqual(app.staticTexts["player-zoom-mode"].label, "custom")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Production player Playback menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMovieAndBehindLiveToolbarsOpenMoreAndRestoreRemoteFocus() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        for live in [false, true] {
            app.launchArguments = ["--toolbar-footage"] + (live ? ["--library-channel-actions", "--preview"] :
                ["--subtitle-style-input-fixture", "--playback-options", "--production-player-input"])
            app.launch()
            if live {
                let watch = app.buttons["Watch channel"]
                XCTAssertTrue(waitUntil { watch.exists && watch.hasFocus }, app.debugDescription)
                XCUIRemote.shared.press(.select)
            }
            let audio = app.buttons[live ? "live-channel-audio" : "player-control-waveform"]
            let subtitles = app.buttons[live ? "live-channel-subtitles" : "player-control-captions.bubble"]
            let more = app.buttons[live ? "live-channel-playback" : "player-control-ellipsis"]
            let rate = app.buttons["player-control-speedometer"]
            let jump = app.buttons["live-channel-go-live"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertLessThan(audio.frame.maxX, subtitles.frame.minX)
            if live {
                XCTAssertTrue(jump.waitForExistence(timeout: 5))
                XCTAssertEqual(jump.label, "Jump to live")
                XCTAssertLessThan(jump.frame.maxX, audio.frame.minX)
                XCTAssertFalse(rate.exists)
            } else {
                XCTAssertLessThan(subtitles.frame.maxX, rate.frame.minX)
                XCTAssertLessThan(rate.frame.maxX, more.frame.minX)
                XCTAssertEqual(rate.value as? String, "1×")
            }
            XCUIRemote.shared.press(.up)
            for _ in 0..<4 where !more.hasFocus { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(waitUntil { more.hasFocus }, app.debugDescription)
            let name = live ? "live" : "movie"
            capture("\(name)-row")
            XCUIRemote.shared.press(.select)
            let zoom = app.buttons["player-settings-row-0"]
            let other = app.buttons[live ? "player-settings-row-6" : "player-settings-row-4"]
            XCTAssertTrue(waitUntil { zoom.exists && other.exists && (live ? other.hasFocus : zoom.hasFocus) }, app.debugDescription)
            XCTAssertFalse(app.buttons["player-settings-row-2"].exists)
            capture("\(name)-more")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(waitUntil { more.hasFocus && !zoom.exists }, app.debugDescription)
            if live {
                XCUIRemote.shared.press(.left)
                XCTAssertTrue(waitUntil { subtitles.hasFocus }, app.debugDescription)
                XCUIRemote.shared.press(.left)
                XCUIRemote.shared.press(.left)
                XCTAssertTrue(waitUntil { jump.hasFocus }, app.debugDescription)
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        ], timeout: 5) == .completed
    }
}
