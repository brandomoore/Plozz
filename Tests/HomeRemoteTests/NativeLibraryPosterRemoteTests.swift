import XCTest

@MainActor
final class NativeLibraryPosterRemoteTests: XCTestCase {
    private static var controlledArm: String?
    private static var controlledPath: [String] = []
    private static var controlledIndices: [Int] = []
    private static var controlledGrid: UUID?

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
        var focusSnapshots: [LibraryTraversalSnapshot]? = nil
        var heldMinimumRows: Int? = nil
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
        Self.controlledIndices = []
        Self.controlledGrid = nil
        addTeardownBlock { @MainActor in self.capture(app, name: "controlled-\(arm)-idle") }

        let initial: String
        if useCurrentGrid {
            initial = try focusedPoster(in: app, arm: arm).label
        } else {
            try await Task.sleep(for: .seconds(max(0, launchEpoch + 60 - Date().timeIntervalSince1970)))
            let library = try XCTUnwrap(environment["PLOZZ_LIBRARY_TARGET_LABEL"])
            XCTAssertEqual(expectedPath.count, 19)
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
        XCTAssertEqual(app.buttons["library-filter-menu"].label, "Filter: All",
                       "The workload must include all watch states.")
        XCTAssertEqual(app.buttons["library-sort-menu"].label, "Sort: Name")
        let calibration = try traversalSnapshot(in: app)
        let firstIndex = try XCTUnwrap(calibration.focusedIndex)
        XCTAssertGreaterThan(calibration.columns, 0)
        let indices = (0...18).map { firstIndex + $0 * calibration.columns }
        XCTAssertLessThan(try XCTUnwrap(indices.last), calibration.total, "Calibrate all eighteen downward transitions.")
        var path = [initial]
        for index in indices.dropFirst() {
            XCUIRemote.shared.press(.down)
            try await Task.sleep(for: .milliseconds(500))
            let label = try focusedPoster(in: app, arm: arm).label
            let focused = try traversalSnapshot(in: app)
            XCTAssertEqual(focused.identity, calibration.identity)
            XCTAssertEqual(focused.focusedIndex, index, "The full route must stay in the calibrated column.")
            XCTAssertNotEqual(label, path.last)
            path.append(label)
        }
        if !expectedPath.isEmpty {
            XCTAssertEqual(path, expectedPath, "Every row must match the same actual library workload.")
        }
        for _ in 0..<18 { XCUIRemote.shared.press(.up) }
        XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, path.first)
        Self.controlledIndices = indices
        Self.controlledGrid = calibration.identity
        let readyEpoch = Date().timeIntervalSince1970
        let minimumAge = environment["PLOZZ_LIBRARY_MINIMUM_STARTUP_AGE"].flatMap(Double.init) ?? 480
        XCTAssertGreaterThanOrEqual(minimumAge, 480)
        let measurementEpoch = max(launchEpoch + minimumAge, readyEpoch + 60)
        print("LIBRARY_POSTER controlled-ready arm=\(arm) epoch=\(readyEpoch) launch=\(launchEpoch) idleNotBefore=\(measurementEpoch)")
        let attachment = XCTAttachment(string: path.joined(separator: "\n"))
        attachment.name = "controlled-\(arm)-calibrated-path"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Minutes of unchanging picture let the TV suspend the app (the screen saver, or the
        // panel's static-image protection over HDMI-CEC). Step focus to the next poster and
        // back every 45 seconds, stopping well before the idle measurement starts.
        while Date().timeIntervalSince1970 < measurementEpoch {
            let remaining = measurementEpoch - Date().timeIntervalSince1970
            try await Task.sleep(for: .seconds(min(45, max(0, remaining))))
            XCTContext.runActivity(named: "Waiting for the recorded startup settling deadline") { _ in }
            if measurementEpoch - Date().timeIntervalSince1970 > 30 {
                // The calibrated start is the first poster, so Right always has a neighbor.
                XCUIRemote.shared.press(.right)
                XCUIRemote.shared.press(.left)
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
            }
        }
        try measureControlled(app, arm: arm, path: path, phase: .idle)
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
        try measureControlled(app, arm: arm, path: Self.controlledPath, phase: .scroll)
    }

    /// Back-to-back presses, as fast as the remote API delivers them (about four a second),
    /// reach rows that have not been drawn yet and return to rows that have scrolled away.
    func testControlledCRapidTraversal() throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26.") }
        let app = try existingApp(activate: false)
        let arm = try XCTUnwrap(Self.controlledArm, "The matched idle test must finish in the same runner first.")
        addTeardownBlock { @MainActor in self.capture(app, name: "controlled-\(arm)-rapid") }
        Thread.sleep(forTimeInterval: 10)
        try measureControlled(app, arm: arm, path: Self.controlledPath, phase: .rapid)
    }

    /// Held input must meet a declared depth and return; repeat throughput is observed.
    func testControlledDHeldTraversal() throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26.") }
        let app = try existingApp(activate: false)
        let arm = try XCTUnwrap(Self.controlledArm, "The matched idle test must finish in the same runner first.")
        addTeardownBlock { @MainActor in self.capture(app, name: "controlled-\(arm)-held") }
        Thread.sleep(forTimeInterval: 10)
        try measureControlled(app, arm: arm, path: Self.controlledPath, phase: .held)
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

    private enum Phase: String {
        /// No input.
        case idle
        /// Six Down then six Up, one press every two seconds.
        case scroll
        /// Eighteen Down then eighteen Up, one press every 0.3 seconds.
        case rapid
        /// Down held for two seconds, then Up held for four, in five-second slots.
        case held

        var presses: (count: Int, interval: Double) {
            switch self {
            case .idle: (0, 0)
            case .scroll: (12, 2)
            case .rapid: (36, 0.3)
            case .held: (0, 5)
            }
        }
    }

    @available(tvOS 26.0, *)
    private func measureControlled(_ app: XCUIApplication, arm: String, path: [String], phase: Phase) throws {
        let initial = try XCTUnwrap(path.first)
        XCTAssertEqual(path.count, 19)
        let minimumRows: Int
        if let configured = ProcessInfo.processInfo.environment["PLOZZ_LIBRARY_HELD_MINIMUM_ROWS"] {
            minimumRows = try XCTUnwrap(Int(configured))
        } else {
            minimumRows = 18
        }
        XCTAssertGreaterThan(minimumRows, 0)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var iteration = 0
        var inputFailure: Error?
        measure(metrics: [
            XCTClockMetric(),
            XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)
        ], options: options) {
            iteration += 1
            do {
                XCTAssertEqual(try focusedPoster(in: app, arm: arm).label, initial)
                let before = try traversalSnapshot(in: app)
                XCTAssertEqual(before.identity, Self.controlledGrid, "The calibrated grid must not be replaced.")
                XCTAssertEqual(before.focusedIndex, Self.controlledIndices.first)
                var inputs: [InputTiming] = []
                let earliestStartEpoch = Date().timeIntervalSince1970
                let startCall = ProcessInfo.processInfo.systemUptime
                startMeasuring()
                let start = ProcessInfo.processInfo.systemUptime
                let epoch = Date().timeIntervalSince1970
                let (count, interval) = phase.presses
                for index in 0..<count {
                    let deadline = start + Double(index) * interval
                    Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                    let sent = ProcessInfo.processInfo.systemUptime
                    XCUIRemote.shared.press(index < count / 2 ? .down : .up)
                    let completed = ProcessInfo.processInfo.systemUptime
                    inputs.append(InputTiming(
                        index: index, relativeSeconds: sent - start, lateSeconds: sent - deadline,
                        durationSeconds: completed - sent
                    ))
                }
                if phase == .held {
                    for (index, (button, duration)) in [(XCUIRemote.Button.down, 2.0), (.up, 4.0)].enumerated() {
                        let deadline = start + Double(index) * interval
                        Thread.sleep(forTimeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime))
                        let sent = ProcessInfo.processInfo.systemUptime
                        XCUIRemote.shared.press(button, forDuration: duration)
                        inputs.append(InputTiming(
                            index: index, relativeSeconds: sent - start, lateSeconds: sent - deadline,
                            durationSeconds: ProcessInfo.processInfo.systemUptime - sent
                        ))
                    }
                }
                Thread.sleep(forTimeInterval: max(0, start + 24 - ProcessInfo.processInfo.systemUptime))
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
                let after = try traversalSnapshot(in: app)
                try attachTiming(WindowTiming(
                    arm: arm, phase: phase.rawValue, iteration: iteration, epoch: epoch,
                    durationSeconds: elapsed, inputs: inputs, measurementBoundary: boundary,
                    focusSnapshots: [before, after], heldMinimumRows: phase == .held ? minimumRows : nil
                ))
                let mode: LibraryTraversalValidation.Mode
                switch phase {
                case .idle: mode = .idle
                case .scroll: mode = .stepped(path: Array(Self.controlledIndices.prefix(7)))
                case .rapid: mode = .stepped(path: Self.controlledIndices)
                case .held: mode = .held(minimumRows: minimumRows)
                }
                let movement = try LibraryTraversalValidation.validate(
                    before: before, after: after, start: start, end: stopCall, mode: mode
                )
                print("LIBRARY_POSTER verified-movement phase=\(phase.rawValue) iteration=\(iteration) transitions=\(movement.transitions) deepestRow=\(movement.deepestRow)")
                print("LIBRARY_POSTER controlled-window arm=\(arm) phase=\(phase.rawValue) iteration=\(iteration) epoch=\(epoch) duration=\(elapsed)")
                for input in inputs {
                    print("LIBRARY_POSTER controlled-input iteration=\(iteration) index=\(input.index) at=\(input.relativeSeconds) late=\(input.lateSeconds) duration=\(input.durationSeconds)")
                    XCTAssertLessThan(input.lateSeconds, 0.15, "Late remote delivery invalidates the matched cadence.")
                    XCTAssertLessThan(input.durationSeconds, phase.presses.interval, "Remote delivery overran its slot.")
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

    private func traversalSnapshot(in app: XCUIApplication) throws -> LibraryTraversalSnapshot {
        let probe = app.descendants(matching: .any)
            .matching(identifier: "library-traversal-diagnostics").firstMatch
        let value = try XCTUnwrap(
            probe.value as? String,
            "Launch the app with PLOZZ_LIBRARY_TRAVERSAL_RECORDING=1; input timing alone is not movement evidence."
        )
        return try JSONDecoder().decode(LibraryTraversalSnapshot.self, from: Data(value.utf8))
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
