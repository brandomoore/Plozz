import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ShimmerPerformanceTests: XCTestCase {
    func testPerformanceLoadingCards() async throws {
        try await measure(disableAnimations: false, scenario: "skeletons-idle")
    }

    func testPerformanceStaticCards() async throws {
        try await measure(disableAnimations: true, scenario: "skeletons-static")
    }

    func testInactiveShimmerRemainsStatic() async throws {
        let fixture = try await Fixture(
            content: RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray)
                .frame(width: 200, height: 300)
                .shimmering(active: false)
        )
        defer { fixture.close() }
        let first = try fixture.snapshot()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(try fixture.snapshot(), first)
    }

    func testEnvironmentPausesAndRestartsShimmer() async throws {
        let state = ShimmerState()
        let fixture = try await Fixture(content: ControlledShimmer(state: state))
        defer { fixture.close() }
        for _ in 0..<2 {
            let paused = try fixture.snapshot()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(try fixture.snapshot(), paused)
            state.enabled = true
            try await Task.sleep(for: .milliseconds(100))
            let first = try fixture.snapshot()
            var changed = false
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(300))
                let next = try fixture.snapshot()
                changed = changed || first != next
            }
            XCTAssertTrue(changed, "Visible placeholders must resume their loading animation.")
            state.enabled = false
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func testVisibilityDoesNotChangeReduceMotionAppearance() async throws {
        let state = ShimmerState()
        state.reduceMotion = true
        let fixture = try await Fixture(content: ControlledShimmer(state: state))
        defer { fixture.close() }
        let paused = try fixture.snapshot()
        state.enabled = true
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(try fixture.snapshot(), paused)
    }

    @MainActor @Observable
    final class ShimmerState {
        var enabled = false
        var reduceMotion = false
    }

    private struct ControlledShimmer: View {
        let state: ShimmerState

        var body: some View {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray)
                .frame(width: 200, height: 300)
                .shimmering()
                .environment(\.plozzShimmerEnabled, state.enabled)
                .environment(\._accessibilityReduceMotion, state.reduceMotion)
        }
    }

    private func measure(disableAnimations: Bool, scenario: String) async throws {
        try PerformanceProbe.requireEnabled()
        let probe = Probe()
        let fixture = try await Fixture(
            content: Cards(probe: probe)
                .transaction { $0.disablesAnimations = disableAnimations }
        )
        defer { fixture.close() }
        XCTAssertEqual(probe.appeared.count, 24)
        let first = try fixture.snapshot(attachment: "\(scenario)-first")
        var changed = false
        for index in 0..<6 {
            try await Task.sleep(for: .milliseconds(350))
            let next = try fixture.snapshot(attachment: index == 2 ? "\(scenario)-mid" : nil)
            changed = changed || first != next
        }
        XCTAssertEqual(changed, !disableAnimations, "Visible motion must survive optimization; the static control must stay still.")
        try await PerformanceProbe.measure(self, scenario: scenario) {
            XCTAssertNotNil(fixture.window.rootViewController?.view.window)
            try await Task.sleep(for: .milliseconds(2300))
            return ["placeholders": probe.appeared.count, "observationMilliseconds": 2300]
        }
    }

    @MainActor
    private final class Probe {
        var appeared: Set<Int> = []
    }

    private struct Cards: View {
        let probe: Probe

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(0..<3) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<8) { column in
                            SkeletonCardView(style: .poster, showsCaption: true)
                                .frame(width: 130)
                                .onAppear { probe.appeared.insert(row * 8 + column) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.themePalette, .dark)
        }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let previous: UIWindow?

        init(content: some View) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = UIHostingController(
                rootView: content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.black)
                    .environment(\.locale, Locale(identifier: "en"))
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
        }

        func snapshot(attachment name: String? = nil) throws -> Data {
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            if let name {
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                XCTContext.runActivity(named: name) { $0.add(attachment) }
            }
            return try XCTUnwrap(image.pngData())
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
