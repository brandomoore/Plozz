#if os(iOS)
import CoreModels
@testable import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeResponsivenessDiagnosticsTests: XCTestCase {
    func testDisabledProbeReturnsWithoutCollecting() async {
        let diagnostics = PerformanceDiagnostics()
        let probe = MainThreadStallProbe.HomeResponsivenessProbe()
        await probe.run(diagnostics: diagnostics)
        probe.noteHeight(from: 100, to: 200)
        XCTAssertNil(diagnostics.snapshot())
    }

    func testProbeMeasuresSchedulingDelayGeometryAndShareActivityThenCancels() async throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let probe = MainThreadStallProbe.HomeResponsivenessProbe()
        probe.isLoading = true
        probe.isScrolling = true
        ShareBackgroundActivity.scanStarted()
        ShareBackgroundActivity.listStarted()
        defer {
            ShareBackgroundActivity.scanFinished()
            ShareBackgroundActivity.listFinished()
        }
        let task = Task { await probe.run(diagnostics: diagnostics) }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        probe.noteHeight(from: 100, to: 250)
        probe.noteHeight(from: 0, to: 500)
        probe.noteHeight(from: .nan, to: 500)
        probe.noteHeight(from: 100, to: .infinity)
        probe.noteHeight(from: 100, to: 100.2)
        blockMainActor()
        try await waitUntil { diagnostics.snapshot()?.homeUI.isEmpty == false }
        let record = try XCTUnwrap(diagnostics.snapshot()?.homeUI.first)
        XCTAssertGreaterThanOrEqual(record.metrics.maximumDelayMilliseconds, 100)
        XCTAssertGreaterThan(record.metrics.delayedSamples, 0)
        XCTAssertEqual(record.metrics.scrollingSamples, record.metrics.samples)
        XCTAssertEqual(record.metrics.loadingSamples, record.metrics.samples)
        XCTAssertEqual(record.metrics.heightChanges, 1)
        XCTAssertEqual(record.metrics.maximumHeightDeltaPoints, 150)
        XCTAssertGreaterThanOrEqual(record.metrics.maximumActiveScans, 1)
        XCTAssertGreaterThanOrEqual(record.metrics.maximumActiveListers, 1)
        task.cancel()
        await task.value
        let count = diagnostics.snapshot()?.homeUI.count
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(diagnostics.snapshot()?.homeUI.count, count)
    }

    func testMountedObserverStopsForHiddenInactiveUnmountedAndReplacedHome() async throws {
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start()
        defer { diagnostics.stop() }
        let state = HomeDiagnosticFixtureState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: HomeDiagnosticFixture(
            state: state, diagnostics: diagnostics
        ))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { diagnostics.snapshot()?.homeUI.isEmpty == false }
        state.height = 2_500
        try await waitUntil {
            diagnostics.snapshot()?.homeUI.contains { $0.metrics.maximumHeightDeltaPoints == 500 } == true
        }
        state.enabled = false
        try await assertStops(diagnostics)
        var count = diagnostics.snapshot()?.homeUI.count ?? 0
        state.enabled = true
        try await waitUntil { (diagnostics.snapshot()?.homeUI.count ?? 0) > count }
        state.phase = .inactive
        try await assertStops(diagnostics)
        count = diagnostics.snapshot()?.homeUI.count ?? 0
        state.phase = .active
        try await waitUntil { (diagnostics.snapshot()?.homeUI.count ?? 0) > count }

        diagnostics.stop()
        diagnostics.start()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(try XCTUnwrap(diagnostics.snapshot()).homeUI.isEmpty)
        state.scope = NSObject()
        state.loading = false
        state.scrolling = false
        try await waitUntil { diagnostics.snapshot()?.homeUI.isEmpty == false }
        let replacement = try XCTUnwrap(diagnostics.snapshot()?.homeUI.first)
        XCTAssertEqual(replacement.metrics.heightChanges, 0)
        XCTAssertEqual(replacement.metrics.loadingSamples, 0)
        XCTAssertEqual(replacement.metrics.scrollingSamples, 0)
        state.mounted = false
        try await assertStops(diagnostics)
    }

    private func blockMainActor() {
        // Intentional, bounded scheduling fault; this is not a presented-frame test.
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func assertStops(_ diagnostics: PerformanceDiagnostics) async throws {
        try await Task.sleep(for: .milliseconds(250))
        let count = diagnostics.snapshot()?.homeUI.count
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(diagnostics.snapshot()?.homeUI.count, count)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}

@MainActor @Observable
private final class HomeDiagnosticFixtureState {
    var enabled = true
    var mounted = true
    var loading = true
    var scrolling = true
    var height: CGFloat = 2_000
    var phase = ScenePhase.active
    var scope = NSObject()
}

private struct HomeDiagnosticFixture: View {
    let state: HomeDiagnosticFixtureState
    let diagnostics: PerformanceDiagnostics

    var body: some View {
        Group {
            if state.mounted {
                ScrollView {
                    Color.clear.frame(height: state.height)
                }
                .modifier(MainThreadStallProbe.HomeResponsivenessModifier(
                    isEnabled: state.enabled, scope: ObjectIdentifier(state.scope),
                    isScrolling: state.scrolling, isLoading: state.loading, diagnostics: diagnostics
                ))
            }
        }
        .environment(\.scenePhase, state.phase)
    }
}
#endif
