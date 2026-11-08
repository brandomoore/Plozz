import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class CardPerformanceTests: XCTestCase {
    func testPerformanceIdle() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        try await PerformanceProbe.measure(self, scenario: "cards-idle") {
            let before = fixture.probe.cardInputs
            try await Task.sleep(for: .milliseconds(500))
            let builds = fixture.probe.cardInputs - before
            XCTAssertEqual(builds, 0, "Settled rows must not rebuild their card inputs without a change.")
            return ["cardInputBuilds": builds]
        }
    }

    func testPerformanceScroll() async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        try await PerformanceProbe.measure(self, scenario: "cards-scroll") {
            let bottom = fixture.scroll.contentSize.height - fixture.scroll.bounds.height
            XCTAssertGreaterThan(bottom, 0)
            for index in 0..<12 {
                let y = bottom * CGFloat(index % 6) / 5
                fixture.scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                fixture.scroll.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertEqual(fixture.scroll.contentOffset.y, y, accuracy: 1)
            }
            return ["scrolls": 12]
        }
    }

    func testPerformanceLifecycle() async throws {
        try await measureLifecycle(scenario: "cards-lifecycle", cycles: 3)
    }

    func testPerformanceLifecycleSoak() async throws {
        try await measureLifecycle(scenario: "cards-lifecycle-soak", cycles: 30)
    }

    private func measureLifecycle(scenario: String, cycles: Int) async throws {
        try PerformanceProbe.requireEnabled()
        let fixture = try await Fixture()
        defer { fixture.close() }
        try await PerformanceProbe.measure(self, scenario: scenario) {
            for _ in 0..<cycles {
                try await fixture.mount()
                weak var host = fixture.host
                weak var view = fixture.host?.view
                fixture.unmount()
                try await Self.waitUntil { host == nil && view == nil }
                XCTAssertNil(host)
                XCTAssertNil(view)
            }
            return ["cycles": cycles, "survivingHosts": 0]
        }
        try await PerformanceProbe.attachMemoryAfterOneSecond(self, scenario: scenario)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Hosted performance fixture did not reach its required state.")
    }

    @MainActor
    private final class Probe {
        var cardInputs = 0
    }

    private struct Rows: View {
        let probe: Probe
        let items: [[MediaItem]]
        var body: some View {
            VStack(spacing: 30) {
                ForEach(items.indices, id: \.self) { row in
                    MediaRowView(
                        title: Text(verbatim: "Fixture \(row)"), items: items[row],
                        style: .landscape, artworkPolicy: .extra,
                        statusCue: { _ in probe.cardInputs += 1; return nil },
                        onSelect: { _ in }
                    )
                    .frame(height: 300)
                }
            }
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.locale, Locale(identifier: "en_US"))
        }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?
        let container = UIViewController()
        let scroll = UIScrollView()
        let probe = Probe()
        let items: [[MediaItem]]
        let folder: URL
        var host: UIHostingController<Rows>?

        init() async throws {
            XCTAssertTrue(Thread.isMainThread)
            try await CardPerformanceTests.waitUntil {
                UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .dark
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("poster.png")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            }
            try XCTUnwrap(image.pngData()).write(to: url)
            items = (0..<8).map { row in
                (0..<20).map { index in
                    MediaItem(id: "row-\(row)-\(index)", title: "Fixture \(row)-\(index)",
                              kind: .movie, posterURL: url, backdropURL: url)
                }
            }
            window.rootViewController = container
            scroll.frame = window.bounds
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.view.addSubview(scroll)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func mount() async throws {
            XCTAssertNil(host)
            let controller = UIHostingController(rootView: Rows(probe: probe, items: items))
            host = controller
            container.addChild(controller)
            scroll.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: 8 * 330)
            scroll.contentSize = controller.view.bounds.size
            controller.didMove(toParent: container)
            window.layoutIfNeeded()
            try await CardPerformanceTests.waitUntil { self.probe.cardInputs > 0 && controller.view.window != nil }
            // Settle async artwork and focus before measuring the warm workload.
            try await Task.sleep(for: .milliseconds(500))
        }

        func unmount() {
            host?.willMove(toParent: nil)
            host?.view.removeFromSuperview()
            host?.removeFromParent()
            host = nil
        }

        func close() {
            unmount()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            do { try FileManager.default.removeItem(at: folder) }
            catch { XCTFail("Could not remove owned performance artwork: \(error)") }
        }
    }
}
