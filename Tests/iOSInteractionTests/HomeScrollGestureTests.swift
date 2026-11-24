import UIKit
import XCTest

@MainActor
final class HomeScrollGestureTests: XCTestCase {
    func testDenseHomeScrollAndDeceleration() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--dense-home-scroll", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let inspect = app.buttons["dense-inspect"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 90))
        func snapshot() -> [String: Int] { self.snapshot(inspect) }

        var ready = snapshot()
        let deadline = Date().addingTimeInterval(60)
        while (ready["rows"] != 40 || ready["loading"] != 0) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            ready = snapshot()
        }
        XCTAssertEqual(ready["rows"], 40, "\(ready)")
        XCTAssertEqual(ready["total"], 40)
        XCTAssertEqual(ready["loading"], 0)
        let width = try XCTUnwrap(ready["width"])
        let height = try XCTUnwrap(ready["height"])
        let screenWidth = try XCTUnwrap(ready["screen"])
        let isPad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad")
            ?? (UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertEqual(ready["pad"], isPad ? 1 : 0)
        XCTAssertEqual(ready["regular"], isPad ? 1 : 0)
        XCTAssertEqual(Double(width), Double(screenWidth), accuracy: 1, "Measure the whole native window")
        if isPad { XCTAssertGreaterThanOrEqual(width, 740, "Never count a compact host as an iPad pass") }
        let contentHeight = try XCTUnwrap(ready["content"])
        XCTAssertGreaterThan(contentHeight, 5 * height)
        let top = app.buttons["dense-top"]
        let viewport = app.frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let dragPoints = Int(viewport.height * 0.40)
        let metric = XCTOSSignpostMetric.scrollingAndDecelerationMetric
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]

        var pass = 0
        measure(metrics: [metric], options: options) {
            // Repeat from the same shelf in the same process, including XCTest's discarded warm-up.
            top.tap()
            let before = snapshot()
            XCTAssertEqual(before["y"], 0)
            XCTAssertEqual(before["moving"], 0)
            if pass == 0 { self.checkPaintedPosters(app, name: "before") }
            startMeasuring()
            start.press(forDuration: 0.03, thenDragTo: end, withVelocity: 2500, thenHoldForDuration: 0)
            // The signpost, not this wait, delimits UIKit's dragging + deceleration.
            // Don't inspect frames, AX elements, offsets, or screenshots while UIKit is scrolling.
            Thread.sleep(forTimeInterval: 3)
            stopMeasuring()
            let after = snapshot()
            let evidence = XCTAttachment(string: "before: \(before)\nafter: \(after)\nfinger travel: \(dragPoints) pt")
            evidence.name = "scroll-pass-\(pass)"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertEqual(after["moving"], 0, "The scroll must finish within the sampled window")
            XCTAssertGreaterThan(after["y"] ?? -1, dragPoints + 20, "Content must coast past the finger's travel")
            XCTAssertEqual(after["rows"], 40)
            XCTAssertEqual(after["total"], 40)
            XCTAssertEqual(after["content"], before["content"])
            self.checkPaintedPosters(app, name: "after-\(pass)")
            pass += 1
        }
    }

    func testColdGestureDuringShelfPublication() throws {
        try measureDuringPublication(calibrate: false)
    }

    func testGestureHitchPositiveControl() throws {
        try measureDuringPublication(calibrate: true)
    }

    /// One fresh normal process. Six alternating startup swipes; the final pair follows
    /// the identical path after delivery completes. All eight have endpoint/clock evidence,
    /// though XCTest discards the first signpost sample as its warm-up.
    func testMinuteHeroProgressiveAndSettledSwipes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--dense-home-scroll", "--minute-hero", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        func now() -> Int { Int(Date().timeIntervalSince1970 * 1_000) }
        let launchMs = now()
        app.launch()
        defer { app.terminate() }
        let inspect = app.buttons["dense-inspect"], hero = app.buttons["home-hero-artwork-detail"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 25))
        XCTAssertEqual(hero.value as? String, "Striped Horizon")
        XCTAssertTrue(hero.isHittable)
        let usableMs = now(), heroFrame = hero.frame
        self.checkMinuteHero(app)
        let paintedMs = now()
        var first = snapshot(inspect)
        let deadline = Date().addingTimeInterval(10)
        while (first["rows"] ?? 0) < 4 && Date() < deadline { first = snapshot(inspect) }
        let origin = try XCTUnwrap(first["originMs"])
        let pad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad")
            ?? (UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertEqual(first["y"], 0)
        XCTAssertEqual(first["moving"], 0)
        XCTAssertEqual(first["pad"], pad ? 1 : 0)
        XCTAssertEqual(first["regular"], pad ? 1 : 0)
        XCTAssertEqual(first["width"], first["screen"])
        if pad { XCTAssertGreaterThanOrEqual(first["width"] ?? 0, 740) }
        XCTAssertGreaterThanOrEqual(first["rows"] ?? 0, 4)
        XCTAssertLessThan(first["rows"] ?? 40, 40)
        XCTAssertEqual(first["pan"], 0)
        let launch = XCTAttachment(string: """
        launchRequestMs: \(launchMs)
        usableHeroObservedMs: \(usableMs)
        paintedHeroObservedMs: \(paintedMs)
        scheduleOriginMs: \(origin)
        heroFrame: \(heroFrame), viewport: \(app.frame)
        first-shelves: \(first)
        """)
        launch.name = "minute-launch"; launch.lifetime = .keepAlways; add(launch)

        let lower = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.74))
        let upper = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.40))
        let finger = Int(app.frame.height * 0.34)
        let options = XCTMeasureOptions()
        options.iterationCount = 7
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        // Aim just before absolute release deadlines. The fixture never knows about
        // these targets. Only observed UIKit motion + completed publication count.
        let targetMs = [0, 10_400, 19_400, 28_400, 37_400, 49_400, 63_000, 71_000]
        var i = 0, overlaps = 0
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            let forward = i.isMultiple(of: 2), settled = i >= 6
            // Return paths can coast to a slightly different offset. Reset only between
            // pairs, outside the interval, to compare forward passes from the same origin.
            if forward && i > 0 { app.buttons["dense-top"].tap() }
            if i == 6 { Thread.sleep(forTimeInterval: max(0, Double(origin + 61_000 - now()) / 1_000)) }
            let before = self.snapshot(inspect)
            let a = XCTAttachment(screenshot: app.screenshot())
            a.name = "minute-before-\(i)"; a.lifetime = .keepAlways; self.add(a)
            if forward { XCTAssertEqual(before["y"], 0) }
            XCTAssertEqual(before["moving"], 0)
            if settled {
                for (field, n) in [("rows",40),("total",40),("shelves",40),("delivered",40),("items",800),
                                   ("distinctItems",800),("posters",800),("layouts",20),("latest",20),
                                   ("history",20),("libraries",20),("loading",0)] {
                    XCTAssertEqual(before[field], n, "\(field): \(before)")
                }
                XCTAssertGreaterThanOrEqual(before["lastDeliveryMs"] ?? 0, 55_990)
                XCTAssertLessThan(before["lastDeliveryMs"] ?? Int.max, 61_000)
                XCTAssertGreaterThan(before["idleRows"] ?? 0, 0, "Home must also publish after motion stops")
            }
            Thread.sleep(forTimeInterval: max(0, Double(origin + targetMs[i] - now()) / 1_000))
            let commandMs = now()
            self.startMeasuring()
            (forward ? lower : upper).press(forDuration: 0.03, thenDragTo: forward ? upper : lower,
                                            withVelocity: 1_650, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 3)
            self.stopMeasuring()
            let after = self.snapshot(inspect)
            let b = XCTAttachment(screenshot: app.screenshot())
            b.name = "minute-after-\(i)"; b.lifetime = .keepAlways; self.add(b)
            let evidence = XCTAttachment(string: """
            before: \(before)
            after: \(after)
            launchRequestMs: \(launchMs)
            commandMs: \(commandMs)
            direction: \(forward ? "forward" : "reverse"), finger: \(finger)
            """)
            evidence.name = "minute-pass-\(i)"; evidence.lifetime = .keepAlways; self.add(evidence)
            XCTAssertEqual(after["pan"], i + 1)
            XCTAssertGreaterThanOrEqual(after["panMs"] ?? 0, commandMs)
            XCTAssertEqual(after["moving"], 0)
            let dy = (after["y"] ?? 0) - (before["y"] ?? 0)
            XCTAssertGreaterThan(forward ? dy : -dy, finger + 20, "No verified deceleration on pass \(i)")
            if i == 0 { self.checkPaintedPosters(app, name: "minute-first-shelves-painted") }
            if settled {
                XCTAssertEqual(after["rowsInMotion"], 0)
                XCTAssertEqual(after["artInMotion"], 0)
            } else {
                let overlap = (after["rowsInMotion"] ?? 0) > 0 && (after["artInMotion"] ?? 0) >= 20
                if overlap { overlaps += 1 }
            }
            i += 1
        }
        XCTAssertEqual(i, 8)
        XCTAssertGreaterThanOrEqual(overlaps, 2, "Require multiple independent in-motion row AND artwork deliveries")
    }

    private func checkMinuteHero(_ app: XCUIApplication) {
        let shot = app.screenshot(), w = 96, h = 144
        let a = XCTAttachment(screenshot: shot)
        a.name = "minute-painted-hero"; a.lifetime = .keepAlways; add(a)
        guard let image = shot.image.cgImage else { return XCTFail("No hero screenshot") }
        var rgba = [UInt8](repeating: 0, count: w*h*4)
        let matches = rgba.withUnsafeMutableBytes { raw -> Int in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // A signed magenta/cyan transition repeated across a scan line distinguishes
            // this specific painted backdrop from labels, skeletons or the shelf bands.
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0..<h).filter { row in
                var previous = 0, changes = 0
                for x in 0..<w {
                    let p = (row*w+x)*4
                    let r = Int(bytes[p]), g = Int(bytes[p+1]), b = Int(bytes[p+2])
                    let color = r-g > 48 && b-g > 40 ? 1 : (g-r > 48 && b-r > 48 ? -1 : 0)
                    if color != 0 {
                        if previous != 0 && previous != color { changes += 1 }
                        previous = color
                    }
                }
                return changes >= 4
            }.count
        }
        XCTAssertGreaterThan(matches, 8, "Shipping hero did not paint the local striped backdrop")
    }

    private func snapshot(_ inspect: XCUIElement) -> [String: Int] {
        inspect.tap()
        let report = inspect.value as? String ?? ""
        return Dictionary(uniqueKeysWithValues: report.split(separator: " ").compactMap { field -> (String, Int)? in
            let parts = field.split(separator: "=")
            guard parts.count == 2, let value = Int(parts[1]) else { return nil }
            return (String(parts[0]), value)
        })
    }

    private func measureDuringPublication(calibrate: Bool) throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Application hitch calibration requires iOS 26") }
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--dense-home-scroll", "--during-publication", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if calibrate { app.launchArguments.append("--calibrate-hitch") }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var processes: Set<Int> = []
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTHitchMetric(application: app)], options: options) {
            // Fresh process, Home model and decoded-image cache for EVERY traversal, including XCTest's warm-up.
            app.launch()
            defer { app.terminate() }
            let inspect = app.buttons["dense-inspect"]
            XCTAssertTrue(inspect.waitForExistence(timeout: 90))
            var before = self.snapshot(inspect)
            let deadline = Date().addingTimeInterval(30)
            while before["rows"] != 4 && Date() < deadline { before = self.snapshot(inspect) }
            XCTAssertEqual(before["rows"], 4, "\(before)")
            XCTAssertEqual(before["total"], 40)
            XCTAssertEqual(before["loading"], 1)
            XCTAssertEqual(before["moving"], 0)
            XCTAssertEqual(before["y"], 0)
            XCTAssertTrue(processes.insert(before["pid"] ?? -1).inserted)
            let pad = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad")
                ?? (UIDevice.current.userInterfaceIdiom == .pad)
            XCTAssertEqual(before["pad"], pad ? 1 : 0)
            XCTAssertEqual(before["regular"], pad ? 1 : 0)
            XCTAssertEqual(before["width"], before["screen"])
            if pad { XCTAssertGreaterThanOrEqual(before["width"] ?? 0, 740) }
            let finger = Int(app.frame.height * 0.4)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            let firstFour = before
            self.checkPaintedPosters(app, name: "cold-before-\(processes.count)")
            // A model publication can precede layout (including removal of confirmed-empty global rows).
            // Keep the first observation as evidence; sample the rendered extent after the screenshot.
            before = self.snapshot(inspect)
            XCTAssertEqual(before["rows"], 4)
            XCTAssertEqual(before["loading"], 1)
            startMeasuring()
            start.press(forDuration: 0.03, thenDragTo: end, withVelocity: 2500, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 3)
            stopMeasuring()
            let after = self.snapshot(inspect)
            var final = after
            let finish = Date().addingTimeInterval(30)
            while final["loading"] != 0 && Date() < finish { final = self.snapshot(inspect) }
            let evidence = XCTAttachment(string: "before: \(before)\nafter: \(after)\nfinal: \(final)\nfinger travel: \(finger) pt\nfirst-four model/extent: \(firstFour)")
            evidence.name = "cold-pass-\(processes.count)"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertEqual(after["moving"], 0)
            XCTAssertGreaterThan(after["y"] ?? -1, finger + 20)
            XCTAssertGreaterThan(after["gains"] ?? 0, 0, "Home must publish additional complete rows during native motion")
            XCTAssertGreaterThan(after["updates"] ?? 0, 0)
            XCTAssertEqual(after["stall"], calibrate ? 1 : 0, "Calibrate only with a stall inside native motion")
            for h in [after["panHeight"], after["minHeight"], after["maxHeight"], after["content"], final["content"]] {
                XCTAssertEqual(h, before["content"], "Keep the document's vertical extent across row publication")
            }
            XCTAssertEqual(final["rows"], 40)
            XCTAssertEqual(final["total"], 40)
            XCTAssertEqual(final["shelves"], 40)
            XCTAssertEqual(final["distinct"], 40)
            for kind in ["libraries", "latest", "history"] { XCTAssertEqual(final[kind], 20, kind) }
            self.checkPaintedPosters(app, name: "cold-after-\(processes.count)")
        }
    }

    /// Validate the shipping poster images, not merely the existence of image views (or a loading skeleton).
    private func checkPaintedPosters(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let image = shot.image.cgImage else { return XCTFail("Missing screenshot") }
        let w = 128, h = 192
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let painted = pixels.withUnsafeMutableBytes { raw -> Int in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: p.count, by: 4).reduce(0) { count, i in
                count + (p[i] > 210 && (55...125).contains(p[i + 1]) && p[i + 2] < 55 ? 1 : 0)
            }
        }
        XCTAssertGreaterThan(painted, w * h / 200, "No recognizable poster bands in \(name)")
    }
}
