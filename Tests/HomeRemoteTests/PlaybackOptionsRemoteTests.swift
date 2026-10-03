import XCTest

@MainActor
final class PlaybackOptionsRemoteTests: XCTestCase {
    func testRemoteInlineSpeedZoomSubmenuAndBackUseTheProductionPlayer() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--subtitle-style-input-fixture", "--production-player-input", "--playback-options"]
        app.launch()
        defer { app.terminate() }
        let playback = app.buttons["player-control-slider.horizontal.3"]
        XCTAssertTrue(playback.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitUntil { playback.hasFocus })
        XCUIRemote.shared.press(.select)

        let zoom = app.buttons["player-settings-row-0"]
        let amount = app.buttons["player-settings-row-20"]
        let speed = app.buttons["player-settings-row-2"]
        XCTAssertTrue(waitUntil { zoom.exists && zoom.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { speed.hasFocus })
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { app.staticTexts["player-options-speed"].label == "1.55" })
        XCTAssertTrue(speed.hasFocus)
        XCTAssertFalse(amount.exists)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(waitUntil { zoom.hasFocus })
        XCUIRemote.shared.press(.select)
        let fit = app.buttons["player-option-row-10"]
        let fill = app.buttons["player-option-row-11"]
        let custom = app.buttons["player-settings-row-12"]
        XCTAssertTrue(waitUntil { fit.exists && fit.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { fill.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { app.staticTexts["player-zoom-mode"].label == "fill" && zoom.hasFocus })
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(waitUntil { fill.exists && fill.hasFocus })
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(waitUntil { custom.hasFocus })
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(waitUntil { amount.exists && amount.hasFocus })
        XCUIRemote.shared.press(.right, forDuration: 0.8)
        let percent = try XCTUnwrap(Int(app.staticTexts["player-zoom-percent"].label))
        XCTAssertGreaterThan(percent, 101)
        XCTAssertTrue(amount.hasFocus)
        XCTAssertEqual(app.staticTexts["subtitle-navigation-open-attempts"].label, "0")

        XCTAssertFalse(zoom.exists, "Custom zoom has its own percentage screen.")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(waitUntil { app.staticTexts["player-options-play-pause"].label == "1" },
                      "The native input host must not swallow the player's Play/Pause command.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { custom.exists && custom.hasFocus },
                      "Back returns to the Zoom Mode list with Custom focused.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitUntil { zoom.exists && zoom.hasFocus && speed.exists && !amount.exists },
                      "Back returns to the same two Playback rows with Zoom Mode focused.")
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

    private func waitUntil(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        ], timeout: 5) == .completed
    }
}
