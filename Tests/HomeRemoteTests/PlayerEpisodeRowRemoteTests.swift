import UIKit
import CoreImage
import XCTest

@MainActor
final class PlayerEpisodeRowRemoteTests: XCTestCase {
    func testSongCardFollowsInfoActionsAndOffersServiceSearchWithScannableFallback() throws {
        continueAfterFailure = false
        let app = launch(arguments: ["--production-player-input", "--song"])
        defer { app.terminate() }
        let song = app.descendants(matching: .any)["player-song"]
        func focused(_ element: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, app.debugDescription)
        }
        for _ in 0..<2 {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))
            XCUIRemote.shared.press(.down)
            focused(app.buttons["Restart"])
            XCUIRemote.shared.press(.right)
            focused(app.buttons["Next Episode"])
            let restingBounds = song.frame
            let restingImage = app.screenshot().image
            XCUIRemote.shared.press(.right)
            focused(song)
            let focusedScreenshot = app.screenshot()
            try assertSongFocusOverflows(restingBounds, before: restingImage, after: focusedScreenshot.image)
            let capture = XCTAttachment(screenshot: focusedScreenshot)
            capture.name = "Song focus overflow"
            capture.lifetime = .keepAlways
            add(capture)
            XCUIRemote.shared.press(.menu)
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Closed'"),
                                          object: app.staticTexts["episode-row-drawer-state"])
            ], timeout: 5), .completed)
        }
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        focused(app.buttons["Restart"])
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        focused(song)
        XCUIRemote.shared.press(.select)
        let spotify = app.buttons["song-service-spotify"]
        XCTAssertTrue(spotify.waitForExistence(timeout: 5))
        // The native sheet begins on its leading service action.
        for _ in 0..<5 {
            if spotify.hasFocus { break }
            XCUIRemote.shared.press(.right)
        }
        focused(spotify)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["This app couldn’t open the link. Scan with your phone."].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        XCTAssertEqual((detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString,
                       "https://open.spotify.com/search/Test%20song%20Test%20artist")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.down)
        focused(app.buttons["Restart"])
    }

    private func assertSongFocusOverflows(_ bounds: CGRect, before: UIImage, after: UIImage) throws {
        func pixels(_ image: UIImage, rect: CGRect) throws -> [UInt8] {
            let source = try XCTUnwrap(image.cgImage)
            let scale = CGFloat(source.width) / 1920
            let crop = try XCTUnwrap(source.cropping(to: CGRect(
                x: rect.minX * scale, y: rect.minY * scale,
                width: rect.width * scale, height: rect.height * scale
            ).integral))
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            try bytes.withUnsafeMutableBytes {
                let context = try XCTUnwrap(CGContext(
                    data: $0.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return bytes
        }
        for y in [bounds.minY - 24, bounds.maxY + 1] {
            let region = CGRect(x: bounds.midX, y: y, width: 2, height: 23)
            let old = try pixels(before, rect: region), new = try pixels(after, rect: region)
            let difference = zip(old, new).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertGreaterThan(difference, 24, "Focused card pixels must overflow both edges of the Info stage.")
        }
    }

    func testUpUpDownKeepsEpisodeArtworkUnfocusedUntilRowEntry() throws {
        let app = launch(arguments: ["--long-season", "--production-player-input", "--capture-artwork"])
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["Episodes"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        for pausesOnTab in [true, false, false] {
            XCUIRemote.shared.press(.down)
            _ = try focusedEpisode(in: app)
            XCUIRemote.shared.press(.right)
            assertInAppArtworkIsClean(in: app)
            XCUIRemote.shared.press(.up)
            if pausesOnTab { assertInAppArtworkIsClean(in: app) }
            XCUIRemote.shared.press(.up)
            let surface = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Playback'"),
                object: app.staticTexts["episode-row-focus-owner"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [surface], timeout: 3), .completed)
            XCUIRemote.shared.press(.down)
            XCTAssertEqual(app.staticTexts["episode-row-focus-owner"].label, "Controls")
            XCTAssertEqual(app.collectionViews.firstMatch.cells.matching(NSPredicate(format: "hasFocus == true")).count, 0,
                           "Reentering the Episodes tab must not also focus an episode.")
            assertInAppArtworkIsClean(in: app)
        }
    }

    func testUpFromEpisodesTabReturnsToSeekSurfaceLikeInfo() throws {
        continueAfterFailure = false
        let app = launch(arguments: ["--production-player-input"])
        defer { app.terminate() }
        for tab in ["Info", "Episodes"] {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 5))
            let opened = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Open'"),
                object: app.staticTexts["episode-row-drawer-state"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 3), .completed)
            if tab == "Episodes" {
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
            }
            XCTAssertEqual(app.staticTexts["episode-row-focus-owner"].label, "Controls")
            XCUIRemote.shared.press(.up)
            let surface = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Playback'"),
                object: app.staticTexts["episode-row-focus-owner"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [surface], timeout: 3), .completed,
                           "Up from \(tab) must return real UIKit focus to the seek surface.")
            XCTAssertEqual(app.staticTexts["episode-row-drawer-state"].label, "Closed")
        }
    }

    func testRemoteBackClosesEpisodesWithoutReopeningOrLeavingHighlights() throws {
        let app = launch(arguments: ["--long-season", "--production-player-input", "--capture-artwork"])
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["Episodes"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            _ = try focusedEpisode(in: app)
            XCUIRemote.shared.press(.right, forDuration: 2)
            XCUIRemote.shared.press(.left, forDuration: 1)
            assertInAppArtworkIsClean(in: app)
            XCUIRemote.shared.press(.menu)
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Closed'"),
                object: app.staticTexts["episode-row-drawer-state"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed,
                           "Back must leave the bottom drawer, not restore its tab and reopen it.")
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(app.staticTexts["episode-row-drawer-state"].label, "Closed")
            XCUIRemote.shared.press(.down)
            assertInAppArtworkIsClean(in: app)
        }
    }

    func testAutomaticPlayerCloseClearsArtworkBeforeReenteringTheRow() throws {
        let app = launch(arguments: ["--long-season", "--production-player-input", "--capture-artwork"])
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        let episodes = app.buttons["Episodes"]
        XCTAssertTrue(episodes.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            _ = try focusedEpisode(in: app)
            let activity = try XCTUnwrap(Int(app.staticTexts["episode-row-activity"].label))
            XCUIRemote.shared.press(.right, forDuration: 2)
            XCUIRemote.shared.press(.left, forDuration: 1)
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertGreaterThan(try XCTUnwrap(Int(app.staticTexts["episode-row-activity"].label)), activity,
                                 "Native episode navigation must restart the production idle timer.")
            assertInAppArtworkIsClean(in: app)
            Thread.sleep(forTimeInterval: 8)
            XCTAssertEqual(app.staticTexts["episode-row-drawer-state"].label, "Open")
            XCUIRemote.shared.press(.right)
            let lastInput = Date()
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == 'Closed'"),
                object: app.staticTexts["episode-row-drawer-state"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 20), .completed)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(lastInput), 14.5,
                                        "The full 15-second episode timeout restarts after navigation.")
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertEqual(app.collectionViews.firstMatch.cells.matching(NSPredicate(format: "hasFocus == true")).count, 0)
            assertInAppArtworkIsClean(in: app)
        }
    }

    private func assertInAppArtworkIsClean(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        Thread.sleep(forTimeInterval: 0.8)
        let activity = app.staticTexts["episode-row-activity"].label
        let capture = app.staticTexts["episode-row-artwork-capture"]
        let clean = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "\(activity):clean"), object: capture
        )
        XCTAssertEqual(XCTWaiter.wait(for: [clean], timeout: 3), .completed,
                       "Only focused artwork may enlarge; app-side capture: \(capture.label)", file: file, line: line)
    }

    func testOnlyFocusedArtworkStaysEnlargedAfterRapidMovesAndInterruptedDrawer() throws {
        let app = launch(arguments: ["--long-season", "--interrupt-focus", "--refresh-on-focus"])
        defer { app.terminate() }
        for _ in 0..<3 {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCUIRemote.shared.press(.down)
        for _ in 0..<3 {
            XCUIRemote.shared.press(.right, forDuration: 0.4)
            XCUIRemote.shared.press(.left, forDuration: 0.4)
        }
        for _ in 0..<3 {
            XCUIRemote.shared.press(.select)
            XCUIRemote.shared.press(.right)
        }
        XCUIRemote.shared.press(.left)
        Thread.sleep(forTimeInterval: 0.6)
        try assertOnlyFocusedArtworkIsEnlarged(in: app)
        XCUIRemote.shared.press(.right, forDuration: 8)
        XCUIRemote.shared.press(.left, forDuration: 8)
        Thread.sleep(forTimeInterval: 0.6)
        try assertOnlyFocusedArtworkIsEnlarged(in: app)
        XCUIRemote.shared.press(.playPause)
        Thread.sleep(forTimeInterval: 0.4)
        XCUIRemote.shared.press(.playPause)
        Thread.sleep(forTimeInterval: 0.6)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 0.4)
        try assertOnlyFocusedArtworkIsEnlarged(in: app)
    }

    private func assertOnlyFocusedArtworkIsEnlarged(in app: XCUIApplication) throws {
        let capture = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = "Episode artwork after interrupted focus"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(capture.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let collection = app.collectionViews.firstMatch
        var measured = 0
        for cell in collection.cells.allElementsBoundByIndex
            where collection.frame.insetBy(dx: -1, dy: -1).contains(cell.frame) {
            let frame = cell.frame
            let crop = try XCTUnwrap(image.cropping(to: CGRect(
                x: frame.midX * scale, y: (frame.minY - 4) * scale,
                width: 1, height: 40 * scale
            ).integral))
            var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let top = try pixels.withUnsafeMutableBytes { bytes -> Int? in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                return (0..<crop.height).first {
                    let offset = $0 * crop.width * 4
                    return bytes[offset + 2] > 150 && Double(bytes[offset + 2]) > Double(bytes[offset]) * 1.5
                }
            }
            let inset = CGFloat(try XCTUnwrap(top, "Artwork must be visible for \(cell.label)")) / scale - 4
            if cell.hasFocus {
                XCTAssertLessThan(inset, 4, "The actual focused artwork must enlarge.")
            } else {
                XCTAssertEqual(inset, 12, accuracy: 2,
                               "Unfocused artwork must return to its resting size: \(cell.label)")
            }
            measured += 1
        }
        XCTAssertGreaterThanOrEqual(measured, 2)
    }

    func testHeldDirectionsCrossViewportAndSeasonBoundaries() throws {
        try assertContinuousBrowsing()
    }

    func testHeldDirectionsCrossLoadingBoundariesInRTL() throws {
        try assertContinuousBrowsing(rtl: true)
    }

    private func assertContinuousBrowsing(rtl: Bool = false) throws {
        continueAfterFailure = false
        let app = launch(arguments: rtl ? ["--rtl"] : [])
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        let start = try focusedEpisode(in: app)
        XCUIRemote.shared.press(rtl ? .left : .right, forDuration: 18)
        let right = try focusedEpisode(in: app)
        let afterHold = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterHold.name = "Episode right hold"
        afterHold.lifetime = .keepAlways
        add(afterHold)
        XCTAssertGreaterThan(right, 48, "One hold must continue into the following season.")
        XCTAssertGreaterThan(right, start + 8, "One hold must cross several viewports.")
        let forwardTrace = trace(in: app)
        XCTAssertGreaterThan(forwardTrace.count, 8)
        XCTAssertTrue(zip(forwardTrace, forwardTrace.dropFirst()).allSatisfy { $0 < $1 },
                      "Forward focus must not jump backward as cells and seasons load: \(forwardTrace)")
        XCUIRemote.shared.press(rtl ? .right : .left, forDuration: 36)
        XCTAssertLessThan(try focusedEpisode(in: app), 25,
                          "One hold must continue through earlier season loading.")
        let backwardTrace = Array(trace(in: app).dropFirst(forwardTrace.count - 1))
        XCTAssertTrue(zip(backwardTrace, backwardTrace.dropFirst()).allSatisfy { $0 > $1 },
                      "Backward focus must not jump forward while earlier seasons load: \(backwardTrace)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(Int(app.staticTexts["episode-row-peak-cells"].label)), 24)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Continuous episode browsing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFirstEpisodeDoesNotScrollWhenItReceivesFocus() throws {
        continueAfterFailure = false
        let app = launch(arguments: ["--single-season"])
        defer { app.terminate() }
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Episode 1' AND value == 'S1 · E1'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        let x = first.frame.midX
        XCUIRemote.shared.press(.down)
        if try focusedEpisode(in: app) == 2 { XCUIRemote.shared.press(.left) }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(try focusedEpisode(in: app), 1)
        XCTAssertEqual(first.frame.midX, x, accuracy: 2, "First-card entry must not change row alignment.")
        XCUIRemote.shared.press(.right, forDuration: 4)
        XCUIRemote.shared.press(.left, forDuration: 8)
        waitForFocusedCardToSettle(in: app)
        XCTAssertEqual(try focusedEpisode(in: app), 1)
        XCTAssertEqual(first.frame.midX, x, accuracy: 2, "Returning to the first episode must keep the same gutter.")
        let capture = XCUIScreen.main.screenshot()
        try assertFocusedEpisodeLabelIsVisible(first.frame, in: capture, appFrame: app.frame)
        let screenshot = XCTAttachment(screenshot: capture)
        screenshot.name = "Focused episode scrim"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testInitiallyLeadingEpisodeDoesNotShiftWhenFocused() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Episode 36' AND value == 'S2 · E12'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let x = first.frame.midX
        XCUIRemote.shared.press(.down)
        if try focusedEpisode(in: app) == 37 { XCUIRemote.shared.press(.left) }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try focusedEpisode(in: app), 36)
        XCTAssertEqual(first.frame.midX, x, accuracy: 2,
                       "The initially leading episode must already have its native focus clearance.")
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.left)
        XCTAssertEqual(try focusedEpisode(in: app), 36)
        XCTAssertEqual(first.frame.midX, x, accuracy: 2)
    }

    func testLongSeasonReusesNativeCellsDuringHeldBrowsing() throws {
        continueAfterFailure = false
        let app = launch(arguments: ["--long-season"])
        defer { app.terminate() }
        XCTAssertEqual(app.staticTexts["episode-row-count"].label, "1000")
        XCUIRemote.shared.press(.down)
        let start = try focusedEpisode(in: app)
        XCTAssertGreaterThanOrEqual(start, 500)
        XCUIRemote.shared.press(.right, forDuration: 8)
        waitForFocusedCardToSettle(in: app)
        let last = try focusedEpisode(in: app)
        XCTAssertGreaterThan(last, start + 12)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(app.buttons["Browse episodes"].hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.down)
        let returned = try focusedEpisode(in: app)
        XCTAssertLessThan(abs(returned - last), 5,
                          "Native Down may select a column-aligned card, but must retain the browsed viewport.")
        XCTAssertGreaterThan(returned, start + 12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(Int(app.staticTexts["episode-row-peak-cells"].label)), 24,
                                 "A large season must not create every native artwork cell.")
    }

    private func trace(in app: XCUIApplication) -> [Int] {
        app.staticTexts["episode-row-trace"].label.split(separator: ",").compactMap { Int($0) }
    }

    private func assertFocusedEpisodeLabelIsVisible(
        _ cell: CGRect, in screenshot: XCUIScreenshot, appFrame: CGRect
    ) throws {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / appFrame.width
        // The fixture has no white artwork. Sample only the lower-left image
        // interior, excluding the native focus rim and the caption below it.
        let region = CGRect(
            x: (cell.minX + 10 - appFrame.minX) * scale,
            y: (cell.minY + cell.height * 0.6 - appFrame.minY) * scale,
            width: cell.width * 0.35 * scale, height: cell.height * 0.22 * scale
        ).integral
        let crop = try XCTUnwrap(image.cropping(to: region))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let whitePixels = try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 220 && bytes[$0 + 1] > 220 && bytes[$0 + 2] > 220
            }.count
        }
        XCTAssertGreaterThan(whitePixels, 30,
                             "Panel glass must not hide the native focused artwork and its episode label.")
    }

    private func waitForFocusedCardToSettle(in app: XCUIApplication) {
        let collection = app.collectionViews.firstMatch
        let focused = collection.cells.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            focused.exists && collection.frame.insetBy(dx: -1, dy: -1).contains(focused.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The focused card must settle inside the row's viewport.")
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--episode-row-fixture"] + arguments
        app.launch()
        let ready = app.staticTexts["episode-row-ready"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Ready'"), object: ready)
        ], timeout: 10), .completed)
        return app
    }

    private func focusedEpisode(in app: XCUIApplication) throws -> Int {
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true AND label BEGINSWITH 'Episode '")).firstMatch
        XCTAssertTrue(focused.exists, app.debugDescription)
        return try XCTUnwrap(Int(focused.label.dropFirst("Episode ".count)))
    }
}
