import XCTest

@MainActor
final class NativeLibraryPosterRemoteTests: XCTestCase {
    private static var controlledArm: String?
    private static var controlledPath: [String] = []

    private struct InputTiming: Encodable {
        let index: Int
        let relativeSeconds: Double
        let lateSeconds: Double
        let durationSeconds: Double
    }

    private struct WindowTiming: Encodable {
        let arm: String
        let phase: String
        let iteration: Int
        let epoch: Double
        let durationSeconds: Double
        let inputs: [InputTiming]
        var measurementBoundary: MeasurementBoundaryTiming? = nil
    }

    private struct MeasurementBoundaryTiming: Encodable {
        let earliestStartEpoch: Double
        let latestStopEpoch: Double
        let startCallSeconds: Double
        let stopCallSeconds: Double
        let outerDurationSeconds: Double
    }

    func testControlledAIdle() async throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26.") }
        let app = try existingApp()
        executionTimeAllowance = 900
        let environment = ProcessInfo.processInfo.environment
        let arm = try XCTUnwrap(environment["PLOZZ_LIBRARY_POSTER_ARM"])
        XCTAssertTrue(["baseline", "composited"].contains(arm))
        let useCurrentGrid = environment["PLOZZ_LIBRARY_USE_CURRENT_GRID"] == "1"
        let expectedPathJSON = environment["PLOZZ_LIBRARY_EXPECTED_PATH"] ?? ""
        let expectedPath = expectedPathJSON.isEmpty ? [] : try JSONDecoder().decode(
            [String].self, from: Data(expectedPathJSON.utf8)
        )
        let launchEpoch = try XCTUnwrap(environment["PLOZZ_LIBRARY_LAUNCH_EPOCH"].flatMap(Double.init))
        let age = Date().timeIntervalSince1970 - launchEpoch
        XCTAssertGreaterThanOrEqual(age, 0)
        if !useCurrentGrid {
            XCTAssertLessThan(age, 240, "Automated blocks require a fresh, externally recorded launch.")
        }
        Self.controlledArm = nil
        Self.controlledPath = []
        addTeardownBlock { @MainActor in self.capture(app, name: "controlled-\(arm)-idle") }

        let initial: String
        if useCurrentGrid {
            initial = try focusedPoster(in: app, arm: arm).label
        } else {
            try await Task.sleep(for: .seconds(max(0, launchEpoch + 60 - Date().timeIntervalSince1970)))
            let library = try XCTUnwrap(environment["PLOZZ_LIBRARY_TARGET_LABEL"])
            XCTAssertEqual(expectedPath.count, 7)
            initial = try XCTUnwrap(expectedPath.first)
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(focused.waitForExistence(timeout: 60))
            var foundMovies = false
            for _ in 0..<48 {
                if focused.label == "Movies"
                    || focused.buttons.matching(NSPredicate(format: "label == %@", "Movies")).count == 1 {
                    foundMovies = true
                    break
                }
                XCUIRemote.shared.press(.down)
                try await Task.sleep(for: .milliseconds(700))
            }
            XCTAssertTrue(foundMovies, "Never select an unverified library or media title.")
            for _ in 0..<12 {
                if focused.label == library
                    || focused.buttons.matching(NSPredicate(format: "label == %@", library)).count == 1 {
                    break
                }
                XCUIRemote.shared.press(.right)
            }
            XCTAssertTrue(
                focused.label == library
                    || focused.buttons.matching(NSPredicate(format: "label == %@", library)).count == 1,
                "The requested actual library must be selected, not another server's grid."
            )
            XCUIRemote.shared.press(.select)
            let recommended = app.buttons.matching(NSPredicate(
                format: "label == %@ AND hasFocus == true", "Recommended"
            )).firstMatch
            XCTAssertTrue(recommended.waitForExistence(timeout: 30))
            XCUIRemote.shared.press(.right)
            let browse = app.buttons.matching(NSPredicate(format: "label == %@ AND hasFocus == true", "Browse")).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10))
            XCUIRemote.shared.press(.select)
            let firstPoster = app.cells.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "native-library-poster-\(arm)", initial
            )).firstMatch
            XCTAssertTrue(firstPoster.waitForExistence(timeout: 60))
            try await Task.sleep(for: .seconds(2))
            XCUIRemote.shared.press(.down)
            let startColumn = try focusedPoster(in: app, arm: arm).label
            if startColumn != initial { XCUIRemote.shared.press(.left) }
            XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
        }
        XCTAssertTrue(app.staticTexts["Filter"].exists, "The workload must include all watch states.")
        XCTAssertTrue(app.staticTexts["Sort: Name"].exists)
        var path = [initial]
        for _ in 0..<6 {
            XCUIRemote.shared.press(.down)
            try await Task.sleep(for: .milliseconds(500))
            let label = try focusedPoster(in: app, arm: arm).label
            XCTAssertNotEqual(label, path.last)
            path.append(label)
        }
        if !expectedPath.isEmpty {
            XCTAssertEqual(path, expectedPath, "Every row must match the same actual library workload.")
        }
        for _ in 0..<6 { XCUIRemote.shared.press(.up) }
        XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, path.first)
        let readyEpoch = Date().timeIntervalSince1970
        let minimumAge = environment["PLOZZ_LIBRARY_MINIMUM_STARTUP_AGE"].flatMap(Double.init) ?? 480
        XCTAssertGreaterThanOrEqual(minimumAge, 480)
        let measurementEpoch = max(launchEpoch + minimumAge, readyEpoch + 60)
        print("LIBRARY_POSTER controlled-ready arm=\(arm) epoch=\(readyEpoch) launch=\(launchEpoch) idleNotBefore=\(measurementEpoch)")
        let attachment = XCTAttachment(string: path.joined(separator: "\n"))
        attachment.name = "controlled-\(arm)-calibrated-path"
        attachment.lifetime = .keepAlways
        add(attachment)
        while Date().timeIntervalSince1970 < measurementEpoch {
            let remaining = measurementEpoch - Date().timeIntervalSince1970
            try await Task.sleep(for: .seconds(min(30, max(0, remaining))))
            XCTContext.runActivity(named: "Waiting for the recorded startup settling deadline") { _ in }
        }
        try measureControlled(app, arm: arm, path: path, idle: true)
        Self.controlledArm = arm
        Self.controlledPath = path
    }

    func testControlledBTraversal() throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26.") }
        // Do not reactivate here: foreground refresh work would invalidate the idle comparison.
        let app = try existingApp(activate: false)
        let arm = try XCTUnwrap(Self.controlledArm, "The matched idle test must finish in the same runner first.")
        addTeardownBlock { @MainActor in self.capture(app, name: "controlled-\(arm)-traversal") }
        Thread.sleep(forTimeInterval: 10)
        try measureControlled(app, arm: arm, path: Self.controlledPath, idle: false)
    }

    func testProfileRealLibraryTraversal() throws {
        let app = try existingApp()
        let arm = try XCTUnwrap(ProcessInfo.processInfo.environment["PLOZZ_LIBRARY_POSTER_ARM"])
        let initial = try focusedPoster(in: app, arm: arm).label
        let start = ProcessInfo.processInfo.systemUptime
        let epoch = Date().timeIntervalSince1970
        var inputs: [InputTiming] = []
        for index in 0..<12 {
            let deadline = start + Double(index) * 2
            Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
            let sent = ProcessInfo.processInfo.systemUptime
            XCUIRemote.shared.press(index < 6 ? .down : .up)
            inputs.append(InputTiming(
                index: index, relativeSeconds: sent - start, lateSeconds: sent - deadline,
                durationSeconds: ProcessInfo.processInfo.systemUptime - sent
            ))
        }
        Thread.sleep(forTimeInterval: max(0, start + 24 - ProcessInfo.processInfo.systemUptime))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        try attachTiming(WindowTiming(
            arm: arm, phase: "profile", iteration: 1, epoch: epoch, durationSeconds: elapsed, inputs: inputs
        ))
        print("LIBRARY_POSTER profile-window epoch=\(epoch) duration=\(elapsed)")
        for input in inputs {
            print("LIBRARY_POSTER profile-input index=\(input.index) at=\(input.relativeSeconds)")
            XCTAssertEqual(input.relativeSeconds, Double(input.index) * 2, accuracy: 0.15)
            XCTAssertLessThan(input.durationSeconds, 1.95)
        }
        XCTAssertEqual(elapsed, 24, accuracy: 0.15)
        XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
        capture(app, name: "profiled-library-roundtrip")
    }

    @available(tvOS 26.0, *)
    private func measureControlled(_ app: XCUIApplication, arm: String, path: [String], idle: Bool) throws {
        let initial = try XCTUnwrap(path.first)
        XCTAssertEqual(path.count, 7)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        let phase = idle ? "idle" : "scroll"
        var iteration = 0
        var inputFailure: Error?
        measure(metrics: [
            XCTClockMetric(),
            XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)
        ], options: options) {
            iteration += 1
            do {
                XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
                var inputs: [InputTiming] = []
                let earliestStartEpoch = Date().timeIntervalSince1970
                let startCall = ProcessInfo.processInfo.systemUptime
                startMeasuring()
                let start = ProcessInfo.processInfo.systemUptime
                let epoch = Date().timeIntervalSince1970
                if idle {
                    Thread.sleep(forTimeInterval: 24)
                } else {
                    for index in 0..<12 {
                        let deadline = start + Double(index) * 2
                        Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                        let sent = ProcessInfo.processInfo.systemUptime
                        XCUIRemote.shared.press(index < 6 ? .down : .up)
                        let completed = ProcessInfo.processInfo.systemUptime
                        inputs.append(InputTiming(
                            index: index, relativeSeconds: sent - start, lateSeconds: sent - deadline,
                            durationSeconds: completed - sent
                        ))
                    }
                    Thread.sleep(forTimeInterval: max(0, start + 24 - ProcessInfo.processInfo.systemUptime))
                }
                let stopCall = ProcessInfo.processInfo.systemUptime
                let elapsed = stopCall - start
                stopMeasuring()
                let stopped = ProcessInfo.processInfo.systemUptime
                let boundary = MeasurementBoundaryTiming(
                    earliestStartEpoch: earliestStartEpoch,
                    latestStopEpoch: Date().timeIntervalSince1970,
                    startCallSeconds: start - startCall,
                    stopCallSeconds: stopped - stopCall,
                    outerDurationSeconds: stopped - startCall
                )
                try attachTiming(WindowTiming(
                    arm: arm, phase: phase, iteration: iteration, epoch: epoch,
                    durationSeconds: elapsed, inputs: inputs, measurementBoundary: boundary
                ))
                print("LIBRARY_POSTER controlled-window arm=\(arm) phase=\(phase) iteration=\(iteration) epoch=\(epoch) duration=\(elapsed)")
                for input in inputs {
                    print("LIBRARY_POSTER controlled-input iteration=\(iteration) index=\(input.index) at=\(input.relativeSeconds) late=\(input.lateSeconds) duration=\(input.durationSeconds)")
                    XCTAssertLessThan(input.lateSeconds, 0.15, "Late remote delivery invalidates the matched cadence.")
                    XCTAssertLessThan(input.durationSeconds, 1.95, "Remote delivery overran its two-second slot.")
                }
                XCTAssertEqual(elapsed, 24, accuracy: 0.15)
                XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
                Thread.sleep(forTimeInterval: 2)
            } catch {
                inputFailure = error
                XCTFail("Unverified controlled window: \(error)")
            }
        }
        if let inputFailure { throw inputFailure }
    }

    func testObserveExistingApp() throws {
        let app = try existingApp()
        capture(app, name: "library-poster-observation")
    }

    func testNavigateExistingApp() throws {
        let app = try existingApp()
        addTeardownBlock { @MainActor in self.capture(app, name: "library-poster-navigation") }
        let environment = ProcessInfo.processInfo.environment
        let commands = (environment["PLOZZ_LIBRARY_NAVIGATION"] ?? "").split(separator: ",")
        XCTAssertLessThanOrEqual(commands.count, 12)
        for command in commands {
            let button: XCUIRemote.Button
            switch command {
            case "up": button = .up
            case "down": button = .down
            case "left": button = .left
            case "right": button = .right
            case "menu": button = .menu
            case "select":
                let expected = try XCTUnwrap(environment["PLOZZ_LIBRARY_SELECT_LABEL"])
                let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
                XCTAssertTrue(
                    focused.label == expected || focused.buttons.matching(NSPredicate(format: "label == %@", expected)).count == 1,
                    "Never select an unverified destination or media title."
                )
                button = .select
            default:
                XCTFail("Unsupported navigation input")
                return
            }
            XCTAssertEqual(app.state, .runningForeground)
            XCUIRemote.shared.press(button)
            Thread.sleep(forTimeInterval: 0.7)
        }
    }

    private func attachTiming(_ timing: WindowTiming) throws {
        let attachment = XCTAttachment(data: try JSONEncoder().encode(timing), uniformTypeIdentifier: "public.json")
        attachment.name = "library-\(timing.arm)-\(timing.phase)-\(timing.iteration)-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func existingApp(activate: Bool = true) throws -> XCUIApplication {
        #if !os(tvOS) || targetEnvironment(simulator)
        throw XCTSkip("Explicit physical-device library comparison only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let device = environment["PLOZZ_LIBRARY_PHYSICAL_DEVICE"], !device.isEmpty,
              environment["PLOZZ_LIBRARY_TARGET_DEVICE"] == device,
              environment["PLOZZ_LIBRARY_OPTIMIZED_APP"] == "1" else {
            throw XCTSkip("Requires a verified, already-running optimized Plozz and explicit physical target.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        XCTAssertNotEqual(app.state, .notRunning, "Never cold-launch or install the application from this runner.")
        // The external driver must verify that runner activation did not replace the app's PID.
        if activate && app.state != .runningForeground { app.activate() }
        XCTAssertEqual(app.state, .runningForeground)
        return app
        #endif
    }

    private func focusedPoster(in app: XCUIApplication, arm: String) throws -> XCUIElement {
        XCTAssertEqual(app.state, .runningForeground)
        let matches = app.descendants(matching: .any).matching(NSPredicate(
            format: "hasFocus == true AND identifier == %@", "native-library-poster-\(arm)"
        ))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(matches.count, 1, "The requested real library renderer must own focus.")
        let poster = matches.firstMatch
        XCTAssertGreaterThan(poster.frame.height, 100)
        return poster
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
