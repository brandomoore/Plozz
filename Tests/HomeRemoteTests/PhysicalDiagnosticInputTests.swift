import XCTest
import notify

@MainActor
final class PhysicalDiagnosticInputTests: XCTestCase {
    func testExistingLiveTVPublishesSavedChannels() throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_CAPTURE_LIVE_TV_LOADING"] == "1",
              ProcessInfo.processInfo.environment["PLOZZ_CAPTURE_BUNDLE_ID"] == "com.thatcube.Plozz" else {
            throw XCTSkip("Explicit saved-playlist loading check in the foreground physical app only.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        XCTAssertEqual(app.state, .runningForeground)
        guard app.state == .runningForeground else { return }
        defer {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Existing Live TV loading result"
            tree.lifetime = .keepAlways
            add(tree)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Existing Live TV loaded screen"
            image.lifetime = .keepAlways
            add(image)
        }
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "live-tv-channel-content-channels-")
        )
        let introduction = app.buttons["live-tv-preview-enable"]
        let skeleton = app.descendants(matching: .any)["live-tv-guide-skeleton"]
        var navigated = false
        var started = ProcessInfo.processInfo.systemUptime
        if !rows.firstMatch.exists && !introduction.exists && !skeleton.exists {
            let destination = app.buttons.matching(
                NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Live TV", "Live TV,")
            ).firstMatch
            XCTAssertTrue(destination.exists, "No known Live TV navigation control; no input sent.")
            guard destination.exists else { return }
            for _ in 0..<12 where !destination.hasFocus {
                let focused = app.descendants(matching: .any).matching(
                    NSPredicate(format: "hasFocus == true")
                ).firstMatch
                guard focused.exists else {
                    XCTFail("No current focus; no selection sent.")
                    return
                }
                if focused.frame.midX > destination.frame.maxX {
                    XCUIRemote.shared.press(.left)
                } else {
                    XCUIRemote.shared.press(focused.frame.midY < destination.frame.midY ? .down : .up)
                }
            }
            XCTAssertTrue(destination.hasFocus, "Could not reach Live TV; no selection sent.")
            guard destination.hasFocus else { return }
            started = ProcessInfo.processInfo.systemUptime
            XCUIRemote.shared.press(.select)
            navigated = true
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            rows.firstMatch.exists || introduction.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                       "Saved channels must replace loading placeholders without a full playlist download.")
        XCTAssertFalse(skeleton.exists)
        print("PLZLIVETV saved-loading navigated=\(navigated) observed_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }

    func testRepeatedDownThroughExistingSubfolders() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_CAPTURE_FOLDER_DOWN"] == "1",
              let bundleID = environment["PLOZZ_CAPTURE_BUNDLE_ID"], !bundleID.isEmpty else {
            throw XCTSkip("Explicit repeated-Down capture in an already-open folder only.")
        }
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26.") }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        XCTAssertEqual(app.state, .runningForeground)
        guard app.state == .runningForeground else { return }
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Or open a subfolder")).firstMatch.exists,
              focused.exists,
              focused.identifier.hasPrefix("share-location:") || focused.images["folder.fill"].exists else {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "Folder input refused - current accessibility"
            state.lifetime = .keepAlways
            add(state)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Folder input refused - current screen"
            image.lifetime = .keepAlways
            add(image)
            XCTFail("Position focus on an existing subfolder before measuring; no input sent.")
            return
        }
        let beforeLabel = focused.label
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Before repeated folder Down"
        before.lifetime = .keepAlways
        add(before)
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var iteration = 0
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            iteration += 1
            print("PLZFOLDER iteration.begin index=\(iteration)")
            startMeasuring()
            for index in 1...8 {
                let start = ProcessInfo.processInfo.systemUptime
                print("PLZFOLDER down.begin index=\(index) epoch=\(Date().timeIntervalSince1970)")
                XCUIRemote.shared.press(.down)
                print("PLZFOLDER down.end index=\(index) commandSeconds=\(ProcessInfo.processInfo.systemUptime - start)")
                Thread.sleep(forTimeInterval: 0.35)
            }
            stopMeasuring()
        }
        let after = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(after.exists && (after.identifier.hasPrefix("share-location:") || after.images["folder.fill"].exists))
        XCTAssertNotEqual(after.label, beforeLabel, "Repeated Down must advance through the list.")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "After repeated folder Down"
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Folder navigation result"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testInspectRecordingStatusWithoutInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_CAPTURE_INSPECT_STATUS"] == "1",
              let bundleID = environment["PLOZZ_CAPTURE_BUNDLE_ID"], !bundleID.isEmpty else {
            throw XCTSkip("Explicit existing-app status inspection only.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        print("PLZCAPTURE inspection.state=\(app.state.rawValue)")
        XCTAssertEqual(app.state, .runningForeground)
        guard app.state == .runningForeground else { return }
        XCTAssertEqual(notify_post(bundleID + ".Diagnostics.preparing"), UInt32(NOTIFY_STATUS_OK))
        defer { notify_post(bundleID + ".Diagnostics.finished") }
        let badge = app.staticTexts["diagnostic-recording-status"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Existing app recording status"
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Recording status accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func testPressFocusedControlAfterRecordingConfirmation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PLOZZ_CAPTURE_EXISTING_APP"] == "1",
              let label = environment["PLOZZ_CAPTURE_FOCUSED_LABEL"], !label.isEmpty,
              let bundleID = environment["PLOZZ_CAPTURE_BUNDLE_ID"], !bundleID.isEmpty else {
            throw XCTSkip("Requires the already-running physical TV app and an explicitly confirmed recorder.")
        }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        XCTAssertEqual(app.state, .runningForeground)
        guard app.state == .runningForeground else { return }
        let target = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "Before the single focused-control press"
        before.lifetime = .keepAlways
        add(before)
        XCTAssertTrue(target.exists && target.hasFocus, "Do not move focus or press a different control.")
        guard target.exists && target.hasFocus else { return }

        let notification = "com.thatcube.Plozz.DiagnosticInput.\(UUID().uuidString)"
        let recording = XCTestExpectation(description: "Parent confirms sustained recording")
        var token: Int32 = 0
        let status = notify_register_dispatch(notification, &token, .main) { _ in recording.fulfill() }
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            XCTFail("Cannot register the recording confirmation; no input sent.")
            return
        }
        defer { notify_cancel(token) }
        print("PLZCAPTURE ready notification=\(notification) relaunch=false")
        guard await XCTWaiter.fulfillment(of: [recording], timeout: 120) == .completed else {
            XCTFail("Recording was not confirmed; no input sent.")
            return
        }
        guard app.state == .runningForeground, target.exists && target.hasFocus else {
            XCTFail("The original focused control changed; no input sent.")
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        print("PLZCAPTURE select.begin epoch=\(Date().timeIntervalSince1970) uptime=\(start)")
        XCUIRemote.shared.press(.select)
        print("PLZCAPTURE select.end elapsed=\(ProcessInfo.processInfo.systemUptime - start)")
        let observation = min(180, max(5, Double(environment["PLOZZ_CAPTURE_OBSERVE_SECONDS"] ?? "") ?? 75))
        try await Task.sleep(for: .seconds(observation))
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "After the single focused-control press"
        after.lifetime = .keepAlways
        add(after)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Result accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        print("PLZCAPTURE observation.complete relaunch=false")
    }
}
