import UIKit
import XCTest

final class LiveTVSourceNavigationSmokeTests: XCTestCase {
    @MainActor
    func testPrimarySourceActionStaysFilledWithoutFocusInBothThemes() throws {
        for light in [false, true] {
            let app = launchFixture(arguments: ["--typed-settings"] + (light ? ["--light"] : []))
            defer { app.terminate() }
            guard select(app.buttons["fixture-live-tv-settings"], in: app) else { return }
            guard select(app.buttons["live-tv-add-playlist"], in: app) else { return }
            let action = app.buttons["live-tv-playlist-action"]
            guard focus(action, in: app),
                  focus(app.buttons["live-tv-add-guide"], in: app) else { return }
            XCTAssertFalse(action.hasFocus)
            let point = CGPoint(
                x: action.frame.minX + action.frame.width * 0.15, y: action.frame.midY
            )
            let fill = try screenshotPixel(at: point, in: app)
            for component in fill {
                if light { XCTAssertLessThan(component, 0.2, "Light theme needs an unfocused dark primary fill") }
                else { XCTAssertGreaterThan(component, 0.85, "Dark theme needs an unfocused bright primary fill") }
            }
            capture(light ? "iptv-primary-action-light-unfocused" : "iptv-primary-action-dark-unfocused", in: app)
            assertNoSourcesOrNetwork(in: app)
        }
    }

    @MainActor
    func testPlaylistControlsHaveGenerousBoundsAndGuidesCanBeAddedAndRemoved() {
        let app = launchFixture(arguments: ["--typed-settings"])
        defer { app.terminate() }
        guard select(app.buttons["fixture-live-tv-settings"], in: app) else { return }
        let addPlaylist = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCTAssertEqual(addPlaylist.label, "IPTV playlist")
        let server = app.buttons["live-tv-add-server"]
        XCTAssertEqual(server.label, "Media server")
        for row in [addPlaylist, server] {
            XCTAssertEqual(row.staticTexts.count, 1)
            XCTAssertLessThan(row.staticTexts.firstMatch.frame.height, 55)
        }
        capture("iptv-setup-source-options", in: app)
        XCUIRemote.shared.press(.right)
        guard select(addPlaylist, in: app) else { return }
        let playlist = app.textFields["live-tv-playlist-url"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(playlist.frame.height, 64)
        XCTAssertTrue(app.staticTexts["Playlist or live HLS URL"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 0)
        XCTAssertFalse(app.buttons["live-tv-remove-guide"].exists)
        let addGuide = app.buttons["live-tv-add-guide"]
        guard focus(addGuide, in: app) else { return }
        XCTAssertGreaterThanOrEqual(addGuide.frame.height, 64)
        XCTAssertGreaterThan(addGuide.frame.width, 500)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 1)
        let remove = app.buttons.matching(identifier: "live-tv-remove-guide").firstMatch
        guard focus(remove, in: app) else { return }
        XCTAssertGreaterThanOrEqual(remove.frame.height, 64)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 300)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 0)
        let save = app.buttons["live-tv-playlist-action"]
        guard select(save, in: app) else { return }
        XCTAssertTrue(app.staticTexts[
            "Enter a complete HTTP or HTTPS playlist URL, without a username or password before the hostname."
        ].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(save.frame.height, 64)
        capture("iptv-setup-validation", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testTypedSettingsEntryCanOpenPlaylistEditorAndReturnThroughBothPages() {
        let app = launchFixture(arguments: ["--typed-settings"])
        defer { app.terminate() }
        guard select(app.buttons["fixture-live-tv-settings"], in: app) else { return }
        let addPlaylist = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        guard select(addPlaylist, in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5), app.debugDescription)
        capture("settings-iptv-editor", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["fixture-live-tv-settings"].waitForExistence(timeout: 5), app.debugDescription)
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testEmptySetupOpensPlaylistFormAndBackWithoutLoadingSources() {
        let app = launchFixture()
        defer { app.terminate() }
        let welcome = app.staticTexts["Add your channels"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        assertNoPublicChannelOffer(in: app)
        XCTAssertFalse(app.staticTexts["No guide? No problem."].exists)
        assertNoSourcesOrNetwork(in: app)

        guard select(app.buttons["live-tv-setup-playlist"], in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Name (optional)"].exists)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(welcome.waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testServerSetupExplainsMissingAccountsWithoutOfferingChannels() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Add your channels"].waitForExistence(timeout: 10))

        assertNoPublicChannelOffer(in: app)
        guard select(app.buttons["live-tv-setup-server"], in: app) else { return }
        XCTAssertTrue(app.staticTexts["No connected Live TV servers"].waitForExistence(timeout: 5))
        assertNoPublicChannelOffer(in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["Add your channels"].waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSettingsSourcesPaneOpensEditorWithoutAnIntermediateManagementPage() {
        let app = launchFixture(arguments: ["--source-settings"])
        defer { app.terminate() }
        let addPlaylist = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage sources"].exists)
        XCTAssertFalse(app.staticTexts["No guide? No problem."].exists)
        XCUIRemote.shared.press(.right)
        guard select(addPlaylist, in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Auto preview"].exists)
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSettingsSourcesPaneCanToggleAndEditAnExistingSourceDirectly() {
        let app = launchFixture(arguments: ["--source-settings", "--configured-sources"])
        defer { app.terminate() }
        let enabled = app.switches["live-tv-source-enabled-fixture"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.right)
        guard select(enabled, in: app) else { return }
        let saved = NSPredicate(format: "label == %@", "Sources 1 writes 1 requests 0")
        expectation(for: saved, evaluatedWith: app.staticTexts["fixture-source-metrics"])
        waitForExpectations(timeout: 5)
        guard select(app.buttons["live-tv-edit-source-fixture"], in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["live-tv-playlist-url"].value as? String, "https://example.invalid/fixture.m3u")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-tv-remove-source-fixture"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Manage sources"].exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 1 requests 0")
    }

    @MainActor
    func testTypedSourcesDestinationCanPushPlaylistEditorAndReturn() {
        let app = launchFixture(arguments: ["--typed-sources"])
        defer { app.terminate() }

        guard select(app.buttons["fixture-sources"], in: app) else { return }
        let addPlaylist = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        assertNoPublicChannelOffer(in: app)
        guard select(addPlaylist, in: app) else { return }
        XCTAssertTrue(app.textFields["live-tv-playlist-url"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(addPlaylist.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["fixture-sources"].waitForExistence(timeout: 5))
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSetupCardsHaveEqualSizesAndAllActionsAreReachable() {
        let app = launchFixture(arguments: ["--setup-cards"])
        defer { app.terminate() }
        let cards = ["playlist", "server", "library"].map { app.buttons["live-tv-setup-\($0)"] }
        for card in cards { XCTAssertTrue(card.waitForExistence(timeout: 5)) }
        XCTAssertEqual(cards[2].label, "Enable Plozz channels")
        XCTAssertFalse(app.buttons["Create channel"].exists)
        let sizes = cards.map { card in
            let scale = card.hasFocus ? 1.025 : 1.0
            return CGSize(width: card.frame.width / scale, height: card.frame.height / scale)
        }
        for size in sizes.dropFirst() {
            XCTAssertEqual(size.width, sizes[0].width, accuracy: 2)
            XCTAssertEqual(size.height, sizes[0].height, accuracy: 2)
        }
        XCTAssertLessThan(cards[0].frame.maxX, cards[1].frame.minX)
        XCTAssertLessThan(cards[1].frame.maxX, cards[2].frame.minX)
        capture("live-setup-three-cards", in: app)
        for action in ["playlist", "server", "library"] {
            guard select(app.buttons["live-tv-setup-\(action)"], in: app) else { return }
            XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, action)
        }
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testSetupCardsStackAtNarrowWidthsAndAccessibilitySizes() {
        for arguments in [["--setup-compact"], ["--setup-accessibility"]] {
            let app = launchFixture(arguments: ["--setup-cards"] + arguments)
            let playlist = app.buttons["live-tv-setup-playlist"]
            let server = app.buttons["live-tv-setup-server"]
            XCTAssertTrue(playlist.waitForExistence(timeout: 5))
            XCTAssertTrue(server.exists)
            XCTAssertLessThan(playlist.frame.maxY, server.frame.minY)
            XCTAssertEqual(playlist.frame.midX, server.frame.midX, accuracy: 2)
            capture(arguments[0], in: app)
            guard select(app.buttons["live-tv-setup-library"], in: app) else {
                app.terminate()
                return
            }
            XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, "library")
            assertNoSourcesOrNetwork(in: app)
            app.terminate()
        }
    }

    @MainActor
    func testSetupCardsMirrorInRightToLeftAndRemainReadableInLightTheme() {
        let app = launchFixture(arguments: ["--setup-cards", "--rtl", "--light"])
        defer { app.terminate() }
        let playlist = app.buttons["live-tv-setup-playlist"]
        let library = app.buttons["live-tv-setup-library"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertTrue(library.exists)
        XCTAssertGreaterThan(playlist.frame.minX, library.frame.maxX)
        capture("live-setup-light-rtl", in: app)
        guard select(library, in: app) else { return }
        XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, "library")
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testEnablePlozzChannelsOpensManagementWithoutCreatingACustomChannel() {
        let app = launchFixture(arguments: ["--automatic-channels"])
        defer { app.terminate() }
        capture("automatic-welcome-enable", in: app)
        guard select(app.buttons["live-tv-setup-library"], in: app) else { return }
        let enabled = app.switches["live-tv-automatic-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5), app.debugDescription)
        let switchTitle = enabled.staticTexts["Enable Plozz channels"]
        XCTAssertTrue(switchTitle.exists)
        XCTAssertGreaterThan(
            switchTitle.frame.height, enabled.staticTexts["Off"].frame.height * 1.5,
            "The primary switch title must wrap rather than truncate in the compact management sheet.")
        XCTAssertTrue(app.buttons["live-tv-create-custom-channel"].exists)
        XCTAssertFalse(app.textFields["Channel name"].exists)
        XCTAssertEqual(app.staticTexts["fixture-automatic-metrics"].label, "Enabled false changes 0 retries 0")
        assertNoSourcesOrNetwork(in: app)
        capture("automatic-management-disabled-custom-secondary", in: app)

        guard select(enabled, in: app) else { return }
        assertAutomaticMetrics("Enabled true changes 1 retries 0", in: app)
        XCTAssertTrue(app.staticTexts["No Plozz channels yet"].waitForExistence(timeout: 5))
        capture("automatic-management-enabled-empty", in: app)
        guard select(enabled, in: app) else { return }
        assertAutomaticMetrics("Enabled false changes 2 retries 0", in: app)
        assertNoSourcesOrNetwork(in: app)
        capture("automatic-management-disabled-again", in: app)
        let custom = app.buttons["live-tv-create-custom-channel"]
        guard focus(custom, in: app) else { return }
        capture("automatic-management-custom-secondary-focused", in: app)
        guard select(custom, in: app) else { return }
        XCTAssertTrue(app.textFields["Channel name"].waitForExistence(timeout: 5))
        capture("automatic-optional-custom-editor", in: app)
        XCTAssertEqual(app.staticTexts["fixture-automatic-metrics"].label, "Enabled false changes 2 retries 0")
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testEnabledEmptyLineupDoesNotFallBackToDisabledSourcesOrWelcome() {
        let app = launchFixture(arguments: ["--automatic-channels", "--automatic-enabled"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No Plozz channels yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your sources are paused"].exists)
        XCTAssertFalse(app.buttons["live-tv-setup-library"].exists)
        capture("automatic-root-empty", in: app)
        guard select(app.buttons["live-tv-automatic-manage"], in: app) else { return }
        XCTAssertTrue(app.switches["live-tv-automatic-enabled"].waitForExistence(timeout: 5))
        guard select(app.buttons["live-tv-automatic-retry"], in: app) else { return }
        assertAutomaticMetrics("Enabled true changes 0 retries 1", in: app)
        assertNoSourcesOrNetwork(in: app)
        capture("automatic-management-empty-after-retry", in: app)
    }

    @MainActor
    func testPreparationShowsLibraryPageCountsAndWaitingStatus() {
        let app = launchFixture(arguments: [
            "--automatic-channels", "--automatic-enabled", "--automatic-working", "--automatic-progress"
        ])
        defer { app.terminate() }
        let library = app.staticTexts["live-tv-preparation-library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertEqual(library.label, "TV Shows")
        XCTAssertEqual(app.staticTexts["live-tv-preparation-page-count"].label, "750 of 2,400")
        XCTAssertEqual(app.staticTexts["live-tv-preparation-total"].label, "1,250 library items checked")
        XCTAssertTrue(app.staticTexts["live-tv-preparation-waiting"].exists)
        capture("automatic-preparation-real-progress", in: app)
        guard select(app.buttons["live-tv-automatic-manage"], in: app) else { return }
        XCTAssertTrue(app.staticTexts["live-tv-preparation-stage"].waitForExistence(timeout: 5))
        capture("automatic-preparation-management-progress", in: app)
        guard select(app.switches["live-tv-automatic-enabled"], in: app) else { return }
        assertAutomaticMetrics("Enabled false changes 1 retries 0", in: app)
        assertNoSourcesOrNetwork(in: app)
    }

    @MainActor
    func testPreparingAndFailureKeepAutomaticManagementReachable() {
        for state in ["--automatic-working", "--automatic-failure"] {
            let app = launchFixture(arguments: ["--automatic-channels", "--automatic-enabled", state])
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["live-tv-automatic-manage"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Your sources are paused"].exists)
            XCTAssertFalse(app.textFields["Channel name"].exists)
            capture(state == "--automatic-working" ? "automatic-root-preparing" : "automatic-root-error", in: app)
            guard select(app.buttons["live-tv-automatic-manage"], in: app) else { return }
            let enabled = app.switches["live-tv-automatic-enabled"]
            XCTAssertTrue(enabled.waitForExistence(timeout: 5))
            if state == "--automatic-working" {
                XCTAssertFalse(app.buttons["live-tv-automatic-retry"].exists)
                XCTAssertTrue(app.activityIndicators["live-tv-automatic-progress"].exists)
                capture("automatic-management-preparing", in: app)
                guard select(enabled, in: app) else { return }
                assertAutomaticMetrics("Enabled false changes 1 retries 0", in: app)
            } else {
                XCTAssertTrue(app.buttons["live-tv-automatic-retry"].exists)
                XCTAssertFalse(app.staticTexts["Your sources are paused"].exists)
                capture("automatic-management-error-retry", in: app)
            }
            assertNoSourcesOrNetwork(in: app)
        }
    }

    @MainActor
    func testSettingsKeepsPlozzManagementDiscoverableWithConfiguredIPTV() {
        let app = launchFixture(arguments: ["--source-settings", "--configured-sources", "--automatic-channels"])
        defer { app.terminate() }
        XCUIRemote.shared.press(.right)
        guard select(app.buttons["live-tv-manage-library-channels"], in: app) else { return }
        let enabled = app.switches["live-tv-automatic-enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        let custom = app.buttons["live-tv-create-custom-channel"]
        XCTAssertTrue(custom.exists)
        XCTAssertLessThan(enabled.frame.minY, custom.frame.minY)
        XCTAssertFalse(app.buttons["Create channel"].exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
        capture("automatic-management-with-iptv", in: app)
        guard select(enabled, in: app) else { return }
        assertAutomaticMetrics("Enabled true changes 1 retries 0", in: app)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
    }

    @MainActor
    private func assertAutomaticMetrics(_ expected: String, in app: XCUIApplication) {
        expectation(
            for: NSPredicate(format: "label == %@", expected),
            evaluatedWith: app.staticTexts["fixture-automatic-metrics"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["fixture-automatic-load-error"].exists)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func screenshotPixel(at point: CGPoint, in app: XCUIApplication) throws -> [Double] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let frame = app.windows.firstMatch.frame
        XCTAssertTrue(frame.contains(point))
        let x = ((point.x - frame.minX) * CGFloat(image.width) / frame.width).rounded(.down)
        let y = ((point.y - frame.minY) * CGFloat(image.height) / frame.height).rounded(.down)
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.interpolationQuality = .none
            context.translateBy(x: -x, y: -(CGFloat(image.height) - 1 - y))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return rgba.prefix(3).map { Double($0) / 255 }
    }

    @MainActor
    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--source-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-source-metrics"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertNoSourcesOrNetwork(in app: XCUIApplication) {
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 0 writes 0 requests 0")
        XCTAssertFalse(app.staticTexts["fixture-unexpected-playback"].exists)
        XCTAssertFalse(app.staticTexts["Profile settings unavailable"].exists)
    }

    @MainActor
    private func assertNoPublicChannelOffer(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["Try free channels"].exists)
        XCTAssertFalse(app.buttons["Try free US channels"].exists)
        XCTAssertFalse(app.buttons["Add free channels"].exists)
        XCTAssertFalse(app.staticTexts["Free channels"].exists)
    }

    @MainActor
    private func select(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        guard focus(button, in: app) else { return false }
        XCUIRemote.shared.press(.select)
        return true
    }

    @MainActor
    private func focus(_ button: XCUIElement, in app: XCUIApplication) -> Bool {
        guard button.waitForExistence(timeout: 5) else {
            XCTFail("Missing navigation control")
            return false
        }
        for _ in 0..<12 {
            let identifier = button.identifier.isEmpty ? button.label : button.identifier
            let focusedCell = app.cells.containing(.button, identifier: identifier)
                .allElementsBoundByIndex.contains(where: \.hasFocus)
            if button.hasFocus || focusedCell {
                return true
            }
            let focused = app.descendants(matching: .any).allElementsBoundByIndex.first(where: \.hasFocus)
            let target = button.frame
            if let focused, target.minX > focused.frame.maxX {
                XCUIRemote.shared.press(.right)
            } else if let focused, target.maxX < focused.frame.minX {
                XCUIRemote.shared.press(.left)
            } else if let focused, abs(target.midY - focused.frame.midY) < 40 {
                XCUIRemote.shared.press(target.midX < focused.frame.midX ? .left : .right)
            } else {
                XCUIRemote.shared.press(target.midY < (focused?.frame.midY ?? 0) ? .up : .down)
            }
        }
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Could not focus navigation control \(button.label)")
        return false
    }
}
