#if os(tvOS)
import CoreModels
@testable import FeatureHome
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeShareScanRefreshHostedTests: XCTestCase {
    func testHiddenChangesCoalesceAndRefreshWhenHomeReturns() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await fixture.establishBaseline()
        fixture.state.frontmost = false
        try await settle()
        for _ in 0..<3 {
            fixture.status.catalogChanged(shareID: "share")
            try await settle()
        }
        XCTAssertEqual(fixture.state.refreshes, 0)
        fixture.state.frontmost = true
        try await waitUntil { fixture.state.refreshes == 1 }
        fixture.state.frontmost = false
        try await settle()
        fixture.state.frontmost = true
        try await settle()
        XCTAssertEqual(fixture.state.refreshes, 1, "Pending changes are consumed once, not on every reveal.")
    }

    func testPollingStopsWhileCoveredAndOverduePollResumesOnReturn() async throws {
        let fixture = try await fixture(pollInterval: .milliseconds(250))
        defer { fixture.close() }
        try await waitUntil { fixture.state.polls > 0 }
        fixture.state.frontmost = false
        try await settle()
        let before = fixture.state.polls
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(fixture.state.polls, before)
        fixture.state.frontmost = true
        try await waitUntil { fixture.state.polls > before }
        XCTAssertEqual(fixture.state.polls, before + 1, "Missed intervals coalesce, never catch up as a burst.")
    }

    func testVisibleCatalogChangesStillRespectTrailerAndNavigation() async throws {
        let fixture = try await fixture(idle: false, pollInterval: .milliseconds(100))
        defer { fixture.close() }
        try await fixture.establishBaseline()
        fixture.status.catalogChanged(shareID: "share")
        try await settle()
        XCTAssertEqual(fixture.state.refreshes, 0)
        fixture.state.trailerPlaying = true
        try await settle()
        fixture.navigation.recordInteraction(at: .now.advanced(by: .seconds(-31)))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.state.refreshes, 0)
        fixture.state.trailerPlaying = false
        try await waitUntil { fixture.state.refreshes == 1 }
        fixture.status.scanFinished(shareID: "share")
        try await settle()
        XCTAssertEqual(fixture.state.refreshes, 1, "An unchanged completed scan is not a catalog change.")
    }

    private func fixture(
        hasShare: Bool = true, idle: Bool = true, pollInterval: Duration = .seconds(120)
    ) async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene, hasShare: hasShare, idle: idle, pollInterval: pollInterval)
        try await settle()
        return fixture
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "The production refresh observer did not settle.")
    }

    @MainActor @Observable
    final class State {
        var frontmost = true
        var trailerPlaying = false
        var phase = ScenePhase.active
        @ObservationIgnored var refreshes = 0
        @ObservationIgnored var polls = 0
    }

    private struct Content: View {
        let state: State
        let status: ShareScanStatusModel
        let navigation: HomeNavigationActivity
        let pollInterval: Duration

        var body: some View {
            HomeShareScanRefreshObserver(
                onRefresh: { state.refreshes += 1 }, isTrailerPlaying: state.trailerPlaying,
                isFrontmost: state.frontmost, onPollShares: { state.polls += 1 },
                pollInterval: pollInterval, navigationActivity: navigation
            )
            .environment(status)
            .environment(\.scenePhase, state.phase)
        }
    }

    @MainActor
    private final class Fixture {
        let state = State()
        let status = ShareScanStatusModel()
        let navigation: HomeNavigationActivity
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, hasShare: Bool, idle: Bool, pollInterval: Duration) {
            navigation = HomeNavigationActivity(now: .now.advanced(by: .seconds(idle ? -31 : 0)))
            if hasShare { status.scanStarted(shareID: "share", name: "Fixture") }
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Content(
                state: state, status: status, navigation: navigation, pollInterval: pollInterval
            ))
            window.makeKeyAndVisible()
        }

        func establishBaseline() async throws {
            status.catalogChanged(shareID: "share")
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(state.refreshes, 0, "The cold-load baseline must not trigger a duplicate load.")
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
#endif
