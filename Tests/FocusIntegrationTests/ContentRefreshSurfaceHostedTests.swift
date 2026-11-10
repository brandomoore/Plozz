#if os(tvOS)
import FeatureHomeCore
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ContentRefreshSurfaceHostedTests: XCTestCase {
    func testNotificationsRefreshOnlyVisibleSurfaceAndCancelWhenCovered() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.coordinator.requestManualRefresh()
        try await waitUntil { fixture.state.started == 1 }
        fixture.state.visible = false
        try await waitUntil { fixture.state.cancelled == 1 }
        XCTAssertEqual(fixture.state.completed, 0)

        fixture.state.clock = fixture.state.clock.advanced(by: .seconds(600))
        fixture.state.visible = true
        try await waitUntil { fixture.state.started == 2 }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try await waitUntil { fixture.state.cancelled == 2 }
        fixture.state.clock = fixture.state.clock.advanced(by: .seconds(600))
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { fixture.state.started == 3 }
        XCTAssertEqual(fixture.state.completed, 0)
    }

    func testProfileResetCancelsWorkAndReRegistersMountedSurface() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.coordinator.requestManualRefresh()
        try await waitUntil { fixture.state.started == 1 }
        fixture.coordinator.reset()
        try await waitUntil { fixture.state.cancelled == 1 }
        try await settle()
        fixture.coordinator.requestManualRefresh()
        try await waitUntil { fixture.state.started == 2 }
        XCTAssertEqual(fixture.state.completed, 0)
    }

    func testIdentityChangeAndUnmountCancelWork() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        fixture.coordinator.requestManualRefresh()
        try await waitUntil { fixture.state.started == 1 }
        fixture.state.itemID = "another-title"
        try await waitUntil { fixture.state.cancelled == 1 }
        try await settle()
        fixture.coordinator.requestManualRefresh()
        try await waitUntil { fixture.state.started == 2 }
        fixture.state.mounted = false
        try await waitUntil { fixture.state.cancelled == 2 }
        XCTAssertNil(fixture.coordinator.request)
    }

    private func fixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        try await settle()
        return fixture
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Content refresh adapter did not settle.")
    }

    @MainActor @Observable
    fileprivate final class State {
        var mounted = true
        var visible = true
        var itemID = "title"
        @ObservationIgnored var clock = ContinuousClock.now
        @ObservationIgnored var started = 0
        @ObservationIgnored var cancelled = 0
        @ObservationIgnored var completed = 0

        func refresh() async {
            started += 1
            do {
                try await Task.sleep(for: .seconds(30))
                completed += 1
            } catch is CancellationError {
                cancelled += 1
            } catch {
                XCTFail("Unexpected sleep failure: \(error)")
            }
        }
    }

    private struct Content: View {
        let state: State
        let coordinator: ContentRefreshCoordinator

        var body: some View {
            ZStack {
                if state.mounted {
                    Color.clear.contentRefreshSurface(
                        id: .init(kind: .movieDetail, accountID: "account", itemID: state.itemID),
                        isVisible: state.visible
                    ) { _ in await state.refresh() }
                }
            }
            .environment(coordinator)
            .background(ContentRefreshLifecycleReader(coordinator: coordinator))
        }
    }

    @MainActor
    private final class Fixture {
        let state = State()
        let coordinator: ContentRefreshCoordinator
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene) {
            let state = state
            coordinator = ContentRefreshCoordinator(profile: .tvOS, now: { state.clock })
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: Content(state: state, coordinator: coordinator))
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
#endif
