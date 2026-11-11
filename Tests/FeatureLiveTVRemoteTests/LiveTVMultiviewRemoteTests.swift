import XCTest
import UIKit
import Vision

final class LiveTVMultiviewRemoteTests: XCTestCase {
    @MainActor
    func testInlineLiveTVAndGuideUsePhysicalScreenBounds() {
        assertLiveTVBounds(native: false)
    }

    @MainActor
    func testNativeLiveTVAndGuideUsePhysicalScreenBounds() {
        assertLiveTVBounds(native: true)
    }

    @MainActor
    private func assertLiveTVBounds(native: Bool) {
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture"]
        if native { app.launchArguments.append("--multiview-native-sidebar") }
        else { app.launchArguments.append("--inline-live-tv") }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        capture("live-tv-fullscreen-bounds-\(native)", in: app)
        assertVideoFrame(1, equals: app.frame, in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
        capture("live-tv-guide-bounds-\(native)", in: app)
        assertVideoFrame(1, equals: app.frame, in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
    }

    @MainActor
    func testProductionMultiviewWakeKeepsCompactControlsBelowPictures() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture", "--inline-live-tv"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        select(app.buttons["live-channel-timeline"], in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        for cycle in 1...2 {
            focusAudio("Sports 1", in: app)
            finishSetup(in: app)
            assertSideBySideFillsScreen(in: app)
            capture("production-multiview-before-wake-\(cycle)", in: app)
            XCUIRemote.shared.press(.right)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            assertAudio("Sports 2", in: app)
            XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 3))
            let controls = ["add", "layout", "more"].map { app.buttons["live-multiview-\($0)"].frame }
            let group = controls.reduce(CGRect.null) { $0.union($1) }
            XCTAssertEqual(group.midX, app.frame.midX, accuracy: 3)
            let picturesBottom = [1, 2].map {
                app.otherElements["multiview-fixture-video-\($0)"].frame.maxY
            }.max()!
            XCTAssertGreaterThan(group.minY, picturesBottom + 20)
            XCTAssertEqual(group.midY, (picturesBottom + app.frame.maxY - 60) / 2, accuracy: 25)
            XCTAssertFalse(app.staticTexts["Multiview"].exists)
            capture("production-multiview-after-wake-\(cycle)", in: app)
            assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        }
    }

    @MainActor
    func testCancellingInitialPickerReturnsToNormalPlaybackWithoutRetuning() {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        startProductionChannel(in: app)
        for cancelWithBack in [false, true] {
            openMultiviewPicker(in: app)
            if cancelWithBack { XCUIRemote.shared.press(.menu) }
            else { select(app.buttons["live-multiview-cancel-selection"], in: app) }
            XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["live-multiview-add"].exists)
            XCTAssertFalse(app.sheets["Close Multiview?"].exists)
            assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        }
        openMultiviewPicker(in: app)
        chooseGuideChannel(1, in: app)
        XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 5))
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
    }

    @MainActor
    func testRemovingSecondPictureResumesNormalPlaybackAndCanReopenMultiview() {
        assertSinglePictureReturn(removing: 2)
    }

    @MainActor
    func testRemovingOriginalPictureKeepsTheSurvivingPlayerInNormalPlayback() {
        assertSinglePictureReturn(removing: 1)
    }

    @MainActor
    private func assertSinglePictureReturn(removing channel: Int) {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        focusAudio("Sports \(channel)", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        selectMenuItem("Remove", in: app)
        XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["live-multiview-add"].exists)
        XCTAssertFalse(app.sheets["Close Multiview?"].exists)
        let survivor = channel == 1 ? 2 : 1
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-\(survivor)"].exists)
        assertVideoFrame(survivor, equals: app.frame, in: app)
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(3, in: app)
        XCTAssertTrue(pane("Sports \(survivor)", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(pane("Sports 3", in: app).exists)
        assertMetrics("Engines 3 loads 3 stops 1 audible 1", in: app)
    }

    @MainActor
    func testFullscreenPickerDoesNotReserveAppNavigationSpace() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--multiview-navigation-insets"]
        app.launch()
        defer { app.terminate() }
        let search = app.buttons["live-tv-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(search.frame.minX, 100)
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        XCTAssertEqual(search.frame.minX, 32, accuracy: 1)
        XCTAssertLessThanOrEqual(search.frame.minY, 76)
        chooseGuideChannel(2, in: app)
        select(app.buttons["live-multiview-add"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        XCTAssertEqual(search.frame.minX, 32, accuracy: 1)
        XCTAssertLessThanOrEqual(search.frame.minY, 76)
    }

    @MainActor
    func testAddingChannelKeepsEveryPictureBehindGuideAndAnimatesIntoItsSlot() throws {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--motion-fixture"]
        app.launch()
        defer { app.terminate() }
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        let motion = app.staticTexts["multiview-fixture-picture-motion"]
        func frames() -> [[[Double]]] {
            (motion.value as? String ?? "").split(separator: "|", omittingEmptySubsequences: false).map {
                $0.split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
            }
        }
        select(app.buttons["live-multiview-add"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        let backgrounds = NSPredicate { _, _ in
            let samples = frames()
            return samples.count == 2 && samples.allSatisfy {
                guard let last = $0.last, last.count == 5 else { return false }
                return last[2] < app.frame.width * 0.6 && last[4] > 0.99
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: backgrounds, object: nil)
        ], timeout: 5), .completed, "Both pictures must keep their slots behind the guide, not become a fullscreen preview.")
        let before = frames()
        capture("multiview-all-pictures-behind-guide", in: app)
        chooseGuideChannel(3, in: app)
        assertMetrics("Engines 3 loads 3 stops 0 audible 1", in: app)
        let settled = NSPredicate { _, _ in frames().count == 3 && frames().allSatisfy { !$0.isEmpty } }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: settled, object: nil)
        ], timeout: 5), .completed)
        let after = frames()
        let evidence = XCTAttachment(string: motion.value as? String ?? "")
        evidence.name = "Guide to three-picture presentation frames"
        evidence.lifetime = .keepAlways
        add(evidence)
        for index in 0..<2 {
            let start = try XCTUnwrap(before[index].last)[2]
            let end = try XCTUnwrap(after[index].last)[2]
            let widths = after[index].dropFirst(before[index].count).map { $0[2] }
            XCTAssertGreaterThan(abs(start - end), 100)
            XCTAssertGreaterThan(widths.filter { $0 > min(start, end) + 1 && $0 < max(start, end) - 1 }.count, 3,
                                 "Each retained renderer must animate into its new slot.")
            XCTAssertLessThan(widths.max() ?? 0, app.frame.width * 0.6)
        }
        let added = after[2].filter { $0[4] > 0.01 }
        XCTAssertGreaterThan(added.count, 3, "The new picture must animate into view.")
        XCTAssertLessThan(added.map { $0[2] }.max() ?? 0, app.frame.width * 0.6,
                          "A new renderer must never appear fullscreen before entering its slot.")
        capture("multiview-three-pictures-after-guide", in: app)
        select(app.buttons["live-multiview-add"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        let threeBehindGuide = NSPredicate { _, _ in
            let samples = frames()
            return samples.count == 3 && samples.allSatisfy {
                guard let last = $0.last, last.count == 5 else { return false }
                return last[2] < app.frame.width * 0.6 && last[4] > 0.99
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: threeBehindGuide, object: nil)
        ], timeout: 5), .completed)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5))
        assertMetrics("Engines 3 loads 3 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-add"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        let beforeFourth = frames()
        chooseGuideChannel(4, in: app)
        assertMetrics("Engines 4 loads 4 stops 0 audible 1", in: app)
        let fourReady = NSPredicate { _, _ in frames().count == 4 && frames().allSatisfy { !$0.isEmpty } }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: fourReady, object: nil)
        ], timeout: 5), .completed)
        let four = frames()
        let startX = try XCTUnwrap(beforeFourth[2].last)[0]
        let endX = try XCTUnwrap(four[2].last)[0]
        XCTAssertGreaterThan(abs(startX - endX), 100)
        XCTAssertGreaterThan(four[2].dropFirst(beforeFourth[2].count).filter {
            $0[0] > min(startX, endX) + 1 && $0[0] < max(startX, endX) - 1
        }.count, 3, "The existing bottom picture must slide into its four-picture position.")
        XCTAssertGreaterThan(four[3].filter { $0[4] > 0.01 && $0[4] < 0.99 }.count, 3)
        XCTAssertLessThan(four[3].map { $0[2] }.max() ?? 0, app.frame.width * 0.6)
        capture("multiview-four-pictures-after-guide", in: app)
    }

    @MainActor
    func testChannelPickerKeepsCategoriesReachableAndAppNavigationHidden() throws {
        try assertChannelPicker(rtl: false)
    }

    @MainActor
    func testRTLChannelPickerKeepsCategoriesReachableAndAppNavigationHidden() throws {
        try assertChannelPicker(rtl: true)
    }

    @MainActor
    private func assertChannelPicker(rtl: Bool) throws {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = [
            "--live-root-fixture", "--visual-focus-fixture",
            "--multiview-categories", "--multiview-native-sidebar"
        ]
        if rtl { app.launchArguments.append("--multiview-rtl") }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        select(app.buttons["live-channel-timeline"], in: app)
        select(app.buttons["live-channel-multiview"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["multiview-fixture-navigation"].label, "Navigation hidden")
        let first = app.buttons["live-tv-channel-channels-1"]
        select(first, in: app, activate: false)
        XCUIRemote.shared.press(rtl ? .right : .left)
        let categories = app.buttons["live-tv-sidebar-category-all"]
        assertNativeFocus(categories, in: app)
        XCUIRemote.shared.press(rtl ? .right : .left)
        assertNativeFocus(categories, in: app)
        select(app.buttons["live-tv-sidebar-category-News"], in: app)
        XCUIRemote.shared.press(rtl ? .left : .right)
        let third = app.buttons["live-tv-channel-channels-3"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        let screenshot = capture("multiview-picker-news-category-\(rtl)", in: app)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Add channel to Multiview"), "The live video must not cover the picker: \(text)")
        XCTAssertTrue(text.contains("Cancel"))
        XCTAssertEqual(app.staticTexts["multiview-fixture-navigation"].label, "Navigation hidden")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.buttons["Home"].isHittable)
        chooseGuideChannel(3, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-add"], in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5))
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        finishSetup(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertEqual(app.staticTexts["multiview-fixture-navigation"].label, "Navigation visible")
        select(third, in: app, activate: false)
        XCUIRemote.shared.press(rtl ? .right : .left)
        assertNativeFocus(app.buttons["live-tv-sidebar-category-News"], in: app)
        select(app.buttons["live-tv-search"], in: app, activate: false)
        XCUIRemote.shared.press(rtl ? .right : .left)
        capture("multiview-restored-native-navigation-\(rtl)", in: app)
        XCUIRemote.shared.press(.up)
        let home = app.collectionViews["Sidebar"].cells.containing(.button, identifier: "Home").firstMatch
        assertNativeFocus(home, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Fixture home"].waitForExistence(timeout: 5),
                      "Closing Multiview must restore usable native app navigation.")
    }

    @MainActor
    func testCloseMultiviewDialogKeepsFocusedCancelLegible() throws {
        try assertCloseDialogContrast(reduceGlass: false)
    }

    @MainActor
    func testCloseMultiviewDialogKeepsFocusedCancelLegibleWithReducedGlass() throws {
        try assertCloseDialogContrast(reduceGlass: true)
    }

    @MainActor
    private func assertCloseDialogContrast(reduceGlass: Bool) throws {
        let app = launchVisualFixture(reduceGlass: reduceGlass)
        defer { app.terminate() }
        openMultiview(in: app)
        finishSetup(in: app)
        XCUIRemote.shared.press(.menu)
        let dialog = app.sheets["Close Multiview?"]
        let keepWatching = dialog.buttons.matching(NSPredicate(format: "label == %@", "Keep watching")).firstMatch
        XCTAssertTrue(keepWatching.waitForExistence(timeout: 5))
        select(keepWatching, in: app, activate: false)
        try assertFocusedControl(
            keepWatching, name: "close-dialog-focused-cancel-\(reduceGlass)", showsTitle: true, in: app)
        select(keepWatching, in: app)
        XCTAssertFalse(dialog.exists)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
    }

    @MainActor
    func testProductionNativeFocusAndAutomaticWatchingPreserveEveryStream() async throws {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture", "--motion-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        select(app.buttons["live-channel-timeline"], in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        XCTAssertFalse(app.buttons["live-multiview-watch"].exists)
        XCTAssertFalse(app.buttons["live-multiview-done"].exists)
        focusAudio("Sports 1", in: app)
        let videos = [1, 2].map { app.otherElements["multiview-fixture-video-\($0)"] }
        capture("production-videos-after-adding-channel", in: app)
        XCTAssertTrue(videos.allSatisfy(\.exists), app.debugDescription)
        let firstFocus = videos.map(\.frame)
        capture("production-native-focus-first-video", in: app)
        XCTAssertGreaterThan(firstFocus[0].width, firstFocus[1].width + 15)
        XCUIRemote.shared.press(.right)
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        capture("production-native-focus-second-video", in: app)
        XCTAssertGreaterThan(videos[1].frame.width, videos[0].frame.width + 15)
        assertAudio("Sports 2", in: app)
        try await Task.sleep(for: .seconds(11))
        assertChromeHidden(in: app)
        assertSideBySideFillsScreen(in: app)
        capture("production-idle-full-videos-no-focus-treatment", in: app)
        assertAudio("Sports 2", in: app)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 5))
        capture("production-controls-return-after-idle", in: app)
        XCTAssertLessThan(videos[0].frame.width, app.frame.width / 2)
        XCTAssertLessThan(videos[1].frame.width, app.frame.width / 2)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        try await Task.sleep(for: .seconds(11))
        capture("production-native-menu-blocks-idle-timeout", in: app)
        selectMenuItem("Main and stack", in: app)
        XCTAssertTrue(app.buttons["live-multiview-layout"].exists)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testFocusedChannelCaptionDisappearsAndReturnsWithoutChangingVideoOrFocus() async throws {
        try await assertTransientChannelCaption(reduceGlass: false)
    }

    @MainActor
    func testFocusedChannelCaptionUsesReducedGlassFallback() async throws {
        try await assertTransientChannelCaption(reduceGlass: true)
    }

    @MainActor
    private func assertTransientChannelCaption(reduceGlass: Bool) async throws {
        continueAfterFailure = false
        let app = launchVisualFixture(reduceGlass: reduceGlass)
        defer { app.terminate() }
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        finishSetup(in: app)
        focusAudio("Sports 1", in: app)
        let frame = pane("Sports 2", in: app).frame
        let firstFrame = pane("Sports 1", in: app).frame
        let screenWidth = app.frame.width
        func captionText(_ screenshot: UIImage, in frame: CGRect) throws -> String {
            let image = try XCTUnwrap(screenshot.cgImage)
            let scale = CGFloat(image.width) / screenWidth
            let region = CGRect(x: frame.minX, y: frame.maxY - 100, width: frame.width, height: 100)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
            let crop = try XCTUnwrap(image.cropping(to: region))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: crop).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        let style = reduceGlass ? "reduced-glass" : "native-glass"
        XCUIRemote.shared.press(.right)
        let visible = capture("channel-caption-\(style)-focused", in: app)
        XCTAssertTrue(try captionText(visible, in: frame).contains("Sports 2"))
        XCTAssertFalse(try captionText(visible, in: firstFrame).contains("Sports 1"))
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        let videoFrame = settledVideoFrame(2, in: app)
        // A boundary press renews the controls deadline without refocusing or renewing the caption.
        XCUIRemote.shared.press(.right)
        try await Task.sleep(for: .seconds(4))
        let hidden = capture("channel-caption-\(style)-hidden", in: app)
        let hiddenVideoFrame = app.otherElements["multiview-fixture-video-2"].frame
        XCTAssertFalse(try captionText(hidden, in: frame).contains("Sports 2"))
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        assertAudio("Sports 2", in: app)
        XCTAssertEqual(hiddenVideoFrame, videoFrame)
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.right)
        let restored = capture("channel-caption-\(style)-refocused", in: app)
        XCTAssertTrue(try captionText(restored, in: frame).contains("Sports 2"))
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    private func fixtureApplication() -> XCUIApplication {
        if Bundle(for: Self.self).bundleIdentifier == "com.thatcube.Plozz.HomeRemoteTests" {
            return XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        }
        return XCUIApplication()
    }

    @MainActor
    func testCornerFocusClearanceShowsTheMainVideoInsteadOfABlackBacking() throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        focusAudio("Sports 1", in: app)
        let main = settledVideoFrame(1, in: app)
        let inset = settledVideoFrame(2, in: app)
        let screenshot = capture("corner-transparent-focus-clearance", in: app)
        let image = try XCTUnwrap(screenshot.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        for point in [
            CGPoint(x: inset.minX - 10, y: inset.midY),
            CGPoint(x: inset.midX, y: inset.minY - 8)
        ] {
            XCTAssertTrue(main.contains(point))
            let crop = try XCTUnwrap(image.cropping(to: CGRect(
                x: point.x * scale, y: point.y * scale, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(pixel[2], 150, "The main blue picture must show through the inset's focus clearance.")
            XCTAssertLessThan(pixel[0], 50)
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testProductionNativeFullscreenShrinksTheActualRetainedVideoIntoMultiview() throws {
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture", "--motion-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        select(app.buttons["live-channel-timeline"], in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5), app.debugDescription)
        let video = app.staticTexts["multiview-fixture-metrics"]
        func widths() -> [Double] {
            (video.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
        }
        func waitForGrowth(after baseline: [Double]) throws -> [Double] {
            let original = try XCTUnwrap(baseline.last)
            let animated = NSPredicate { _, _ in
                widths().dropFirst(baseline.count).filter { $0 > original + 1 }.count >= 4
            }
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: animated, object: nil)
            ], timeout: 5), .completed, "Wait for the renderer history, not just menu dismissal.")
            return widths()
        }
        let after = widths()
        let diagnostics = XCTAttachment(string: video.value as? String ?? "Missing output history")
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        let fullscreenWidth = try XCTUnwrap(after.max())
        XCTAssertEqual(fullscreenWidth, app.frame.width, accuracy: 1)
        let setupWidth = try XCTUnwrap(after.last)
        XCTAssertLessThan(setupWidth, fullscreenWidth - 100)
        XCTAssertGreaterThan(after.filter {
            $0 > setupWidth + 1 && $0 < fullscreenWidth - 1
        }.count, 2, "Native fullscreen must return its actual renderer before the shrink animation starts.")
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        let screenshot = capture("production-multiview-rounded-picture", in: app)
        let image = try XCTUnwrap(screenshot.cgImage)
        let center = try XCTUnwrap(image.cropping(to: CGRect(
            x: image.width / 2 - 200, y: image.height / 2 - 150, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[2], 200, "The retained blue video must remain visible after native handoff.")
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        let grid = widths()
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Main and stack", in: app)
        let stack = try waitForGrowth(after: grid)
        let gridWidth = try XCTUnwrap(grid.last)
        let stackWidth = try XCTUnwrap(stack.last)
        XCTAssertGreaterThan(stackWidth, gridWidth)
        XCTAssertGreaterThan(stack.dropFirst(grid.count).filter { $0 > gridWidth + 1 && $0 < stackWidth - 1 }.count, 2)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Grid", in: app)
        focusAudio("Sports 2", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        selectMenuItem("Remove", in: app)
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        // The last removal now opens normal native playback, not a one-pane grid resize.
        XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["live-multiview-add"].exists)
        assertVideoFrame(1, equals: app.frame, in: app)
    }

    @MainActor
    func testGlassPlaybackAndMultiviewControlsHaveFocusedContrastAndNativeHeight() throws {
        try assertPlaybackControlAppearance(reduceGlass: false)
    }

    @MainActor
    func testReducedTransparencyPlaybackAndMultiviewControlsHaveFocusedContrastAndNativeHeight() throws {
        try assertPlaybackControlAppearance(reduceGlass: true)
    }

    @MainActor
    func testProductionGuideDoesNotOverrideNativePlaybackAndMultiviewContrast() throws {
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        select(app.buttons["live-channel-timeline"], in: app)
        let playback = app.buttons["live-channel-playback"]
        select(playback, in: app, activate: false)
        try assertFocusedControl(playback, name: "production-playback", in: app)
        select(playback, in: app)
        XCUIRemote.shared.press(.menu)
        select(playback, in: app, activate: false)
        try assertFocusedControl(playback, name: "production-playback-menu-return", in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        for name in ["more", "layout"] {
            let button = app.buttons["live-multiview-\(name)"]
            select(button, in: app, activate: false)
            try assertFocusedControl(button, name: "production-multiview-\(name)", showsTitle: true, in: app)
        }
    }

    @MainActor
    private func assertPlaybackControlAppearance(reduceGlass: Bool) throws {
        continueAfterFailure = true
        let app = launchVisualFixture(reduceGlass: reduceGlass)
        defer { app.terminate() }
        select(app.buttons["live-channel-timeline"], in: app)
        let reference = app.buttons["live-channel-multiview"].frame.size
        for name in ["playback", "audio", "subtitles", "multiview"] {
            let button = app.buttons["live-channel-\(name)"]
            select(button, in: app, activate: false)
            try assertFocusedControl(button, name: "transport-\(name)-\(reduceGlass)", in: app)
        }
        openMultiview(in: app)
        for name in ["add", "layout", "more"] {
            let button = app.buttons["live-multiview-\(name)"]
            select(button, in: app, activate: false)
            XCTAssertLessThanOrEqual(button.frame.height, reference.height * 1.2,
                                    "Multiview must use the transport button height.")
            XCTAssertFalse(button.label.isEmpty, "\(name) must retain its accessible title.")
            try assertFocusedControl(button, name: "multiview-\(name)-\(reduceGlass)", showsTitle: true, in: app)
        }
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        XCTAssertTrue(app.buttons["live-multiview-add"].exists, "The native Layout menu must still work.")
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
    }

    @MainActor
    private func assertFocusedControl(
        _ button: XCUIElement, name: String, showsTitle: Bool = false, in app: XCUIApplication
    ) throws {
        assertNativeFocus(button, in: app)
        let image = try XCTUnwrap(capture(name, in: app).cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let region = showsTitle ? button.frame.insetBy(dx: 8, dy: 8)
            : CGRect(x: button.frame.midX - 16, y: button.frame.midY - 16, width: 32, height: 32)
        let crop = try XCTUnwrap(image.cropping(to: region
            .applying(CGAffineTransform(scaleX: scale, y: scale))))
        if showsTitle {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            XCTAssertTrue(text.localizedCaseInsensitiveContains(button.label),
                          "Multiview must visibly name the action: expected \(button.label), rendered \(text)")
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let colors = stride(from: 0, to: pixels.count, by: 4).map { offset in
            (0..<3).map { Int(pixels[offset + $0]) }
        }
        let dark = colors.filter { $0.allSatisfy { $0 < 90 } }.count
        let bright = colors.filter {
            Double($0[0]) * 0.2126 + Double($0[1]) * 0.7152 + Double($0[2]) * 0.0722 > 170
        }.count
        XCTAssertGreaterThan(Double(dark) / Double(colors.count), 0.025,
                             "\(name) must show a dark label inside its focused fill.")
        XCTAssertGreaterThan(Double(bright) / Double(colors.count), 0.2,
                             "\(name) must retain its bright native focus fill.")
    }

    @MainActor
    func testNativePlayerFocusIsRenderedAcrossControlsAndHUDReturn() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        let timeline = app.buttons["live-channel-timeline"]
        // Select on the timeline pauses, so the HUD stays up while focus is walked.
        select(timeline, in: app)
        let controls: [(String, XCUIElement)] = [
            ("audio", app.buttons["live-channel-audio"]),
            ("subtitles", app.buttons["live-channel-subtitles"]),
            ("multiview", app.buttons["live-channel-multiview"]),
            ("info", app.buttons["live-channel-info"])
        ]
        for (name, target) in controls {
            assertRenderedFocus(target, anchor: timeline, name: "player-\(name)", in: app)
        }
        select(app.buttons["live-channel-subtitles"], in: app)
        capture("player-subtitle-menu", in: app)
        select(app.buttons["Off"], in: app)
        XCUIRemote.shared.press(.menu)
        assertRenderedFocus(
            app.buttons["live-channel-subtitles"], anchor: timeline,
            name: "player-subtitles-return", in: app
        )
        select(timeline, in: app)
        let revealSurface = app.descendants(matching: .any)["live-channel-reveal-surface"].firstMatch
        for cycle in 1...2 {
            let hidden = NSPredicate { _, _ in
                !timeline.exists && revealSurface.exists
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 15),
                .completed, "Playing HUD must hide without losing its video owner"
            )
            capture("player-hud-hidden-\(cycle)", in: app)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(timeline.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(revealSurface.exists, "Visible controls must remove the native reveal focus surface")
            let focused = focusedElement(in: app)
            guard focused.exists, focused.identifier == "live-channel-timeline" else {
                XCTFail("Revealing the HUD must focus the timeline: \(nativeFocus(in: app))")
                return
            }
            let beforeFocus = nativeFocus(in: app)
            let before = capture("player-hud-revealed-\(cycle)", in: app)
            XCUIRemote.shared.press(.up)
            let moved = focusedElement(in: app)
            XCTAssertTrue(moved.exists && moved.elementType == .button)
            XCTAssertNotEqual(moved.identifier, "live-channel-timeline", "Up from the timeline must reach a badge")
            XCTAssertFalse(revealSurface.exists)
            let after = capture("player-hud-moved-\(cycle)", in: app)
            let change = pixelDifference(
                before, after, region: moved.frame.insetBy(dx: -8, dy: -8), screen: app.frame
            )
            let evidence = XCTAttachment(string:
                "HUD cycle \(cycle): changed pixel fraction=\(change.fraction), mean RGB delta=\(change.mean)\n" +
                "Revealed: \(beforeFocus)\nMoved: \(nativeFocus(in: app))"
            )
            evidence.name = "player-hud-return-focus-\(cycle)-pixel-evidence"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertGreaterThan(
                change.fraction, 0.03,
                "The badge reached from the timeline must visibly take focus"
            )
            // Back to the hub so the next cycle hides from a playing timeline.
            XCUIRemote.shared.press(.down)
        }
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
    }

    @MainActor
    func testLiveTransportTabsMenusAndGuideAreReachableByRemote() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        let timeline = app.buttons["live-channel-timeline"]
        select(timeline, in: app) // pause, so the HUD stays up
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-timeline")

        // Down from the hub lands on the first card tab and opens its card.
        press(.down)
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-info", nativeFocus(in: app))
        capture("osd-card-info", in: app)
        for tab in ["live-channel-on-now", "live-channel-guide"] {
            press(.right)
            XCTAssertEqual(focusedElement(in: app).identifier, tab, nativeFocus(in: app))
            capture("osd-\(tab)", in: app)
        }
        // Up leaves the card for the timeline.
        press(.up)
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-timeline", nativeFocus(in: app))
        capture("osd-card-closed", in: app)

        // Track menus open above the badges, never over the timeline.
        for badge in ["live-channel-subtitles", "live-channel-audio"] {
            select(app.buttons[badge], in: app)
            let panelRow = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(panelRow.waitForExistence(timeout: 3))
            capture("osd-menu-\(badge)", in: app)
            XCTAssertLessThan(panelRow.frame.maxY, timeline.frame.minY, "\(badge) menu must sit above the timeline")
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(app.buttons[badge].waitForExistence(timeout: 3))
        }

        // Guide: a card like the others, with the grid under the pills.
        select(app.buttons["live-channel-guide"], in: app, activate: false)
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-guide", nativeFocus(in: app))
        let guide = app.descendants(matching: .any)["live-channel-guide-overlay"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 5), "Focusing the Guide pill shows the grid")
        capture("osd-guide", in: app)
        press(.down)
        XCTAssertNotEqual(focusedElement(in: app).identifier, "live-channel-guide", "Down walks into the grid")
        capture("osd-guide-moved", in: app)
        select(app.buttons["live-channel-guide"], in: app, activate: false)
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-guide", "Up from the grid returns to the pills")
        press(.left)
        XCTAssertEqual(focusedElement(in: app).identifier, "live-channel-on-now", nativeFocus(in: app))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "Menu closes the card")
        capture("osd-guide-closed", in: app)
    }

    @MainActor
    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        usleep(700_000)
    }

    @MainActor
    func testMultiviewToolbarFocusIsRendered() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        XCTAssertFalse(app.buttons["live-multiview-done"].exists)
        XCTAssertFalse(app.staticTexts["Multiview"].exists)
        for name in ["add", "layout", "more"] {
            let anchor = name == "layout" ? app.buttons["live-multiview-add"] : app.buttons["live-multiview-layout"]
            assertRenderedFocus(
                app.buttons["live-multiview-\(name)"], anchor: anchor,
                name: "multiview-single-\(name)", in: app
            )
        }
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        focusAudio("Sports 2", in: app)
        for name in ["replace", "promote", "remove", "favorite", "edit"] {
            XCTAssertFalse(app.buttons["live-multiview-\(name)"].exists)
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["live-multiview-add", "live-multiview-layout", "live-multiview-more"]
        )).count, 3)
        XCUIRemote.shared.press(.select, forDuration: 1)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label == %@", "Replace channel")).firstMatch.exists)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label == %@", "Make main picture")).firstMatch.exists)
        selectMenuItem("Remove", in: app)
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        select(pane("Sports 1", in: app), in: app, activate: false)
        assertAudio("Sports 1", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        XCTAssertFalse(app.cells.containing(NSPredicate(format: "label == %@", "Remove")).firstMatch.exists)
        XCUIRemote.shared.press(.menu)
    }

    @MainActor
    func testMultiviewFocusedPanesKeepVideoReadableInBothLayouts() {
        continueAfterFailure = true
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        for layout in ["side-by-side", "corner"] {
            if layout == "corner" {
                select(app.buttons["live-multiview-layout"], in: app)
                selectMenuItem("Corner", in: app)
                assertCornerLayout(in: app)
            }
            for (index, channel) in ["Sports 1", "Sports 2"].enumerated() {
                let anchor = layout == "corner" && channel == "Sports 2"
                    ? app.buttons["live-multiview-more"] : app.buttons["live-multiview-layout"]
                assertRenderedFocus(
                    pane(channel, in: app), anchor: anchor,
                    name: "\(layout)-\(channel)", preservesVideo: true,
                    visualSurface: app.otherElements["multiview-fixture-video-\(index + 1)"], in: app
                )
            }
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testPaneDirectionsFromControlsAndAcrossEveryCornerKeepNativeContextMenus() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        XCTAssertFalse(app.buttons["live-multiview-done"].exists)
        XCTAssertFalse(app.buttons["live-multiview-watch"].exists)
        select(app.buttons["live-multiview-layout"], in: app, activate: false)
        XCUIRemote.shared.press(.up)
        assertNativeFocus(pane("Sports 1", in: app), in: app)
        capture("single-pane-up-from-controls", in: app)

        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        for corner in ["Bottom right", "Top right", "Top left", "Bottom left"] {
            select(app.buttons["live-multiview-layout"], in: app)
            selectMenuItem(corner, in: app)
            select(pane("Sports 1", in: app), in: app, activate: false)
            XCUIRemote.shared.press(corner.hasSuffix("left") ? .left : .right)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            assertAudio("Sports 2", in: app)
            capture("\(corner)-inset-directional-focus", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, corner: corner, in: app)
            XCUIRemote.shared.press(corner.hasSuffix("left") ? .right : .left)
            assertNativeFocus(pane("Sports 1", in: app), in: app)
            assertAudio("Sports 1", in: app)
            capture("\(corner)-main-directional-focus", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 1", engine: 1, corner: corner, in: app)
            revealChrome(in: app)
        }
        focusAudio("Sports 2", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        try await Task.sleep(for: .seconds(11))
        capture("corner-pane-native-context-menu", in: app)
        selectMenuItem("Make main picture", in: app)
        assertAudio("Sports 2", in: app)
        finishSetup(in: app)
        assertVideoFrame(2, equals: app.frame, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testProductionRootRetainsThePromotedPlayer() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture"]
        app.launch()
        defer { app.terminate() }
        select(app.buttons["live-tv-channel-channels-1"], in: app)
        select(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Play channel")
            ).firstMatch,
            in: app
        )
        XCTAssertTrue(
            app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        openMultiviewPicker(in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertSideBySideFillsScreen(in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        revealChrome(in: app)
        focusAudio("Sports 2", in: app)
        XCTAssertFalse(app.buttons["live-multiview-done"].exists)
        XCUIRemote.shared.press(.menu)
        assertChromeHidden(in: app)
        XCTAssertFalse(app.sheets["Close Multiview?"].exists, "Back from setup starts watching without closing.")
        XCUIRemote.shared.press(.menu)
        let keepWatching = app.sheets["Close Multiview?"].buttons.matching(
            NSPredicate(format: "label == %@", "Keep watching")).firstMatch
        XCTAssertTrue(keepWatching.waitForExistence(timeout: 5))
        select(keepWatching, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-2"].label, "Engine 2 loads 1")
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        select(app.buttons["live-root-fixture-refresh"], in: app)
        XCTAssertEqual(app.buttons["live-root-fixture-refresh"].value as? String, "1")
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
        select(app.buttons["live-root-fixture-leave"], in: app)
        assertMetrics("Engines 2 loads 2 stops 2 audible 0", in: app)
    }

    @MainActor
    func testNativeFullscreenMultiviewLayoutsAndReturnKeepExistingPlayers() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--multiview-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
        openMultiview(in: app)
        XCTAssertTrue(app.buttons["live-multiview-add"].waitForExistence(timeout: 5))
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)

        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertSideBySideFillsScreen(in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        revealChrome(in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Corner", in: app)
        assertCornerLayout(in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Top left", in: app)
        assertCornerLayout(in: app, topLeft: true)
        focusAudio("Sports 1", in: app)
        focusAudio("Sports 2", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, corner: "Top left", in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)

        revealChrome(in: app)
        focusAudio("Sports 2", in: app)
        XCTAssertFalse(app.buttons["live-multiview-done"].exists)
        finishSetup(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-2"].label, "Engine 2 loads 1")
    }

    @MainActor
    func testChromeIdleCyclesResizeVideosAndRestoreFocusAndAudio() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        finishSetup(in: app)
        assertSideBySideFillsScreen(in: app)
        let original = [1, 2].map { app.otherElements["multiview-fixture-video-\($0)"].frame }
        for cycle in 1...2 {
            focusAudio("Sports 1", in: app)
            let activations = [1, 2].map { audioActivations($0, in: app) }
            let shown = capture("multiview-chrome-shown-\(cycle)", in: app)
            assertChromeHidden(in: app)
            let hidden = capture("multiview-chrome-hidden-\(cycle)", in: app)
            assertNativeFocus(pane("Sports 1", in: app), in: app)
            XCTAssertEqual([1, 2].map { audioActivations($0, in: app) }, activations)
            for (index, frame) in original.enumerated() {
                assertVideoFrame(index + 1, equals: frame, in: app)
                let sample = CGRect(
                    x: frame.minX + frame.width * 0.18, y: frame.minY + frame.height * 0.22,
                    width: frame.width * 0.12, height: frame.height * 0.12
                )
                XCTAssertLessThan(
                    pixelDifference(shown, hidden, region: sample, screen: app.frame).mean, 0.06,
                    "Hiding chrome must not change video contents"
                )
            }
            XCUIRemote.shared.press(.right)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            assertAudio("Sports 2", in: app)
            XCTAssertEqual(audioActivations(1, in: app), activations[0])
            XCTAssertEqual(audioActivations(2, in: app), activations[1] + 1)
            XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 2))
            capture("multiview-chrome-revealed-\(cycle)", in: app)
            for (index, frame) in original.enumerated() {
                XCTAssertLessThan(app.otherElements["multiview-fixture-video-\(index + 1)"].frame.width, frame.width)
            }
            select(app.buttons["live-multiview-layout"], in: app, activate: false)
            assertAudio("Sports 2", in: app)
            try await Task.sleep(for: .seconds(6))
            assertNativeFocus(app.buttons["live-multiview-layout"], in: app)
            XCTAssertFalse(app.buttons["live-multiview-done"].exists)
            XCUIRemote.shared.press(.menu)
            assertChromeHidden(in: app)
            assertNativeFocus(pane("Sports 2", in: app), in: app)
            try await Task.sleep(for: .seconds(1))
            XCTAssertFalse(app.buttons["live-multiview-layout"].exists, "Focus restoration must not reopen chrome")
            assertAudio("Sports 2", in: app)
            assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
        }
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    func testNativePickerAndLayoutMenuRemainPresentedPastInactivityGrace() async throws {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        try await Task.sleep(for: .seconds(11))
        capture("multiview-picker-pinned", in: app)
        chooseGuideChannel(2, in: app)
        finishSetup(in: app)
        focusAudio("Sports 2", in: app)
        revealChrome(in: app)
        select(app.buttons["live-multiview-layout"], in: app, activate: false)
        assertNativeFocus(app.buttons["live-multiview-layout"], in: app)
        assertAudio("Sports 2", in: app)
        select(app.buttons["live-multiview-layout"], in: app)
        try await Task.sleep(for: .seconds(11))
        capture("multiview-layout-menu-pinned", in: app)
        selectMenuItem("Corner", in: app)
        finishSetup(in: app)
        assertCornerLayout(in: app)
        assertAudio("Sports 2", in: app)
        focusAudio("Sports 2", in: app)
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertFalse(app.buttons["live-multiview-layout"].exists)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-2"].waitForExistence(timeout: 5))
        assertMetrics("Engines 2 loads 2 stops 1 audible 1", in: app)
    }

    @MainActor
    func testLeavingActiveWorkspaceStopsAllPlayersAndRestoresNavigation() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        select(app.buttons["live-root-fixture-leave"], in: app)
        assertMetrics("Engines 2 loads 2 stops 2 audible 0", in: app)
        XCTAssertEqual(app.staticTexts["multiview-fixture-navigation"].label, "Navigation visible")
    }

    @MainActor
    func testPendingChannelCanBeRemovedFromItsOwnMenu() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--multiview-fixture", "--pending-multiview-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(pane("Sports 2", in: app), in: app, activate: false)
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        selectMenuItem("Remove", in: app)
        XCTAssertFalse(pane("Sports 2", in: app).exists)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        select(pane("Sports 1", in: app), in: app, activate: false)
        assertAudio("Sports 1", in: app)
    }

    @MainActor
    func testFocusedPendingPaneKeepsExistingAudioUntilItsSourceIsPrepared() {
        continueAfterFailure = false
        let app = fixtureApplication()
        app.launchArguments = ["--multiview-fixture", "--pending-multiview-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        openMultiview(in: app)
        select(app.buttons["live-multiview-add"], in: app)
        chooseGuideChannel(2, in: app)
        select(pane("Sports 2", in: app), in: app, activate: false)
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        assertAudio("Sports 1", in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(pane("Sports 1", in: app).exists, "An unprepared pane must not expand")
        assertAudio("Sports 1", in: app)
        capture("multiview-pending-pane-focus", in: app)
        XCUIRemote.shared.press(.playPause)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        assertNativeFocus(pane("Sports 2", in: app), in: app)
        assertAudio("Sports 2", in: app)
        capture("multiview-prepared-pane-focus", in: app)
        assertSelectAndBackPreservePictures(channel: "Sports 2", engine: 2, in: app)
    }

    @MainActor
    private func focusAudio(_ channel: String, in app: XCUIApplication) {
        select(pane(channel, in: app), in: app, activate: false)
        assertNativeFocus(pane(channel, in: app), in: app)
        assertAudio(channel, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
    }

    @MainActor
    private func assertAudio(_ channel: String, in app: XCUIApplication) {
        let matches = NSPredicate { _, _ in
            guard self.pane(channel, in: app).value as? String == "Audio on" else { return false }
            return (1...4).map { "Sports \($0)" }.filter { $0 != channel }.allSatisfy {
                let other = self.pane($0, in: app)
                return !other.exists || other.value as? String == "Muted"
            }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Expected audio on \(channel), value \(String(describing: self.pane(channel, in: app).value)). " +
                "Sports 1: \(String(describing: self.pane("Sports 1", in: app).value)). \(nativeFocus(in: app))"
        )
    }

    @MainActor
    private func revealChrome(in app: XCUIApplication) {
        if !app.buttons["live-multiview-layout"].exists && !app.buttons["live-multiview-edit"].exists {
            XCUIRemote.shared.press(.down)
        }
        if app.buttons["live-multiview-edit"].exists {
            select(app.buttons["live-multiview-edit"], in: app)
        }
        XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func finishSetup(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["live-multiview-watch"].exists)
        assertChromeHidden(in: app)
    }

    @MainActor
    private func assertChromeHidden(in app: XCUIApplication) {
        let hidden = NSPredicate { _, _ in
            !app.buttons["live-multiview-layout"].exists
                && !app.buttons["live-multiview-edit"].exists && !app.buttons["live-multiview-done"].exists
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 15),
            .completed, "Watching must remove chrome without removing native pane focus targets"
        )
    }

    @MainActor
    private func assertSelectAndBackPreservePictures(
        channel: String, engine: Int, corner: String? = nil, in app: XCUIApplication
    ) {
        finishSetup(in: app)
        select(pane(channel, in: app), in: app, activate: false)
        finishSetup(in: app)
        let original: [CGRect]
        if let corner {
            let width = app.frame.width * 0.32
            let height = width * 9 / 16
            original = [app.frame, CGRect(
                x: corner.hasSuffix("left") ? 16 : app.frame.maxX - width - 16,
                y: corner.hasPrefix("Top") ? 16 : app.frame.maxY - height - 16,
                width: width, height: height)]
        } else {
            original = (0..<2).map {
                CGRect(x: CGFloat($0) * app.frame.width / 2, y: 0,
                       width: app.frame.width / 2, height: app.frame.height)
            }
        }
        for (index, frame) in original.enumerated() {
            assertVideoFrame(index + 1, equals: frame, in: app)
        }
        let activations = [1, 2].map { audioActivations($0, in: app) }
        assertNativeFocus(pane(channel, in: app), in: app)
        XCUIRemote.shared.press(.select)
        assertVideoFrame(engine, equals: app.frame, in: app)
        let other = channel == "Sports 1" ? "Sports 2" : "Sports 1"
        let hidden = NSPredicate { _, _ in !self.pane(other, in: app).exists }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 3),
            .completed, "Expanded viewing must expose only the selected pane")
        capture("multiview-expanded-\(channel)", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(pane(other, in: app).waitForExistence(timeout: 3))
        for (index, frame) in original.enumerated() {
            assertVideoFrame(index + 1, equals: frame, in: app)
        }
        assertNativeFocus(pane(channel, in: app), in: app)
        assertAudio(channel, in: app)
        XCTAssertEqual([1, 2].map { audioActivations($0, in: app) }, activations)
        assertChromeHidden(in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        capture("multiview-restored-\(channel)", in: app)
    }

    @MainActor
    func testFourChannelSetupUsesGuideAndIdleRestoresFullPictures() {
        continueAfterFailure = false
        let app = launchVisualFixture()
        defer { app.terminate() }
        openMultiview(in: app)
        XCTAssertTrue(
            app.buttons["live-multiview-add"].waitForExistence(timeout: 5),
            app.debugDescription)
        let setupVideo = app.otherElements["multiview-fixture-video-1"].frame
        XCTAssertGreaterThan(setupVideo.minX, app.frame.minX)
        XCTAssertGreaterThan(setupVideo.minY, app.frame.minY)
        for channel in 2...4 {
            select(app.buttons["live-multiview-add"], in: app)
            XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["Choose channel"].exists)
            capture("multiview-guide-selection-\(channel)", in: app)
            chooseGuideChannel(channel, in: app)
            assertMetrics("Engines \(channel) loads \(channel) stops 0 audible 1", in: app)
        }
        XCTAssertFalse(app.buttons["live-multiview-add"].exists)
        finishSetup(in: app)
        let frames = (0..<4).map { index in
            CGRect(
                x: app.frame.minX + CGFloat(index % 2) * app.frame.width / 2,
                y: app.frame.minY + CGFloat(index / 2) * app.frame.height / 2,
                width: app.frame.width / 2, height: app.frame.height / 2)
        }
        for (index, frame) in frames.enumerated() { assertVideoFrame(index + 1, equals: frame, in: app) }
        select(pane("Sports 2", in: app), in: app, activate: false)
        select(pane("Sports 1", in: app), in: app, activate: false)
        capture("multiview-four-interactive-focus-first", in: app)
        select(pane("Sports 2", in: app), in: app, activate: false)
        assertAudio("Sports 2", in: app)
        capture("multiview-four-interactive-focus-second", in: app)
        XCTAssertGreaterThan(app.otherElements["multiview-fixture-video-2"].frame.width,
                             app.otherElements["multiview-fixture-video-1"].frame.width)
        select(pane("Sports 4", in: app), in: app, activate: false)
        assertAudio("Sports 4", in: app)
        finishSetup(in: app)
        for (index, frame) in frames.enumerated() { assertVideoFrame(index + 1, equals: frame, in: app) }
        XCUIRemote.shared.press(.select)
        assertVideoFrame(4, equals: app.frame, in: app)
        XCUIRemote.shared.press(.menu)
        for (index, frame) in frames.enumerated() { assertVideoFrame(index + 1, equals: frame, in: app) }
        assertAudio("Sports 4", in: app)
        assertMetrics("Engines 4 loads 4 stops 0 audible 1", in: app)
    }

    @MainActor
    private func openMultiview(in app: XCUIApplication) {
        openMultiviewPicker(in: app)
        select(app.buttons["live-multiview-cancel-selection"], in: app)
        XCTAssertTrue(app.buttons["live-multiview-layout"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openMultiviewPicker(in app: XCUIApplication) {
        select(app.buttons["live-channel-multiview"], in: app)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func chooseGuideChannel(_ number: Int, in app: XCUIApplication) {
        let target = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@ AND label == %@",
            "live-tv-channel-", "live-tv-channel-content-", "Sports \(number)"
        )).firstMatch
        for _ in 0..<16 {
            if target.exists {
                select(target, in: app)
                return
            }
            XCUIRemote.shared.press(.down)
        }
        XCTFail("Guide channel \(number) was not reachable. \(app.debugDescription)")
    }

    @MainActor
    private func confirmCloseMultiview(in app: XCUIApplication) {
        let dialog = app.sheets["Close Multiview?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let close = dialog.buttons.matching(NSPredicate(format: "label == %@", "Close Multiview")).firstMatch
        select(close, in: app)
        let dismissed = NSPredicate { _, _ in !dialog.exists }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5),
            .completed)
    }

    @MainActor
    func testProductionGuideAddsReplacesAndCancelsWithoutDiscardingMultiview() {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        select(app.buttons["live-tv-channel-channels-2"], in: app)
        selectMenuItem("Add to Favorites", in: app)
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["live-tv-category-list"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].exists)
        XCTAssertFalse(app.staticTexts["Choose channel"].exists)
        capture("actual-guide-selects-multiview-channel", in: app)
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        let current = app.buttons["live-tv-channel-channels-1"]
        select(current, in: app, activate: false)
        XCUIRemote.shared.press(.left)
        select(app.buttons["live-tv-search"], in: app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["live-multiview-guide-selection"].waitForExistence(timeout: 5))
        select(app.buttons["live-multiview-cancel-selection"], in: app)
        XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 5))
        assertMetrics("Engines 1 loads 1 stops 0 audible 1", in: app)
        openMultiviewPicker(in: app)
        chooseGuideChannel(2, in: app)
        assertMetrics("Engines 2 loads 2 stops 0 audible 1", in: app)
        focusAudio("Sports 2", in: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        selectMenuItem("Replace channel", in: app)
        chooseGuideChannel(3, in: app)
        let replaced = NSPredicate { _, _ in
            let player = app.staticTexts["multiview-fixture-player-2"]
            return player.exists && player.label == "Engine 2 loads 2"
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: replaced, object: nil)], timeout: 5),
            .completed, app.debugDescription)
        XCTAssertEqual(app.staticTexts["multiview-fixture-player-1"].label, "Engine 1 loads 1")
        XCTAssertTrue(pane("Sports 3", in: app).exists)
        finishSetup(in: app)
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        let keepWatching = app.buttons.matching(identifier: "Keep watching").firstMatch
        XCTAssertTrue(keepWatching.waitForExistence(timeout: 5))
        XCTAssertTrue(pane("Sports 1", in: app).exists)
        select(keepWatching, in: app)
        XCTAssertTrue(pane("Sports 3", in: app).waitForExistence(timeout: 5))
        assertChromeHidden(in: app)
        XCUIRemote.shared.press(.menu)
        confirmCloseMultiview(in: app)
        XCTAssertTrue(app.buttons["live-tv-search"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFavoriteMultiviewRestoresMainAndStackAfterRelaunch() {
        continueAfterFailure = false
        let app = launchProductionGuide()
        defer { app.terminate() }
        startProductionChannel(in: app)
        openMultiviewPicker(in: app)
        for number in 2...4 {
            if number > 2 { select(app.buttons["live-multiview-add"], in: app) }
            chooseGuideChannel(number, in: app)
            assertMetrics("Engines \(number) loads \(number) stops 0 audible 1", in: app)
        }
        select(app.buttons["live-multiview-layout"], in: app)
        selectMenuItem("Main and stack", in: app)
        select(app.buttons["live-multiview-more"], in: app)
        selectMenuItem("Favorite", in: app)
        select(app.buttons["live-multiview-more"], in: app)
        XCTAssertTrue(app.cells.containing(NSPredicate(format: "label == %@", "Unfavorite")).firstMatch.exists)
        XCUIRemote.shared.press(.menu)
        capture("favorite-main-and-stack-setup", in: app)
        app.terminate()
        app.launchArguments = ["--live-root-fixture", "--preserve-multiview-favorites"]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-multiview-favorites"].waitForExistence(timeout: 10))
        select(app.buttons["live-tv-multiview-favorites"], in: app)
        let saved = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "live-multiview-saved-")).firstMatch
        select(saved, in: app)
        assertMetrics("Engines 4 loads 4 stops 0 audible 1", in: app)
        let main = pane("Sports 1", in: app)
        for number in 2...4 {
            let secondary = pane("Sports \(number)", in: app)
            XCTAssertGreaterThan(main.frame.width, secondary.frame.width * 2)
            XCTAssertGreaterThan(secondary.frame.minX, main.frame.maxX)
            if number > 2 {
                let previous = pane("Sports \(number - 1)", in: app)
                XCTAssertGreaterThan(secondary.frame.minY, previous.frame.maxY)
            }
        }
        capture("favorite-main-and-stack-restored", in: app)
    }

    @MainActor
    private func launchProductionGuide() -> XCUIApplication {
        let app = fixtureApplication()
        app.launchArguments = ["--live-root-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-channel-channels-1"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func startProductionChannel(in app: XCUIApplication) {
        select(app.buttons["live-tv-channel-channels-1"], in: app)
        selectMenuItem("Play channel", in: app)
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func assertSideBySideFillsScreen(in app: XCUIApplication) {
        finishSetup(in: app)
        for index in 0..<2 {
            let width = (app.frame.width - 8) / 2
            assertVideoFrame(index + 1, equals: CGRect(
                x: app.frame.minX + CGFloat(index) * (width + 8),
                y: app.frame.minY, width: width, height: app.frame.height
            ), in: app)
        }
    }

    @MainActor
    private func audioActivations(_ engine: Int, in app: XCUIApplication) -> Int {
        let value = app.staticTexts["multiview-fixture-player-\(engine)"].value as? String
        guard let value, let count = Int(value) else {
            XCTFail("Missing audio activation count for engine \(engine)")
            return -1
        }
        return count
    }

    @MainActor
    private func settledVideoFrame(_ engine: Int, in app: XCUIApplication) -> CGRect {
        let video = app.otherElements["multiview-fixture-video-\(engine)"]
        var previous = CGRect.null
        var stableSince = ContinuousClock.now
        let settled = NSPredicate { _, _ in
            let frame = video.frame
            if frame != previous {
                previous = frame
                stableSince = .now
                return false
            }
            return stableSince.duration(to: .now) >= .milliseconds(500)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: settled, object: nil)
        ], timeout: 5), .completed, "Measure the rendered video after its focus/layout animation.")
        return video.frame
    }

    @MainActor
    private func assertVideoFrame(_ engine: Int, equals slot: CGRect, in app: XCUIApplication) {
        let width = min(slot.width, slot.height * 16 / 9)
        let height = width * 9 / 16
        let expected = CGRect(
            x: slot.midX - width / 2, y: slot.midY - height / 2, width: width, height: height)
        let video = app.otherElements["multiview-fixture-video-\(engine)"]
        let matches = NSPredicate { _, _ in
            guard video.exists else { return false }
            let actual = video.frame
            return abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
                && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Video \(engine) must receive its maximum player slot \(expected): " +
                (video.exists ? "\(video.frame)" : "missing")
        )
    }

    @MainActor
    private func assertCornerLayout(
        in app: XCUIApplication, topLeft: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let main = app.otherElements["multiview-fixture-video-1"]
        let inset = app.otherElements["multiview-fixture-video-2"]
        let matches = NSPredicate { _, _ in
            guard main.exists, inset.exists, inset.frame.width < main.frame.width / 2,
                  main.frame.insetBy(dx: -1, dy: -1).contains(inset.frame) else { return false }
            return !topLeft || (inset.frame.midX < main.frame.midX && inset.frame.midY < main.frame.midY)
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, app.debugDescription, file: file, line: line
        )
        if app.buttons["live-multiview-layout"].exists {
            XCTAssertGreaterThan(main.frame.minX, app.frame.minX)
            XCTAssertGreaterThan(main.frame.minY, app.frame.minY)
            XCTAssertLessThan(main.frame.maxY, app.frame.maxY)
        } else {
            assertVideoFrame(1, equals: app.frame, in: app)
        }
    }

    @MainActor
    private func selectMenuItem(
        _ title: String, identifierPrefix: String = "", in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // tvOS exposes Menu actions as focused collection cells, not AX buttons.
        let predicate = identifierPrefix.isEmpty
            ? NSPredicate(format: "label == %@", title)
            : NSPredicate(
                format: "label == %@ AND identifier BEGINSWITH %@", title, identifierPrefix
            )
        let item = app.cells.containing(predicate).firstMatch
        select(item, in: app, file: file, line: line)
    }

    @MainActor
    private func select(
        _ target: XCUIElement, in app: XCUIApplication,
        activate: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard target.exists || target.waitForExistence(timeout: 5) else {
            XCTFail(
                "Missing target: \(target). Native focus: \(nativeFocus(in: app)). \(app.debugDescription)",
                file: file, line: line
            )
            return
        }
        var previousFrame: CGRect?
        var previousMoveWasVertical = false
        for _ in 0..<16 {
            let targetContainsFocus = target.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
            if target.hasFocus || targetContainsFocus {
                if activate { XCUIRemote.shared.press(.select) }
                return
            }
            let focused = focusedElement(in: app)
            guard focused.exists else {
                XCTContext.runActivity(named: "Native focus transition") { activity in
                    activity.add(XCTAttachment(string: nativeFocus(in: app)))
                }
                let movingUp = previousFrame.map { target.frame.midY < $0.midY } ?? false
                XCUIRemote.shared.press(movingUp ? .up : .down)
                continue
            }
            let sameNativeCell = target.elementType == .cell && focused.elementType == .cell &&
                abs(target.frame.midX - focused.frame.midX) < 2 &&
                abs(target.frame.midY - focused.frame.midY) < 2
            if sameNativeCell || (!target.identifier.isEmpty && focused.identifier == target.identifier) ||
               ((!target.identifier.isEmpty || !target.label.isEmpty) &&
               focused.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@", target.identifier, target.label
                )
            ).firstMatch.exists) {
                if activate { XCUIRemote.shared.press(.select) }
                return
            }
            let destination = target.frame
            let origin = focused.frame
            let stalled = previousFrame == origin
            previousFrame = origin
            let below = destination.minY >= origin.maxY - 1
            let above = destination.maxY <= origin.minY + 1
            let horizontalGap = destination.minX >= origin.maxX - 1 || destination.maxX <= origin.minX + 1
            let verticalCenters = !horizontalGap &&
                abs(destination.midY - origin.midY) > abs(destination.midX - origin.midX)
            if (above || below || verticalCenters) && !(stalled && previousMoveWasVertical && horizontalGap) {
                XCUIRemote.shared.press(destination.midY > origin.midY ? .down : .up)
                previousMoveWasVertical = true
            } else {
                XCUIRemote.shared.press(destination.midX > origin.midX ? .right : .left)
                previousMoveWasVertical = false
            }
        }
        let focused = focusedElement(in: app)
        XCTFail(
            "Remote focus cannot reach \(target). Focus: \(focused.exists ? focused.debugDescription : "none"). " +
                "Native focus: \(nativeFocus(in: app)). \(app.debugDescription)",
            file: file, line: line
        )
    }

    @MainActor
    private func focusedElement(in app: XCUIApplication) -> XCUIElement {
        let reported = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard !reported.exists || reported.elementType == .other else { return reported }
        let diagnostic = nativeFocus(in: app)
        let prefix = "focusWindowFrame="
        guard let component = diagnostic.components(separatedBy: " | ")
            .first(where: { $0.hasPrefix(prefix) }) else { return reported }
        let frame = NSCoder.cgRect(for: String(component.dropFirst(prefix.count)))
        guard frame.width > 0, frame.height > 0 else { return reported }
        // Native controls can own UIKit focus without AX hasFocus. AX includes
        // the rendered lift while the focus item can report the resting bounds.
        let candidates = diagnostic.contains("focused=_UIContextMenuCell |")
            ? app.cells.allElementsBoundByIndex
            : app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                "live-multiview-", "live-channel-"
            )).allElementsBoundByIndex
        return candidates.first {
            let candidate = $0.frame
            return abs(candidate.midX - frame.midX) < 2 &&
                abs(candidate.midY - frame.midY) < 2 &&
                abs(candidate.width - frame.width) < max(2, frame.width * 0.15) &&
                abs(candidate.height - frame.height) < max(2, frame.height * 0.15)
        } ?? reported
    }

    @MainActor
    private func pane(_ channel: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "live-multiview-pane-", channel
        )).firstMatch
    }

    @MainActor
    private func assertNativeFocus(
        _ target: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let matches = NSPredicate { _, _ in
            guard target.exists else { return false }
            if target.hasFocus { return true }
            let focused = self.focusedElement(in: app)
            guard focused.exists else { return false }
            if !target.identifier.isEmpty { return focused.identifier == target.identifier }
            return !target.label.isEmpty && focused.label == target.label && focused.elementType == target.elementType
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, "Expected native focus on \(target). \(nativeFocus(in: app)). \(app.debugDescription)",
            file: file, line: line
        )
    }

    @MainActor
    private func launchVisualFixture(reduceGlass: Bool = false) -> XCUIApplication {
        let app = fixtureApplication()
        app.launchArguments = ["--multiview-fixture", "--visual-focus-fixture"]
        if reduceGlass { app.launchArguments.append("--reduce-panel-glass") }
        app.launch()
        XCTAssertTrue(app.staticTexts["multiview-fixture-player-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["live-channel-multiview"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    @discardableResult
    private func capture(_ name: String, in app: XCUIApplication) -> UIImage {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot.image
    }

    @MainActor
    private func assertRenderedFocus(
        _ target: XCUIElement, anchor: XCUIElement, name: String,
        preservesVideo: Bool = false, visualSurface: XCUIElement? = nil, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        select(anchor, in: app, activate: false, file: file, line: line)
        guard target.exists else {
            XCTFail("Missing visual focus target \(name)", file: file, line: line)
            return
        }
        if let visualSurface {
            guard visualSurface.exists, !visualSurface.frame.isEmpty else {
                XCTFail("Missing rendered video surface for \(name)", file: file, line: line)
                return
            }
        }
        // Include the native lift's full rendered bounds, not only its resting slot.
        let frame = visualSurface?.frame ?? target.frame
        let before = capture("\(name)-unfocused", in: app)
        select(target, in: app, activate: false, file: file, line: line)
        let after = capture("\(name)-focused", in: app)
        let region = frame.union(visualSurface?.frame ?? target.frame).insetBy(dx: -8, dy: -8)
        let change = pixelDifference(before, after, region: region, screen: app.frame)
        let evidence = "\(name): changed pixel fraction=\(change.fraction), mean RGB delta=\(change.mean)"
        let attachment = XCTAttachment(string: "\(evidence)\n\(nativeFocus(in: app))")
        attachment.name = "\(name)-pixel-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(
            change.fraction, preservesVideo ? 0.007 : 0.03,
            "Focused \(name) must have a visible treatment. \(evidence)", file: file, line: line
        )
        if preservesVideo {
            let sample = CGRect(
                x: frame.minX + frame.width * 0.18, y: frame.minY + frame.height * 0.22,
                width: frame.width * 0.12, height: frame.height * 0.12
            )
            let videoChange = pixelDifference(before, after, region: sample, screen: app.frame)
            let videoEvidence = XCTAttachment(string: "\(name): video RGB delta=\(videoChange.mean)")
            videoEvidence.name = "\(name)-video-evidence"
            videoEvidence.lifetime = .keepAlways
            add(videoEvidence)
            XCTAssertLessThan(
                videoChange.mean, 0.06,
                "Focus must not wash out \(name)'s video: RGB delta=\(videoChange.mean)",
                file: file, line: line
            )
        }
    }

    private func pixelDifference(
        _ before: UIImage, _ after: UIImage, region: CGRect, screen: CGRect
    ) -> (fraction: Double, mean: Double) {
        guard let first = before.cgImage, let second = after.cgImage,
              first.width == second.width, first.height == second.height else { return (0, 1) }
        let width = first.width
        let height = first.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { storage in
                let context = CGContext(
                    data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let a = pixels(first)
        let b = pixels(second)
        let clipped = region.intersection(screen)
        guard !clipped.isNull, !clipped.isEmpty else { return (0, 1) }
        let x0 = max(0, Int(clipped.minX / screen.width * Double(width)))
        let x1 = min(width, Int(clipped.maxX / screen.width * Double(width)))
        let y0 = max(0, Int(clipped.minY / screen.height * Double(height)))
        let y1 = min(height, Int(clipped.maxY / screen.height * Double(height)))
        var changed = 0
        var sum = 0.0
        let count = (x1 - x0) * (y1 - y0)
        guard count > 0 else { return (0, 1) }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                let delta = (0..<3).reduce(0) { $0 + abs(Int(a[offset + $1]) - Int(b[offset + $1])) }
                let normalized = Double(delta) / (3 * 255)
                if normalized > 0.15 { changed += 1 }
                sum += normalized
            }
        }
        return (Double(changed) / Double(count), sum / Double(count))
    }

    @MainActor
    private func nativeFocus(in app: XCUIApplication) -> String {
        let diagnostics = app.staticTexts["multiview-fixture-focus-diagnostics"]
        guard diagnostics.exists else { return "unavailable" }
        return diagnostics.value as? String ?? "unavailable"
    }

    @MainActor
    private func assertMetrics(
        _ expected: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let metrics = app.staticTexts["multiview-fixture-metrics"]
        let matches = NSPredicate { _, _ in metrics.exists && metrics.label == expected }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5),
            .completed, app.debugDescription, file: file, line: line
        )
    }
}
