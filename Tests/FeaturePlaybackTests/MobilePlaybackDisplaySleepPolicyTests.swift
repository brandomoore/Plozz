import XCTest
#if os(iOS)
import Observation
import SwiftUI
import UIKit
#endif
@testable import FeaturePlayback

final class MobilePlaybackDisplaySleepPolicyTests: XCTestCase {
    func testOnlyVisibleForegroundPlaybackPreventsSleep() {
        for playbackActive in [false, true] {
            for isVisible in [false, true] {
                for sceneIsActive in [false, true] {
                    XCTAssertEqual(MobilePlaybackDisplaySleepPolicy.shouldStayAwake(
                        playbackActive: playbackActive,
                        isVisible: isVisible,
                        sceneIsActive: sceneIsActive
                    ), playbackActive && isVisible && sceneIsActive)
                }
            }
        }
    }

    func testBackgroundContinuationDoesNotKeepThePhoneScreenAwake() {
        XCTAssertFalse(MobilePlaybackDisplaySleepPolicy.shouldStayAwake(
            playbackActive: true, isVisible: true, sceneIsActive: false
        ), "PiP, AirPlay, and background audio may continue without a foreground wake assertion")
    }

    #if canImport(UIKit)
    @MainActor
    func testOutgoingPlayerAndLateTeardownCannotReleaseIncomingPlayersLease() async {
        var wakeRequests: [Bool] = []
        let group = LiveChannelWakeGroup { wakeRequests.append($0) }
        var outgoing: LiveChannelWakeLease? = LiveChannelWakeLease(group: group)
        let incoming = LiveChannelWakeLease(group: group)
        outgoing?.keepAwake(true)
        incoming.keepAwake(true)
        outgoing?.keepAwake(MobilePlaybackDisplaySleepPolicy.shouldStayAwake(
            playbackActive: true, isVisible: false, sceneIsActive: true
        ))
        outgoing = nil
        for _ in 0..<100 where wakeRequests.count < 4 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(wakeRequests.count, 4)
        XCTAssertFalse(wakeRequests.contains(false))
        incoming.allowSleep()
        XCTAssertEqual(wakeRequests.last, false)
    }
    #endif

    #if os(iOS)
    @MainActor
    func testHostedLoadingPresentationUpdatesAndReleasesItsWakeLease() async throws {
        var requests: [Bool] = []
        let group = LiveChannelWakeGroup { requests.append($0) }
        let lease = LiveChannelWakeLease(group: group)
        let state = WakePresentationState()
        let host = UIHostingController(rootView: WakePresentationFixture(state: state, lease: lease))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
            lease.allowSleep()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, true, "Visible startup must acquire the lease before frames exist")
        state.playbackActive = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, false, "Pause/failure must release while the player remains visible")
        state.playbackActive = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, true)
        state.scene = .background
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, false)
        state.scene = .active
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, true)
        state.visible = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.last, false, "Dismissal must release even if playback intent stays active")
    }
    #endif
}

#if os(iOS)
@MainActor @Observable
private final class WakePresentationState {
    var visible = true
    var playbackActive = true
    var scene = ScenePhase.active
}

private struct WakePresentationFixture: View {
    let state: WakePresentationState
    let lease: LiveChannelWakeLease

    var body: some View {
        Group {
            if state.visible {
                Color.black.modifier(MobilePlaybackDisplaySleepModifier(
                    playbackActive: state.playbackActive, wakeLease: lease
                ))
            }
        }
        .environment(\.scenePhase, state.scene)
    }
}
#endif
