import XCTest
#if canImport(notify)
import notify
#endif

/// Warm-only, unbound runner: never launches, activates, terminates, or installs Plozz.
/// Existing Home has no row accessibility IDs. Recognize section text followed by
/// a leaf horizontal scroll view containing enabled media buttons, not skeletons.
/// Hero-off coverage starts at the currently focused real row and visits at most two
/// available neighboring media rows.
@MainActor
final class PhysicalHomeRowsFirstTests: XCTestCase {
    private static var positionedSweep = false
    private let heroID = "home-hero-action-row"
    private var started: TimeInterval = 0
    private var confirmed: TimeInterval = 0
    private var events: [String] = []
    private var inputBudget: TimeInterval = 100

    func testRowMatchingDistinguishesSharedLeadingTitles() {
        func row(_ labels: [String]) -> Row {
            Row(title: "Recently Added", cards: labels.map {
                Card(label: $0, frame: .zero, focused: false)
            })
        }
        let first = row(["Shared", "First", "Second"])
        let second = row(["Shared", "Third", "Fourth"])
        let scene = Scene(frame: .zero, heroPresent: false, heroFocused: false,
                          railFocused: false, rows: [first, second])
        XCTAssertEqual(matchingRows(first, in: scene).first?.cards.map(\.label), first.cards.map(\.label))
        XCTAssertEqual(matchingRows(first, in: scene).count, 1)
        XCTAssertEqual(matchingRows(second, in: scene).first?.cards.map(\.label), second.cards.map(\.label))
        XCTAssertEqual(matchingRows(row(["Shared", "Missing"]), in: scene).count, 0)
        let ambiguous = Scene(frame: .zero, heroPresent: false, heroFocused: false,
                              railFocused: false, rows: [first, first])
        XCTAssertEqual(matchingRows(first, in: ambiguous).count, 2)
    }

    func testHeroDisabledFocusedRowAndAvailableLowerRowsWarm() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_HOME_HERO_OFF"] == "1",
            "Requires explicit hero-off scenario opt-in; this test never changes the setting."
        )
        try runRows()
    }

    func testHeroDisabledVerticalRowsWarm() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["PLOZZ_HOME_VERTICAL_ONLY"] == "1" && environment["PLOZZ_HOME_HERO_OFF"] == "1",
            "Requires explicit hero-off vertical-only opt-in; no horizontal input or setting changes."
        )
        try runRows(verticalOnly: true)
    }

    func testHeroDisabledHorizontalRowWarm() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["PLOZZ_HOME_HORIZONTAL_ONLY"] == "1" && environment["PLOZZ_HOME_HERO_OFF"] == "1",
            "Requires explicit hero-off horizontal-only opt-in."
        )
        try runRows(horizontalOnly: true)
    }

    func testHeroDisabledRowSweepWarm() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            ["down", "up"].contains(environment["PLOZZ_HOME_SWEEP_DIRECTION"] ?? "")
                && environment["PLOZZ_HOME_HERO_OFF"] == "1",
            "Requires explicit hero-off row-sweep opt-in."
        )
        try runRows(sweep: true)
    }

    func testHeroDisabledNativeHitchMetricWarm() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            ["right", "left", "down", "up"].contains(environment["PLOZZ_HOME_MEASURE_DIRECTION"] ?? "")
                && environment["PLOZZ_HOME_HERO_OFF"] == "1",
            "Requires an explicit native hitch measurement direction."
        )
        try runRows(nativeMetric: true)
    }

    private func runRows(
        verticalOnly: Bool = false, horizontalOnly: Bool = false,
        sweep: Bool = false, nativeMetric: Bool = false
    ) throws {
        #if !os(tvOS) || targetEnvironment(simulator)
        throw XCTSkip("Physical tvOS only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["PLOZZ_HOME_TARGET_DEVICE"]?.isEmpty == false
                && environment["PLOZZ_HOME_ROWS_FIRST"] == environment["PLOZZ_HOME_TARGET_DEVICE"],
            "Requires explicit physical-device opt-in matching the driver's destination."
        )
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_HOME_APP_CONFIGURATION"] == "Release",
            "Parent must confirm the already-running Release app; this test does not launch it."
        )
        continueAfterFailure = false
        executionTimeAllowance = sweep || nativeMetric ? 150 : (verticalOnly || horizontalOnly ? 60 : 120)
        inputBudget = sweep || nativeMetric ? 130 : (verticalOnly || horizontalOnly ? 45 : 100)
        started = ProcessInfo.processInfo.systemUptime
        event("scenario hero=disabled verticalOnly=\(verticalOnly) lifecycle=warm-existing relaunch=false causalComparison=false")
        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            let attachment = XCTAttachment(string: self.events.joined(separator: "\n"))
            attachment.name = "warm-rows-first-timeline"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
        try waitForWarmConfirmation()
        let bundleID = environment["PLOZZ_HOME_APP_BUNDLE_ID"] ?? "com.thatcube.Plozz"
        guard ["com.thatcube.Plozz", "com.thatcube.Plozz.FocusHost"].contains(bundleID) else {
            try fail(.notReady, "Only Plozz or its explicit isolated Home fixture can be measured.")
        }
        event("application bundleID=\(bundleID) isolatedFixture=\(bundleID.hasSuffix(".FocusHost"))")
        let app = XCUIApplication(bundleIdentifier: bundleID)
        let continueWatchingTitle = ProcessInfo.processInfo.environment["PLOZZ_HOME_CONTINUE_WATCHING_LABEL"] ?? "Continue Watching"
        var ready = try waitForContent(app: app)
        if let requested = ProcessInfo.processInfo.environment["PLOZZ_HOME_START_ROW"],
           !requested.isEmpty, !sweep || !Self.positionedSweep {
            for _ in 0..<2 {
                if ready.focusedRow?.title == requested { break }
                let matches = ready.rows.indices.filter { ready.rows[$0].title == requested }
                guard matches.count == 1,
                      let current = ready.rows.firstIndex(where: { $0.focusedCard != nil }) else {
                    try fail(.notReady, "Requested starting row is not uniquely exposed; refusing blind navigation.")
                }
                let step = matches[0] < current ? -1 : 1
                let expected = ready.rows[current + step]
                event("preparation.target-row measured=false")
                try input(step < 0 ? .up : .down, phase: "preparation.target-row", app: app)
                ready = try observe(app, phase: "preparation.target-row.ready")
                try requireFocused(expected, in: ready)
            }
            guard ready.focusedRow?.title == requested else {
                try fail(.notReady, "Requested starting row was not reached within two preparation inputs.")
            }
            if sweep { Self.positionedSweep = true }
        }
        guard let focused = ready.focusedRow else {
            try fail(.notReady, "No populated media row/card currently focused; no automatic focus repair.")
        }
        let title = focused.title
        var scene = ready
        event("hero-off.row-ready title=\(title.debugDescription)")

        if nativeMetric {
            try measureNativeHitches(from: scene, app: app)
            return
        }
        if sweep {
            try sweepRows(from: scene, app: app)
            return
        }
        if verticalOnly {
            try runVerticalRows(from: scene, app: app)
            return
        }
        try requireFocused(title, in: scene)
        scene = try pageHorizontally(from: scene, app: app)
        if title == continueWatchingTitle { event("continue-watching.verified") }

        if horizontalOnly {
            event("horizontal-only.verified title=\(title.debugDescription)")
            event("complete")
            return
        }
        try runVerticalRows(from: scene, app: app)
        #endif
    }

    private func pageHorizontally(from initial: Scene, app: XCUIApplication) throws -> Scene {
        guard let current = initial.focusedRow else { try fail(.notReady, "No focused real row to page.") }
        let title = current.title
        var scene = initial
        guard current.cards.count >= 2 else {
            event("horizontal.not-applicable title=\(title.debugDescription) reason=single-exposed-card")
            return scene
        }
        do {
            event("first-row.input-window.begin title=\(title.debugDescription)")
            let initialCard = scene.rows.first(where: { $0.title == title })?.focusedCard
            try input(.right, duration: 3, phase: "first-row.right-hold", app: app)
            scene = try observe(app, phase: "first-row.after-right")
            try requireFocused(title, in: scene)
            let movedCard = scene.rows.first(where: { $0.title == title })?.focusedCard
            guard initialCard != movedCard else {
                try fail(.inputFailed, "Starting-row Right hold did not change the focused real card.")
            }
            event("first-row.movement.observed")
            try input(.left, duration: 3, phase: "first-row.left-hold", app: app)
            scene = try observe(app, phase: "first-row.after-left")
            if scene.focusedRow == nil, scene.railFocused {
                event("first-row.left-boundary.return")
                try input(.right, phase: "first-row.rail-recovery", app: app)
                scene = try observe(app, phase: "first-row.after-recovery")
            }
            try requireFocused(title, in: scene)
            event("first-row.input-window.end")
            event("first-row.horizontal.verified title=\(title.debugDescription)")
        }
        return scene
    }

    private func measureNativeHitches(from initial: Scene, app: XCUIApplication) throws {
        guard #available(tvOS 26.0, *) else { throw XCTSkip("Native hitch metrics require tvOS 26 or newer.") }
        let direction = ProcessInfo.processInfo.environment["PLOZZ_HOME_MEASURE_DIRECTION"]
        if direction == "down" || direction == "up" {
            try measureNativeVerticalHitches(from: initial, app: app, ascending: direction == "up")
            return
        }
        guard let title = initial.focusedRow?.title else { try fail(.notReady, "No row for native metrics.") }
        let measuresLeft = ProcessInfo.processInfo.environment["PLOZZ_HOME_MEASURE_DIRECTION"] == "left"
        let idleControl = ProcessInfo.processInfo.environment["PLOZZ_HOME_METRIC_IDLE_CONTROL"] == "1"
        var scene = initial
        var failure: Error?
        var iteration = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            iteration += 1
            do {
                if measuresLeft {
                    try self.input(.right, duration: 3, phase: "native.prepare-right", app: app)
                    scene = try self.observe(app, phase: "native.prepared")
                    try self.requireFocused(title, in: scene)
                }
                let before = scene.focusedRow?.focusedCard
                self.event("first-row.input-window.begin title=\(title.debugDescription)")
                self.event("native.metric.begin iteration=\(iteration) direction=\(measuresLeft ? "left" : "right") idleControl=\(idleControl)")
                self.startMeasuring()
                if idleControl { Thread.sleep(forTimeInterval: 3) }
                else if measuresLeft { XCUIRemote.shared.press(.left, forDuration: 3) }
                else { XCUIRemote.shared.press(.right, forDuration: 3) }
                self.stopMeasuring()
                self.event("native.metric.end iteration=\(iteration)")
                self.event("first-row.input-window.end")
                if idleControl {
                    try self.input(measuresLeft ? .left : .right, duration: 3, phase: "native.unmeasured-control-input", app: app)
                }
                scene = try self.observe(app, phase: "native.measured-focus")
                if scene.railFocused {
                    try self.input(.right, phase: "native.rail-return", app: app)
                    scene = try self.observe(app, phase: "native.rail-returned")
                }
                try self.requireFocused(title, in: scene)
                guard before != scene.focusedRow?.focusedCard else {
                    try self.fail(.inputFailed, "The measured hold did not change the actual focused card.")
                }
                if !measuresLeft {
                    try self.input(.left, duration: 3, phase: "native.reset-left", app: app)
                    scene = try self.observe(app, phase: "native.reset-focus")
                    if scene.railFocused {
                        try self.input(.right, phase: "native.reset-rail-return", app: app)
                        scene = try self.observe(app, phase: "native.reset-returned")
                    }
                    try self.requireFocused(title, in: scene)
                }
            } catch {
                failure = error
                XCTFail("Native hitch measurement could not complete verified input: \(error)")
            }
        }
        if let failure { throw failure }
        event("native.metric.verified title=\(title.debugDescription) direction=\(measuresLeft ? "left" : "right") idleControl=\(idleControl)")
        event("complete")
    }

    @available(tvOS 26.0, *)
    private func measureNativeVerticalHitches(
        from initial: Scene, app: XCUIApplication, ascending: Bool
    ) throws {
        guard let index = initial.rows.firstIndex(where: { $0.focusedCard != nil }),
              initial.rows.indices.contains(index + (ascending ? -1 : 1)) else {
            try fail(.notReady, "No observed neighboring row for the measured vertical transition.")
        }
        let source = initial.rows[index]
        let destination = initial.rows[index + (ascending ? -1 : 1)]
        guard matchingRows(source, in: initial).count == 1,
              matchingRows(destination, in: initial).count == 1 else {
            try fail(.notReady, "Vertical metric requires distinguishable source and destination rows.")
        }
        guard ProcessInfo.processInfo.environment["PLOZZ_HOME_METRIC_IDLE_CONTROL"] != "1" else {
            try fail(.notReady, "Idle control is supported only by horizontal metric workloads.")
        }
        var scene = initial
        var failure: Error?
        var iteration = 0
        let direction = ascending ? "up" : "down"
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            iteration += 1
            do {
                try self.requireFocused(source, in: scene)
                self.event("lower-rows.input-window.begin")
                self.event("native.metric.begin iteration=\(iteration) direction=\(direction) from=\(source.title.debugDescription) to=\(destination.title.debugDescription)")
                self.startMeasuring()
                XCUIRemote.shared.press(ascending ? .up : .down)
                self.stopMeasuring()
                self.event("native.metric.end iteration=\(iteration)")
                self.event("lower-rows.input-window.end")
                scene = try self.observe(app, phase: "native.measured-focus")
                try self.requireFocused(destination, in: scene)
                try self.input(ascending ? .down : .up, phase: "native.reset-vertical", app: app)
                scene = try self.observe(app, phase: "native.reset-focus")
                try self.requireFocused(source, in: scene)
            } catch {
                failure = error
                XCTFail("Native vertical hitch workload did not complete: \(error)")
            }
        }
        if let failure { throw failure }
        event("native.metric.verified title=\(source.title.debugDescription) destination=\(destination.title.debugDescription) direction=\(direction)")
        event("complete")
    }

    private func sweepRows(from initial: Scene, app: XCUIApplication) throws {
        let ascending = ProcessInfo.processInfo.environment["PLOZZ_HOME_SWEEP_DIRECTION"] == "up"
        let direction = ascending ? "up" : "down"
        let stopTitle = ProcessInfo.processInfo.environment["PLOZZ_HOME_SWEEP_STOP_ROW"] ?? ""
        var scene = initial
        var visited: [Row] = []
        var boundary = false
        for ordinal in 1...4 {
            guard let current = scene.focusedRow else { try fail(.inputFailed, "Sweep left the media rows.") }
            event("sweep.row.begin ordinal=\(ordinal) direction=\(direction) title=\(current.title.debugDescription)")
            scene = try pageHorizontally(from: scene, app: app)
            guard let finished = scene.focusedRow else { try fail(.inputFailed, "Paging lost row focus.") }
            visited.append(finished)
            event("sweep.row.verified ordinal=\(ordinal) title=\(finished.title.debugDescription)")
            if !stopTitle.isEmpty, finished.title == stopTitle {
                boundary = true
                event("sweep.requested-stop title=\(stopTitle.debugDescription)")
                break
            }
            guard let index = scene.rows.firstIndex(where: { $0.focusedCard != nil }) else {
                try fail(.inputFailed, "Focused row is absent from the snapshot.")
            }
            let neighborIndex = index + (ascending ? -1 : 1)
            let expected = scene.rows.indices.contains(neighborIndex) ? scene.rows[neighborIndex] : nil
            event("lower-rows.input-window.begin")
            try input(ascending ? .up : .down, phase: "sweep.\(direction)", app: app)
            scene = try observe(app, phase: "sweep.destination")
            event("lower-rows.input-window.end")
            if let expected {
                try requireFocused(expected, in: scene)
            } else if matchingRows(finished, in: scene).contains(where: { $0.focusedCard != nil }) {
                let blockedByLoading = scene.unavailableRows.contains {
                    ascending ? $0.midY < finished.frame.midY : $0.midY > finished.frame.midY
                }
                guard !blockedByLoading else {
                    try fail(.notReady, "An unpopulated row blocks the sweep; this is not the end of Home.")
                }
                boundary = true
                event("sweep.retained-boundary direction=\(direction) title=\(finished.title.debugDescription)")
                break
            } else {
                guard let next = scene.focusedRow, !next.title.isEmpty,
                      !visited.contains(where: { matchingRows($0, in: scene).contains(where: { $0.focusedCard != nil }) })
                else { try fail(.inputFailed, "Sweep moved to an unexpected control or previously visited row.") }
            }
            event("sweep.transition.verified direction=\(direction) title=\(scene.focusedRow?.title.debugDescription ?? "<none>")")
        }
        event("sweep.coverage rows=\(visited.count) direction=\(direction) boundary=\(boundary) exhaustive=false")
        event("complete")
    }

    private func waitForWarmConfirmation() throws {
        #if canImport(notify)
        let name = "com.thatcube.Plozz.HomeRowsWarm.\(UUID().uuidString).confirmed"
        let expectation = XCTestExpectation(description: "Parent confirms existing warm Home without relaunch")
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.confirmed == 0 else { return }
                self.confirmed = ProcessInfo.processInfo.systemUptime
                self.event("warm-home.confirmed")
                expectation.fulfill()
            }
        }
        guard status == UInt32(NOTIFY_STATUS_OK) else { try fail(.notReady, "Warm confirmation notification unavailable.") }
        defer { _ = notify_cancel(token) }
        event("warm-ready confirmedNotification=\(name) relaunch=false")
        guard XCTWaiter.wait(for: [expectation], timeout: 30) == .completed else {
            try fail(.notReady, "30-second warm Home confirmation timed out; no AUT queries or input attempted.")
        }
        #else
        try fail(.notReady, "Public notification module unavailable.")
        #endif
    }

    private func waitForContent(app: XCUIApplication) throws -> Scene {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var returnedFromSidebar = false
        repeat {
            let scene = try observe(app, phase: "readiness")
            if scene.heroPresent {
                try fail(.notReady, "Hero-off scenario still exposes a Home hero. No setting changes attempted; refusing mixed-state measurement.")
            }
            if let focused = scene.focusedRow,
               scene.rows.filter({ $0.focusedCard != nil }).count == 1,
               !focused.title.isEmpty, focused.cards.count >= 2,
               focused.cards.contains(where: { $0.frame.intersects(scene.frame) }) {
                return scene
            }
            if scene.railFocused, !returnedFromSidebar,
               scene.rows.contains(where: { $0.cards.count >= 2 }) {
                returnedFromSidebar = true
                event("readiness.sidebar-return measured=false")
                try input(.right, phase: "readiness.sidebar-return", app: app)
                continue
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while ProcessInfo.processInfo.systemUptime < deadline
        try fail(.notReady, "15-second readiness limit: expected a uniquely identified row with two enabled, labelled real media buttons and a visible focused card. Headings/skeletons do not qualify.")
    }

    private func observe(_ app: XCUIApplication, phase: String) throws -> Scene {
        event("\(phase) ax-check.begin")
        defer { event("\(phase) ax-check.returned") }
        let failure: Failure = phase == "readiness" ? .notReady : .inputFailed
        guard app.state == .runningForeground else { try fail(failure, "Plozz is not foreground; refusing to activate or relaunch.") }
        let root: XCUIElementSnapshot
        do {
            root = try app.snapshot()
        } catch {
            try fail(failure, "AX snapshot unavailable; this does not establish content readiness or app responsiveness: \(error)")
        }
        var rows: [Row] = []
        var unavailableRows: [CGRect] = []
        var latestHeading = ""

        func descendants(_ node: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
            node.children.flatMap { [$0] + descendants($0) }
        }
        func containsFocus(_ node: XCUIElementSnapshot) -> Bool {
            node.hasFocus || node.children.contains(where: containsFocus)
        }
        func mediaButtons(_ node: XCUIElementSnapshot) -> [Card] {
            if node.elementType == .button || node.elementType == .cell {
                guard node.isEnabled, node.identifier != heroID,
                      node.identifier != "episode-entry-placeholder",
                      node.frame.width > 0, node.frame.height > 0 else { return [] }
                let text = node.label.isEmpty
                    ? descendants(node).filter { $0.elementType == .staticText }.map(\.label).joined(separator: " ")
                    : node.label
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return [Card(label: text, frame: node.frame, focused: containsFocus(node))]
                }
            }
            return node.children.flatMap(mediaButtons)
        }
        func walk(_ node: XCUIElementSnapshot, insideButton: Bool = false) {
            if node.elementType == .staticText, !insideButton, !node.label.isEmpty {
                latestHeading = node.label
            }
            if node.elementType == .scrollView || node.elementType == .collectionView,
               node.frame.width > root.frame.width * 0.45,
               node.frame.height < root.frame.height * 0.85 {
                let contents = descendants(node)
                if !contents.contains(where: {
                    $0.elementType == .scrollView || $0.elementType == .collectionView
                }) {
                    let cards = mediaButtons(node)
                    if !cards.isEmpty {
                        rows.append(Row(title: latestHeading, cards: cards,
                                        isCollection: node.elementType == .collectionView, frame: node.frame))
                    } else {
                        unavailableRows.append(node.frame)
                        event("\(phase) unavailableRow title=\(latestHeading.debugDescription) type=\(node.elementType.rawValue) frame=\(node.frame)")
                    }
                    return
                }
            }
            for child in node.children {
                walk(child, insideButton: insideButton || node.elementType == .button)
            }
        }
        walk(root)
        let elements = descendants(root)
        let heroPresent = elements.contains { $0.identifier == heroID }
        let heroFocused = elements.contains { $0.identifier == heroID && $0.hasFocus }
        let focusedControl = elements.first { $0.elementType == .button && containsFocus($0) }
        let homeLabel = ProcessInfo.processInfo.environment["PLOZZ_HOME_NAVIGATION_LABEL"] ?? "Home"
        let sidebarLabels: Set<String> = [homeLabel, "Search", "Watchlist", "Live TV", "Music", "Settings"]
        let sidebarButtons = elements.filter {
            $0.elementType == .button && sidebarLabels.contains($0.label)
                && $0.frame.minX < root.frame.width * 0.10
                && $0.frame.maxX < root.frame.width * 0.25
                && $0.frame.width > $0.frame.height * 2
        }
        let railFocused = focusedControl.map {
            ($0.identifier == "pinned-sidebar-page-button" || $0.label == homeLabel)
                && $0.frame.midX < root.frame.width * 0.25
        } == true || (Set(sidebarButtons.map(\.label)).count >= 3
                     && sidebarButtons.contains(where: containsFocus))
        let focusedRow = rows.first { $0.focusedCard != nil }
        event("\(phase) realMediaRows=\(rows.count) focusedRows=\(rows.filter { $0.focusedCard != nil }.count) heroPresent=\(heroPresent) railFocused=\(railFocused) focusRow=\(focusedRow?.title.debugDescription ?? "<none>") focusCard=\(focusedRow?.focusedCard?.label.debugDescription ?? "<none>")")
        if focusedRow == nil {
            for element in elements.filter(\.hasFocus).prefix(8) {
                event("\(phase) focusedElement type=\(element.elementType.rawValue) identifier=\(element.identifier.debugDescription) label=\(element.label.debugDescription) frame=\(element.frame)")
            }
        }
        for (index, row) in rows.enumerated() {
            event("\(phase) row=\(index) title=\(row.title.debugDescription) cards=\(row.cards.count) firstCards=\(row.cards.prefix(3).map(\.label)) focused=\(row.focusedCard != nil) nativeCollection=\(row.isCollection)")
        }
        return Scene(frame: root.frame, heroPresent: heroPresent, heroFocused: heroFocused,
                     railFocused: railFocused, rows: rows,
                     hasNativeFocus: elements.contains(where: { $0.hasFocus }), unavailableRows: unavailableRows)
    }

    private func requireFocused(_ title: String, in scene: Scene) throws {
        guard scene.rows.filter({ $0.focusedCard != nil }).count == 1,
              scene.focusedRow?.title == title else {
            try fail(.inputFailed, "Input did not focus the expected populated row \(title.debugDescription).")
        }
    }

    private func runVerticalRows(from initial: Scene, app: XCUIApplication) throws {
        guard let startingRow = initial.focusedRow else {
            try fail(.notReady, "No real starting row is focused.")
        }
        var scene = initial
        var route = [startingRow]
        guard let initialIndex = scene.rows.firstIndex(where: { $0.focusedCard != nil }) else {
            try fail(.notReady, "Starting row is not in the observed media rows.")
        }
        let nextIndex = initialIndex + 1
        let canStartDown = nextIndex < scene.rows.count
            && !scene.rows[nextIndex].title.isEmpty
            && matchingRows(scene.rows[nextIndex], in: scene).count == 1
        let step = canStartDown ? 1 : -1
        let outward: XCUIRemote.Button = canStartDown ? .down : .up
        let returning: XCUIRemote.Button = canStartDown ? .up : .down
        event("vertical-only.start-row.ready title=\(startingRow.title.debugDescription)")
        event("vertical-only.direction outward=\(canStartDown ? "down" : "up")")
        event("lower-rows.input-window.begin")
        for ordinal in 1...2 {
            guard let index = scene.rows.firstIndex(where: { $0.focusedCard != nil }),
                  scene.rows.indices.contains(index + step) else {
                event("lower-rows.not-ready-or-not-exposed visited=\(route.count - 1)")
                break
            }
            let expected = scene.rows[index + step]
            guard !expected.title.isEmpty, matchingRows(expected, in: scene).count == 1 else {
                try fail(.notReady, "Next row cannot be distinguished by its heading and actual media cards.")
            }
            try input(outward, phase: "vertical-row-\(ordinal).\(canStartDown ? "down" : "up")", app: app)
            scene = try observe(app, phase: "lower-row-\(ordinal).entered")
            try requireFocused(expected, in: scene)
            route.append(expected)
            event("lower-row.verified ordinal=\(ordinal) direction=\(canStartDown ? "down" : "up") title=\(expected.title.debugDescription)")
        }
        for expected in route.dropLast().reversed() {
            try input(returning, phase: "vertical-row.return", app: app)
            scene = try observe(app, phase: "lower-row.returned")
            try requireFocused(expected, in: scene)
        }
        var visitedCount = route.count - 1
        if visitedCount == 1,
           let index = scene.rows.firstIndex(where: { $0.focusedCard != nil }),
           scene.rows.indices.contains(index - step) {
            let expected = scene.rows[index - step]
            guard !expected.title.isEmpty, matchingRows(expected, in: scene).count == 1 else {
                try fail(.notReady, "Opposite neighboring row is ambiguous.")
            }
            try input(returning, phase: "vertical-opposite.enter", app: app)
            scene = try observe(app, phase: "vertical-opposite.entered")
            try requireFocused(expected, in: scene)
            visitedCount += 1
            event("lower-row.verified ordinal=2 direction=\(canStartDown ? "up" : "down") title=\(expected.title.debugDescription)")
            try input(outward, phase: "vertical-opposite.return", app: app)
            scene = try observe(app, phase: "vertical-opposite.returned")
        }
        try requireFocused(startingRow, in: scene)
        event("lower-rows.input-window.end")
        event("hero-off.starting-row.restored")
        event("coverage startingRow=\(startingRow.title.debugDescription) visitedOtherRows=\(visitedCount) exhaustive=false")
        guard visitedCount == 2 else {
            try fail(.notReady, "Returned to starting row, but two other populated rows were not exposed.")
        }
        event("vertical-only.verified down=2 up=2")
        event("complete")
    }

    private func matchingRows(_ expected: Row, in scene: Scene) -> [Row] {
        // Different libraries can use the same section heading.
        let labels = Set(expected.cards.map(\.label))
        let candidates = scene.rows.filter { $0.title == expected.title }.map {
            (row: $0, sharedLabels: labels.intersection($0.cards.map(\.label)).count)
        }
        guard let strongest = candidates.map(\.sharedLabels).max(),
              strongest >= min(2, labels.count), strongest > 0 else { return [] }
        return candidates.filter { $0.sharedLabels == strongest }.map(\.row)
    }

    private func requireFocused(_ expected: Row, in scene: Scene) throws {
        let matches = matchingRows(expected, in: scene)
        guard scene.rows.filter({ $0.focusedCard != nil }).count == 1,
              matches.count == 1, matches[0].focusedCard != nil else {
            try fail(.inputFailed, "Expected uniquely matched media row \(expected.title.debugDescription) was not focused.")
        }
    }

    private func input(_ button: XCUIRemote.Button, duration: TimeInterval? = nil, phase: String, app: XCUIApplication) throws {
        guard ProcessInfo.processInfo.systemUptime - started < inputBudget else {
            try fail(.budgetExceeded, "\(Int(inputBudget))-second input budget exhausted; refusing more commands.")
        }
        guard app.state == .runningForeground else { try fail(.inputFailed, "Plozz left foreground before input.") }
        event("\(phase) requestedHold=\(duration ?? 0) begin")
        if let duration {
            XCUIRemote.shared.press(button, forDuration: duration)
        } else {
            XCUIRemote.shared.press(button)
        }
        event("\(phase) returned")
    }

    private func event(_ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let confirmedElapsed: Double = confirmed > 0 ? now - confirmed : -1.0
        let text = String(
            format: "PLZROWS wall=%.3f uptime=%.3f confirmedElapsed=%.3f origin=warm-confirmation %@",
            Date().timeIntervalSince1970, now, confirmedElapsed, phase
        )
        events.append(text)
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }

    private func fail(_ failure: Failure, _ message: String) throws -> Never {
        event("failure kind=\(failure.rawValue) \(message)")
        XCTFail("\(failure.rawValue): \(message)")
        throw failure
    }

    private struct Card: Equatable {
        let label: String
        let frame: CGRect
        let focused: Bool
    }
    private struct Row {
        let title: String
        let cards: [Card]
        var isCollection = false
        var frame = CGRect.zero
        var focusedCard: Card? { cards.first(where: \.focused) }
    }
    private struct Scene {
        let frame: CGRect
        let heroPresent: Bool
        let heroFocused: Bool
        let railFocused: Bool
        let rows: [Row]
        var hasNativeFocus = false
        var unavailableRows: [CGRect] = []
        var focusedRow: Row? { rows.first { $0.focusedCard != nil } }
    }
    private enum Failure: String, Error {
        case notReady = "NOT_READY"
        case inputFailed = "INPUT_FAILED"
        case budgetExceeded = "BUDGET_EXCEEDED"
    }
}
