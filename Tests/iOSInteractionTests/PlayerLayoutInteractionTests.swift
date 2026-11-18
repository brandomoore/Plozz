import UIKit
import XCTest

@MainActor
final class PlayerLayoutInteractionTests: XCTestCase {
    func testContinueWatchingArtworkAndPaddingSelectTheCard() {
        assertContinueWatchingCardTaps(options: [])
    }

    func testContinueWatchingBorderlessHiddenLabelsStillSelectTheCard() {
        assertContinueWatchingCardTaps(options: ["--cw-borderless", "--cw-hide-labels"])
    }

    private func assertContinueWatchingCardTaps(options: [String]) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            for artwork in [[], ["--cw-thumbnail"], ["--cw-portrait-artwork"]] {
                XCUIDevice.shared.orientation = orientation
                app.launchArguments = ["--player-layout-fixture", "--continue-watching-player-fixture"] + options + artwork
                app.launch()
                wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == orientation.isLandscape
                }, object: nil)], timeout: 10)
                let tab = app.buttons["player-tab-continue-watching"]
                XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
                tab.tap()
                let cards = app.otherElements.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "player-continue-watching-"
                ))
                XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                var selections = 0
                for (index, provider) in ["plex", "silo"].enumerated() {
                    let card = cards.element(boundBy: index)
                    XCTAssertTrue(card.isHittable, app.debugDescription)
                    let vertical = card.frame.width > card.frame.height * 3
                    let points: [CGVector] = vertical
                        ? [.init(dx: 0.08, dy: 0.5), .init(dx: 0.9, dy: 0.5)]
                        : [.init(dx: 0.5, dy: 0.25), .init(dx: 0.5, dy: 0.9), .init(dx: 0.02, dy: 0.5)]
                    for point in points {
                        card.coordinate(withNormalizedOffset: point).tap()
                        selections += 1
                        XCTAssertTrue(app.staticTexts["player-cw-selection"].wait(
                            for: \.label, toEqual: "\(provider)-continue:\(selections)", timeout: 3
                        ), "The card must own taps on its artwork and padding: \(orientation), \(artwork), \(options), \(point).")
                        XCTAssertTrue(card.exists, "A card tap must not fall through and dismiss the player controls.")
                    }
                }
                app.terminate()
            }
        }
    }

    func testChapterOpeningDoesNotFadeUntilARealScrollAndResetsOnReopen() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--player-layout-fixture", "--chapter-scroll-fixture"]
        app.launch()
        defer { app.terminate() }
        let tab = app.buttons["player-tab-chapters"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        for opening in 0..<2 {
            tab.tap()
            let panel = app.descendants(matching: .any)["player-chapters"].firstMatch
            let current = app.buttons["player-chapter-6"]
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                panel.exists && abs(current.frame.minY - panel.frame.minY) < 1
            }, object: nil)], timeout: 5)
            capture(app, name: "Chapter opening \(opening) at current chapter")
            let frame = panel.frame
            let originalY = current.frame.minY
            func band(_ offset: CGFloat) -> CGRect {
                CGRect(x: frame.maxX - 30, y: frame.minY + offset, width: 4, height: 2)
            }
            let initial = XCUIScreen.main.screenshot().image
            let backdrop = try brightness(initial, in: band(-6), screen: app.frame)
            let top = try brightness(initial, in: band(2), screen: app.frame)
            let interior = try brightness(initial, in: band(23), screen: app.frame)
            XCTAssertGreaterThan(backdrop - top, (backdrop - interior) * 0.85,
                                 "The current chapter must open fully opaque, including after reopening.")

            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + 100))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(
                    CGVector(dx: frame.midX, dy: frame.minY + 80)
                ), withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertLessThan(current.frame.minY, originalY - 5, "Exercise a real scroll, not just a touch.")
            capture(app, name: "Chapter opening \(opening) after manual scroll")
            let scrolled = XCUIScreen.main.screenshot().image
            let edge = try brightness(scrolled, in: band(2), screen: app.frame)
            let middle = try brightness(scrolled, in: band(12), screen: app.frame)
            let inner = try brightness(scrolled, in: band(23), screen: app.frame)
            XCTAssertGreaterThan(edge, middle + 0.02)
            XCTAssertGreaterThan(middle, inner + 0.02, "A real scroll must enable the progressive top fade.")
            tab.tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        }
    }

    func testLiveHeaderKeepsIdentityAndTimelineStableAcrossPlaybackStates() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for (hasProgram, scheduled) in [(true, false), (false, false), (false, true)] {
                app.launchArguments = ["--player-layout-fixture", "--live-player", "--cycle-live-phase", "--light"]
                if !hasProgram { app.launchArguments.append("--no-guide-program") }
                if scheduled { app.launchArguments.append("--scheduled-channel") }
                app.launch()
                let title = app.staticTexts["live-channel-program-title"]
                XCTAssertTrue(title.waitForExistence(timeout: 10))
                wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == orientation.isLandscape
                }, object: nil)], timeout: 10)
                let channel = app.staticTexts["live-channel-name"]
                XCTAssertEqual(channel.exists, hasProgram)
                XCTAssertEqual(title.label, hasProgram ? "Evening News" : "Sample Channel")
                let originalTitle = title.frame
                let originalChannel = hasProgram ? channel.frame : originalTitle
                let scrubber = app.descendants(matching: .any)["live-channel-timeline-scrubber"].firstMatch
                let originalTimeline = scrubber.frame
                let header = app.descendants(matching: .any)["live-channel-title-block"].firstMatch
                XCTAssertEqual(header.images.count, 0, "Artwork belongs in the panels, not the compact header.")
                XCTAssertEqual(originalTitle.minX, app.buttons["live-channel-info"].frame.minX, accuracy: 1)
                XCTAssertEqual(originalChannel.minX, originalTitle.minX, accuracy: 1)
                if hasProgram {
                    XCTAssertGreaterThanOrEqual(originalTitle.minY - originalChannel.maxY, 3)
                }
                let next = app.buttons["fixture-next-live-phase"]
                for index in 0...10 {
                    if index > 0 {
                        next.tap()
                        wait(for: [XCTNSPredicateExpectation(
                            predicate: NSPredicate(format: "value == %@", "\(index)"), object: next
                        )], timeout: 5)
                    }
                    let position = app.staticTexts["live-channel-position"]
                    let visible = index == 0 || index >= 8
                    XCTAssertEqual(position.exists, visible, "Position badge at playback phase \(index).")
                    if visible {
                        let delayed = index == 8 || index == 9
                        XCTAssertEqual(position.label, scheduled
                            ? (delayed ? "DELAYED" : "ON NOW")
                            : (delayed ? "BEHIND LIVE" : "LIVE"))
                        XCTAssertGreaterThan(position.frame.minX, (hasProgram ? channel : title).frame.maxX)
                    }
                    XCTAssertEqual(title.frame, originalTitle)
                    if hasProgram { XCTAssertEqual(channel.frame, originalChannel) }
                    XCTAssertEqual(scrubber.frame, originalTimeline)
                    for text in ["CONNECTING", "BUFFERING", "SEEKING", "RECONNECTING", "PAUSED", "PLAYBACK ERROR", "PLAYBACK ENDED"] {
                        XCTAssertFalse(header.staticTexts[text].exists)
                    }
                    if index == 0 || index == 1 || index == 8 {
                        capture(app, name: "Live header \(orientation) guide-\(hasProgram) scheduled-\(scheduled) phase-\(index)")
                    }
                }
                app.terminate()
            }
        }
    }

    func testLivePanelsKeepTabSeparationInPortrait() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--player-layout-fixture", "--live-player", "--light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-channel-info"].waitForExistence(timeout: 10))
        for (tab, panel) in [
            ("live-channel-info", "live-channel-info-panel"),
            ("live-channel-on-now", "live-channel-on-now-other"),
            ("live-channel-guide", "live-channel-guide-panel")
        ] {
            let button = app.buttons[tab]
            button.tap()
            let card = app.descendants(matching: .any)[panel].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(card.frame.minY - button.frame.maxY, 11.5)
            XCTAssertGreaterThan(button.frame.minY, app.buttons["live-channel-close"].frame.maxY)
            capture(app, name: "Live portrait \(tab) separation")
        }
    }

    func testLiveAndVODUseMatchingNativeControlsAndEdgeSpacingAfterRotation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            var reference: [CGRect] = []
            for live in [false, true] {
                app.launchArguments = ["--player-layout-fixture", "--light"]
                if live { app.launchArguments.append("--live-player") }
                app.launch()
                let close = app.buttons[live ? "live-channel-close" : "Close player"]
                XCTAssertTrue(close.waitForExistence(timeout: 10))
                let landscape = orientation.isLandscape
                wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == landscape
                        && (landscape ? close.frame.minY < 40 : close.frame.minX < 40)
                }, object: nil)], timeout: 10)
                let names = live
                    ? ["live-channel-previous", "live-channel-play-pause", "live-channel-next"]
                    : ["Skip backward", "Play", "Skip forward"]
                let frames = names.map { app.buttons[$0].frame }
                let info = app.buttons[live ? "live-channel-info" : "Info"]
                XCTAssertTrue(info.exists)
                if live {
                    XCTAssertEqual(frames, Array(reference.prefix(3)))
                    XCTAssertEqual(close.frame, reference[3])
                    XCTAssertEqual(info.frame, reference[4])
                    let title = app.staticTexts["live-channel-program-title"].frame
                    for frame in frames { XCTAssertFalse(frame.intersects(title)) }
                    let scrubber = app.descendants(matching: .any)["live-channel-timeline-scrubber"].firstMatch
                    XCTAssertTrue(scrubber.exists)
                    XCTAssertGreaterThanOrEqual(scrubber.frame.height, 44)
                    let current = app.descendants(matching: .any)["live-timeline-current-time"].firstMatch.frame
                    let end = app.descendants(matching: .any)["live-timeline-end-time"].firstMatch.frame
                    XCTAssertEqual(current.midY, scrubber.frame.midY, accuracy: 1)
                    XCTAssertEqual(end.midY, scrubber.frame.midY, accuracy: 1)
                    XCTAssertEqual(scrubber.frame.minX - current.maxX, 4, accuracy: 1)
                    XCTAssertEqual(end.minX - scrubber.frame.maxX, 4, accuracy: 1)
                } else {
                    reference = frames + [close.frame, info.frame]
                }
                if app.frame.size == CGSize(width: 956, height: 440)
                    || app.frame.size == CGSize(width: 440, height: 956) {
                    XCTAssertEqual(close.frame.minY, landscape ? 24 : 62, accuracy: 1)
                    XCTAssertEqual(app.frame.maxY - info.frame.maxY, landscape ? 24 : 34, accuracy: 1)
                }
                capture(app, name: "\(live ? "Live" : "VOD") real \(landscape ? "landscape" : "portrait") geometry")
                attachMeasurements(["window \(app.frame)", "close \(close.frame)", "info \(info.frame)", "center \(frames)"])
                app.terminate()
            }
        }
    }

    func testLiveInlineTimelineSeeksWithinTheBarAndPreservesChannelActions() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--player-layout-fixture", "--live-player", "--light"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let play = app.buttons["live-channel-play-pause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertEqual(play.label, "Play")
        play.tap()
        XCTAssertEqual(play.label, "Pause")
        let fixture = app.descendants(matching: .any)["live-player-layout-fixture"].firstMatch
        app.buttons["live-channel-next"].tap()
        XCTAssertTrue((fixture.value as? String)?.hasPrefix("channel:1,") == true)
        app.buttons["live-channel-previous"].tap()
        XCTAssertTrue((fixture.value as? String)?.hasPrefix("channel:0,") == true)
        let scrubber = app.descendants(matching: .any)["live-channel-timeline-scrubber"].firstMatch
        let original = scrubber.frame
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(scrubber.frame, original)
        let value = fixture.value as? String ?? ""
        let landing = Int(value.components(separatedBy: "behind:").last?.components(separatedBy: ",").first ?? "")
        // The bar spans one hour of history plus the programme's remaining 15 minutes.
        XCTAssertEqual(Double(landing ?? -1), 3600 - 4500 * 0.25, accuracy: 20)
        XCTAssertTrue(value.hasSuffix("scrubs:1"))
        app.buttons["live-channel-go-live"].tap()
        XCTAssertTrue((fixture.value as? String)?.contains("behind:0,") == true)
    }

    func testNativeFullscreenPlayerEdgeReferenceAfterRotation() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["--player-layout-fixture", "--native-avkit", "--light"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let fullscreen = app.buttons["Fullscreen Button"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10))
        fullscreen.tap()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.frame.width > app.frame.height) == orientation.isLandscape
            }, object: nil)], timeout: 10)
            if !app.buttons["Play"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            }
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
            if app.frame.size == CGSize(width: 956, height: 440)
                || app.frame.size == CGSize(width: 440, height: 956) {
                XCTAssertEqual(
                    app.buttons["Close Button"].frame.midY, orientation.isLandscape ? 46 : 84, accuracy: 1
                )
                XCTAssertEqual(
                    app.frame.maxY - app.sliders["Current position"].frame.midY - 22,
                    orientation.isLandscape ? 24 : 34, accuracy: 1
                )
            }
            capture(app, name: "Native AVKit fullscreen edge reference \(orientation.isLandscape ? "landscape" : "portrait")")
            attachMeasurements([app.debugDescription])
        }
    }

    func testLivePanelsUseNativeMediaGlassInBothAppearances() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for appearance in ["light", "dark"] {
            for empty in [false, true] {
                app.launchArguments = ["--player-layout-fixture", "--live-player", "--\(appearance)"]
                if empty { app.launchArguments.append("--empty-on-now") }
                app.launch()
                XCTAssertTrue(app.buttons["live-channel-info"].waitForExistence(timeout: 10))
                for (tab, panel) in [
                    ("live-channel-info", "live-channel-info-panel"),
                    ("live-channel-on-now", empty ? "live-channel-on-now-empty" : "live-channel-on-now-other"),
                    ("live-channel-guide", "live-channel-guide-panel")
                ] {
                    app.buttons[tab].tap()
                    let card = app.descendants(matching: .any)[panel].firstMatch
                    XCTAssertTrue(card.waitForExistence(timeout: 5))
                    XCTAssertGreaterThanOrEqual(card.frame.minY - app.buttons[tab].frame.maxY, 11.5)
                    capture(app, name: "Live \(tab) \(appearance) \(empty ? "empty" : "populated")")
                    attachMeasurements(["\(tab): \(card.frame), window: \(app.frame)"])
                    XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX)
                    XCTAssertLessThanOrEqual(card.frame.maxY, app.frame.maxY)
                    let padding = CGRect(x: card.frame.maxX - 16, y: card.frame.midY - 10, width: 8, height: 20)
                    XCTAssertLessThan(
                        try brightness(XCUIScreen.main.screenshot().image, in: padding, screen: app.frame), 0.4,
                        "Live panels must not retain regular glass's pale backing over black video."
                    )
                    if tab == "live-channel-info" {
                        let action = app.buttons["live-channel-playback-info"]
                        XCTAssertTrue(action.isHittable)
                        let ink = try visibleBounds(
                            uprightImage(XCUIScreen.main.screenshot().image, screen: app.frame),
                            in: action.frame.insetBy(dx: 8, dy: 8), screen: app.frame, threshold: 200
                        )
                        XCTAssertGreaterThan(ink.width, 8, "Secondary actions need the main player's light foreground.")
                        XCTAssertGreaterThan(ink.height, 8)
                    } else if tab == "live-channel-guide" {
                        XCTAssertFalse(card.staticTexts["Evening News"].exists)
                        let heading = card.staticTexts["Channels"].firstMatch
                        XCTAssertTrue(heading.exists)
                        XCTAssertLessThan(heading.frame.minX - card.frame.minX, card.frame.width * 0.2)
                        let station = card.buttons.matching(
                            NSPredicate(format: "identifier BEGINSWITH %@", "live-tv-channel-channels-")
                        ).firstMatch
                        XCTAssertTrue(station.exists)
                        XCTAssertLessThanOrEqual(station.frame.height, 65, "Full-width phone guides keep compact rows.")
                        let ink = try visibleBounds(
                            uprightImage(XCUIScreen.main.screenshot().image, screen: app.frame),
                            in: heading.frame, screen: app.frame, threshold: 128
                        )
                        XCTAssertGreaterThan(ink.width, 30, "Guide headings need light ink over media glass.")
                        XCTAssertGreaterThan(ink.height, 8)
                    }
                }
                app.terminate()
            }
        }
    }

    func testPlaybackMenuKeepsNativeMediaContrastInBothAppearances() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        var levels: [Double] = []
        for appearance in ["light", "dark"] {
            for backdrop in ["black", "white", "video"] {
                XCUIDevice.shared.orientation = backdrop == "video" ? .landscapeLeft : .portrait
                app.launchArguments = ["--player-layout-fixture", "--playback-menu", "--\(appearance)"]
                if backdrop == "white" { app.launchArguments.append("--white-video") }
                if backdrop == "video" { app.launchArguments.append("--video") }
                app.launch()
                let options = app.buttons["player-playback-options"]
                XCTAssertTrue(options.waitForExistence(timeout: 10))
                options.tap()
                let speed = app.buttons["Playback Speed"]
                XCTAssertTrue(speed.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Audio"].exists)
                XCTAssertTrue(app.buttons["Zoom Mode"].exists)
                XCTAssertFalse(app.buttons["Playback Sync"].exists)
                capture(app, name: "Plozz native menu \(appearance) \(backdrop) video")
                if backdrop == "black" {
                    let image = XCUIScreen.main.screenshot().image
                    let interior = speed.frame.insetBy(dx: 12, dy: 6)
                    let level = try brightness(image, in: interior, screen: app.frame)
                    levels.append(level)
                    XCTAssertLessThan(level, 0.45, "The media menu must not become a white-tinted surface in Light mode.")
                    let ink = try visibleBounds(image, in: interior, screen: app.frame, threshold: 200)
                    XCTAssertGreaterThan(ink.width, 80, "The native menu's title must retain light ink.")
                    XCTAssertLessThan(ink.height, interior.height - 2, "Measure label ink, not a pale menu background.")
                }
                speed.tap()
                XCTAssertTrue(app.navigationBars["Playback Speed"].waitForExistence(timeout: 5))
                app.buttons["Done"].tap()
                XCTAssertTrue(app.navigationBars["Playback Speed"].waitForNonExistence(timeout: 5))
                XCTAssertTrue(options.waitForExistence(timeout: 5))
                options.tap()
                XCTAssertTrue(app.buttons["Playback Speed"].waitForExistence(timeout: 5))
                app.terminate()
            }
        }
        XCTAssertEqual(levels[0], levels[1], accuracy: 0.08)
    }

    func testSyncControlsLiveInsideSubtitlesAndRespectCapabilities() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer { app.terminate() }
        for (subtitles, audio, speed) in [
            (true, false, true), (false, true, true), (true, true, true), (false, false, true), (true, true, false)
        ] {
            app.launchArguments = ["--player-layout-fixture"]
            if subtitles { app.launchArguments.append("--subtitle-delay") }
            if audio { app.launchArguments.append("--audio-delay") }
            if !speed { app.launchArguments.append("--no-playback-speed") }
            app.launch()
            XCTAssertTrue(app.buttons["Subtitles"].waitForExistence(timeout: 10))
            let options = app.buttons["player-playback-options"]
            if speed {
                XCTAssertTrue(options.exists)
                options.tap()
                XCTAssertTrue(app.buttons["Playback Speed"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["Playback Sync"].exists)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            } else {
                XCTAssertFalse(options.exists, "Moving sync must not leave an empty playback-options button.")
            }
            app.buttons["Subtitles"].tap()
            XCTAssertTrue(app.navigationBars["Subtitles"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.sliders["player-subtitle-delay"].exists, subtitles)
            XCTAssertEqual(app.sliders["player-audio-delay"].exists, audio)
            var values: [String: String] = [:]
            for identifier in ["player-subtitle-delay", "player-audio-delay"] where app.sliders[identifier].exists {
                let slider = app.sliders[identifier]
                let original = slider.value as? String
                slider.adjust(toNormalizedSliderPosition: 0.75)
                XCTAssertNotEqual(slider.value as? String, original)
                values[identifier] = slider.value as? String
            }
            app.buttons["Done"].tap()
            app.buttons["Subtitles"].tap()
            for (identifier, value) in values {
                XCTAssertEqual(app.sliders[identifier].value as? String, value)
            }
            app.terminate()
        }
    }

    func testBackgroundingCancelsScrubPresentation() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        XCUIDevice.shared.orientation = .portrait
        defer { app.terminate() }
        for playing in [false, true] {
            app.launchArguments = ["--player-layout-fixture", "--scrubbing"]
            if playing { app.launchArguments.append("--playing") }
            app.launch()
            let transport = app.buttons[playing ? "Pause" : "Play"]
            XCTAssertTrue(app.buttons["player-timeline-current-time"].waitForExistence(timeout: 10))
            XCTAssertFalse(transport.exists)
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(transport.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Info"].exists)
            XCTAssertTrue(app.buttons["player-timeline-current-time"].exists)
            if playing {
                wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !transport.exists
                }, object: nil)], timeout: 8)
            }
            app.terminate()
        }
    }

    func testScrubbingShowsOnlyTimelineAndRestoresControlsWithoutMovingIt() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.launchArguments = ["--player-layout-fixture", "--scrubbing", "--light"]
            app.launch()
            let current = app.buttons["player-timeline-current-time"]
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            let scrubber = app.descendants(matching: .any)["player-timeline-scrubber"].firstMatch
            let original = scrubber.frame
            XCTAssertTrue(app.buttons["player-timeline-end-time"].exists)
            for label in ["Close player", "Play", "Skip backward", "Skip forward", "Subtitles", "Info", "Cast"] {
                XCTAssertFalse(app.buttons[label].exists, "\(label) must not remain accessible while scrubbing.")
            }
            XCTAssertFalse(app.staticTexts["Wayward"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["player-track-controls"].firstMatch.exists)
            XCTAssertEqual(app.buttons.count, 2, "Only the two timestamp labels should remain in the control tree.")
            capture(app, name: "Timeline-only scrubbing \(orientation.rawValue)")
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)
                ))
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Info"].exists)
            XCTAssertEqual(scrubber.frame, original, "Scrub completion must not move the finger's target.")
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)
                ))
            let probe = app.descendants(matching: .any)["player-layout-fixture"].firstMatch
            XCTAssertEqual(probe.value as? String, "scrubbing:false,starts:1",
                           "A real drag must enter and leave the same scrub state used by the overlay.")
            XCTAssertEqual(scrubber.frame, original)
            app.terminate()
        }
    }

    func testInfoAndCastDoNotAddALightBackingOverDarkVideo() throws {
        try assertInfoAndCastAppearance(whiteVideo: false)
    }

    func testInfoAndCastRemainReadableOverBrightVideo() throws {
        try assertInfoAndCastAppearance(whiteVideo: true)
    }

    private func assertInfoAndCastAppearance(whiteVideo: Bool) throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        let backdrop = whiteVideo ? "white" : "black"
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for appearance in ["light", "dark"] {
                app.launchArguments = ["--player-layout-fixture", "--\(appearance)"]
                if whiteVideo { app.launchArguments.append("--white-video") }
                app.launch()
                XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 10))
                app.buttons["Info"].tap()
                let title = app.staticTexts["Now Playing"]
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                capture(app, name: "Info \(appearance) \(orientation.rawValue) over \(backdrop) video")
                let titleFrame = title.frame
                let infoImage = uprightImage(XCUIScreen.main.screenshot().image, screen: app.frame)
                let infoBackground = try brightness(infoImage, in: CGRect(
                    x: titleFrame.minX - 8, y: titleFrame.midY - 2, width: 4, height: 4
                ), screen: app.frame)
                XCTAssertLessThan(infoBackground, whiteVideo ? 0.8 : 0.45,
                                  "Info must retain separation between the dimmed video and light text.")
                let infoInk = try visibleBounds(infoImage, in: titleFrame,
                                                screen: app.frame, threshold: 230)
                XCTAssertGreaterThan(infoInk.width, 20, "Info must retain legible video-overlay text.")
                app.buttons["Cast"].tap()
                let face = app.buttons["player-cast-face-actor"]
                XCTAssertTrue(face.waitForExistence(timeout: 5))
                capture(app, name: "Cast \(appearance) \(orientation.rawValue) over \(backdrop) video")
                let faceFrame = face.frame
                let castImage = uprightImage(XCUIScreen.main.screenshot().image, screen: app.frame)
                let castBackground = try brightness(castImage, in: CGRect(
                    x: faceFrame.minX + 8, y: faceFrame.midY - 2, width: 4, height: 4
                ), screen: app.frame)
                XCTAssertLessThan(castBackground, whiteVideo ? 0.8 : 0.45,
                                  "Cast must use the same unpainted video surface as Info.")
                let castInk = try visibleBounds(castImage, in: app.staticTexts["Actor"].firstMatch.frame,
                                                screen: app.frame, threshold: 230)
                XCTAssertGreaterThan(castInk.width, 20, "Cast names must remain readable in Light mode.")
                face.tap()
                XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
                capture(app, name: "Cast detail \(appearance) \(orientation.rawValue) over \(backdrop) video")
                app.buttons["Back"].tap()
                XCTAssertTrue(face.waitForExistence(timeout: 5))
                app.terminate()
            }
        }
    }

    func testPlaybackRolloversDoNotMoveTheScrubber() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer { app.terminate() }
        for longVideo in [false, true] {
            app.launchArguments = ["--player-layout-fixture", "--timeline-rollovers"]
            if longVideo { app.launchArguments.append("--long-video") }
            app.launch()
            let current = app.buttons["player-timeline-current-time"]
            let remaining = app.buttons["player-timeline-end-time"]
            let advance = app.buttons["fixture-next-time"]
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            let scrubber = app.descendants(matching: .any)["player-timeline-scrubber"].firstMatch
            let currentFrame = current.frame
            let remainingFrame = remaining.frame
            let scrubberFrame = scrubber.frame
            for step in 1...(longVideo ? 10 : 6) {
                advance.tap()
                wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    advance.value as? String == "\(step)"
                }, object: nil)], timeout: 5)
                XCTAssertEqual(current.frame, currentFrame)
                XCTAssertEqual(remaining.frame, remainingFrame)
                XCTAssertEqual(scrubber.frame, scrubberFrame,
                               "Playback ticks must not move or resize the actual scrubber hit target.")
            }
            XCTAssertEqual(current.value as? String, longVideo ? "1:30:00" : "20:00")
            XCTAssertEqual(remaining.value as? String, longVideo ? "-0:00:00" : "-00:00")
            app.terminate()
        }
    }

    func testTimeLabelsUseTheVideoDurationFromTheStart() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer { app.terminate() }
        for longVideo in [false, true] {
            app.launchArguments = ["--player-layout-fixture"]
            if longVideo { app.launchArguments.append("--long-video") }
            app.launch()
            let current = app.buttons["player-timeline-current-time"]
            let remaining = app.buttons["player-timeline-end-time"]
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            XCTAssertEqual(current.value as? String, longVideo ? "0:10:00" : "10:00")
            XCTAssertEqual(remaining.value as? String, longVideo ? "-1:20:00" : "-10:00")
            capture(app, name: longVideo ? "Hour-plus timeline" : "Short episode timeline")
            app.terminate()
        }
    }

    func testNativeAVKitPlayerAppearanceInLightAndDark() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            app.launchArguments = ["--player-layout-fixture", "--native-avkit", "--\(appearance)"]
            app.launch()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
            capture(app, name: "AVKit native \(appearance)")
            attachMeasurements([app.debugDescription])
            app.terminate()
        }
    }

    func testPlayerLayoutAppearanceOverVideo() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for appearance in ["light", "dark"] {
            app.launchArguments = ["--player-layout-fixture", "--video", "--\(appearance)"]
            app.launch()
            XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 10))
            capture(app, name: "Plozz \(appearance) controls over video portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height
            }, object: nil)], timeout: 10)
            capture(app, name: "Plozz \(appearance) controls over video landscape")
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testLightControlsRemainLegibleOverWhiteVideo() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--player-layout-fixture", "--white-video", "--light"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
        capture(app, name: "Plozz light controls over white video")
        let image = XCUIScreen.main.screenshot().image
        for name in ["Play", "Skip backward", "Skip forward"] {
            let ink = try visibleBounds(image, in: app.buttons[name].frame.insetBy(dx: 12, dy: 12),
                                        screen: app.frame, threshold: 230)
            XCTAssertGreaterThan(ink.width, 20, "\(name) must retain visible white ink over bright video.")
            XCTAssertGreaterThan(ink.height, 20)
        }
    }

    func testNativePlayerGeometryMatchesReferenceAndSurvivesRotation() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--player-layout-fixture"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
                && app.buttons["Close player"].frame.minY < 40
        }, object: nil)], timeout: 10)
        capture(app, name: "Native player landscape")
        var measurements: [String] = []
        for name in ["Close player", "Skip backward", "Play", "Skip forward", "Info", "Cast", "Episodes", "Playlist", "Subtitles"] {
            let button = app.buttons[name]
            XCTAssertTrue(button.exists, name)
            measurements.append("\(name): \(button.frame)")
        }
        let timeline = app.descendants(matching: .any)["player-timeline"].firstMatch.frame
        measurements.append("timeline: \(timeline)")
        let play = app.buttons["Play"].frame
        let compact = app.frame.height < 400
        XCTAssertEqual(play.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(play.midY, app.frame.midY, accuracy: 1)
        XCTAssertEqual(play.width, compact ? 44 : 92, accuracy: 1)
        XCTAssertEqual(app.buttons["Skip backward"].frame.midX, play.midX - (compact ? 64 : 146), accuracy: 1)
        XCTAssertEqual(app.buttons["Skip forward"].frame.midX, play.midX + (compact ? 64 : 146), accuracy: 1)
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any)["player-timeline-scrubber"].firstMatch.frame.height, 44
        )
        if app.frame.size == CGSize(width: 956, height: 440) {
            let close = app.buttons["Close player"].frame
            XCTAssertEqual(close.minX, 62, accuracy: 1)
            XCTAssertEqual(close.minY, 24, accuracy: 1)
            XCTAssertEqual(close.width, 44, accuracy: 1)
            let info = app.buttons["Info"].frame
            XCTAssertEqual(info.minX, 62, accuracy: 1)
            XCTAssertEqual(info.minY, 372, accuracy: 1)
            XCTAssertEqual(info.height, 44, accuracy: 1)
            XCTAssertEqual(info.width, 56, accuracy: 1)
            XCTAssertEqual(timeline.midY, 353, accuracy: 1)
        }
        attachMeasurements(measurements)
        XCUIDevice.shared.orientation = .portrait
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width < app.frame.height
                && app.buttons["Close player"].frame.minX < 40
        }, object: nil)], timeout: 10)
        capture(app, name: "Native player portrait")
        XCTAssertEqual(app.buttons["Play"].frame.midY, app.frame.midY, accuracy: 1)
        XCTAssertTrue(app.buttons["Skip backward"].isHittable)
        XCTAssertTrue(app.buttons["Skip forward"].isHittable)
        XCTAssertTrue(app.buttons["Subtitles"].isHittable)
        XCTAssertTrue(app.buttons["player-playback-options"].isHittable)
        if app.frame.size == CGSize(width: 440, height: 956) {
            XCTAssertEqual(app.buttons["Close player"].frame.minX, 21, accuracy: 1)
            XCTAssertEqual(app.buttons["Close player"].frame.minY, 62, accuracy: 1)
            XCTAssertEqual(app.buttons["Skip backward"].frame.midX, 103, accuracy: 1)
            XCTAssertEqual(app.buttons["Skip forward"].frame.midX, 337, accuracy: 1)
            XCTAssertEqual(app.buttons["Info"].frame.minX, 21, accuracy: 1)
            XCTAssertEqual(app.buttons["Info"].frame.minY, 878, accuracy: 1)
            XCTAssertEqual(app.descendants(matching: .any)["player-timeline"].firstMatch.frame.midY, 859, accuracy: 1)
            let info = app.buttons["Info"].frame
            let image = XCUIScreen.main.screenshot().image
            let glass = try visibleBounds(image, in: info, screen: app.frame, threshold: 20)
            XCTAssertEqual(glass.width, 56, accuracy: 1)
            XCTAssertEqual(glass.height, 42, accuracy: 1,
                           "Compare the visible glass, not the outer touch target.")
            let ink = try visibleBounds(image, in: info, screen: app.frame, threshold: 180)
            XCTAssertEqual(ink.width, 25.3, accuracy: 1)
            XCTAssertEqual(ink.height, 11, accuracy: 1)
            let current = app.buttons["player-timeline-current-time"].frame
            let end = app.buttons["player-timeline-end-time"].frame
            let scrubber = app.descendants(matching: .any)["player-timeline-scrubber"].firstMatch.frame
            XCTAssertEqual(current.width, 44, accuracy: 1)
            XCTAssertEqual(end.width, 44, accuracy: 1)
            XCTAssertEqual(scrubber.width, 302, accuracy: 1,
                           "Unused long-duration time columns must not squeeze the portrait track.")
            XCTAssertEqual(scrubber.minX - current.maxX, 4, accuracy: 1)
            XCTAssertEqual(end.minX - scrubber.maxX, 4, accuracy: 1)
            let currentInk = try visibleBounds(image, in: current, screen: app.frame, threshold: 130)
            let endInk = try visibleBounds(image, in: end, screen: app.frame, threshold: 130)
            XCTAssertEqual(current.minX + currentInk.minX, info.minX, accuracy: 2)
            XCTAssertEqual(end.minX + endInk.maxX, 419, accuracy: 2)
        }
        let tabs = ["Info", "Cast", "Episodes", "Playlist"].map { app.buttons[$0] }
        for tab in tabs {
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
        }
        for (left, right) in zip(tabs, tabs.dropFirst()) {
            XCTAssertEqual(right.frame.minX - left.frame.maxX, 8, accuracy: 1)
        }
        attachMeasurements(["Portrait"] + ["Close player", "Skip backward", "Play", "Skip forward", "Info", "Cast", "Episodes", "Playlist", "Subtitles"]
            .map { "\($0): \(app.buttons[$0].frame)" })
    }

    private func uprightImage(_ image: UIImage, screen: CGRect) -> UIImage {
        UIGraphicsImageRenderer(size: screen.size).image { context in
            if screen.width > screen.height, let source = image.cgImage,
               source.width < source.height {
                // Screen captures retain portrait pixels in landscapeLeft.
                context.cgContext.translateBy(x: 0, y: screen.height)
                context.cgContext.rotate(by: -.pi / 2)
                UIImage(cgImage: source).draw(in: CGRect(
                    x: 0, y: 0, width: screen.height, height: screen.width
                ))
            } else {
                image.draw(in: CGRect(origin: .zero, size: screen.size))
            }
        }
    }

    private func brightness(_ image: UIImage, in frame: CGRect, screen: CGRect) throws -> Double {
        let source = try XCTUnwrap(uprightImage(image, screen: screen).cgImage)
        let scale = CGFloat(source.width) / screen.width
        let crop = try XCTUnwrap(source.cropping(to: CGRect(
            x: (frame.minX - screen.minX) * scale, y: (frame.minY - screen.minY) * scale,
            width: frame.width * scale, height: frame.height * scale
        ).integral))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) {
            $0 + Double(bytes[$1]) * 0.2126 + Double(bytes[$1 + 1]) * 0.7152 + Double(bytes[$1 + 2]) * 0.0722
        } / Double(crop.width * crop.height) / 255
    }

    private func visibleBounds(_ image: UIImage, in frame: CGRect, screen: CGRect, threshold: UInt8) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / screen.width
        let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale
        )))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        var minX = crop.width, minY = crop.height, maxX = -1, maxY = -1
        for y in 0..<crop.height {
            for x in 0..<crop.width {
                let offset = (y * crop.width + x) * 4
                if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX)
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    private func attachMeasurements(_ lines: [String]) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "Control frames in points"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(image: uprightImage(XCUIScreen.main.screenshot().image, screen: app.frame))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
