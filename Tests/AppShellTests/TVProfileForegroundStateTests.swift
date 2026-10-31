#if os(tvOS)
import SwiftUI
import XCTest
@testable import AppShell

@MainActor
final class TVProfileForegroundStateTests: XCTestCase {
    func testEveryDelayUsesTimeAwayAndLocksAtTheExactThreshold() {
        for delay in [60.0, 300, 900, 1_800] {
            for elapsed in [delay - 0.001, delay, delay + 1] {
                let state = TVProfileForegroundState()
                let start = ContinuousClock.now
                XCTAssertFalse(state.shouldLock(after: .active, delay: delay, now: start))
                XCTAssertFalse(state.shouldLock(after: .background, delay: delay, now: start))
                let shouldLock = elapsed >= delay
                XCTAssertEqual(
                    state.shouldLock(after: .inactive, delay: delay, now: start + .seconds(elapsed)),
                    shouldLock
                )
                XCTAssertFalse(state.shouldLock(after: .active, delay: delay, now: start + .seconds(elapsed)))
            }
        }
    }

    func testDirectReturnAndRepeatedBackgroundNotificationsDoNotResetTheDeadline() {
        let state = TVProfileForegroundState()
        let start = ContinuousClock.now
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start))
        XCTAssertFalse(state.shouldLock(after: .background, delay: 300, now: start))
        XCTAssertFalse(state.shouldLock(after: .background, delay: 300, now: start + .seconds(290)))
        XCTAssertTrue(state.shouldLock(after: .active, delay: 300, now: start + .seconds(300)))
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start + .seconds(301)))
        XCTAssertFalse(state.shouldLock(after: .inactive, delay: 300, now: start + .seconds(1_000)))
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start + .seconds(2_000)))
    }

    func testReturningBeforeExpiryStartsANewGracePeriodForTheNextDeparture() {
        let state = TVProfileForegroundState()
        let start = ContinuousClock.now
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start))
        XCTAssertFalse(state.shouldLock(after: .background, delay: 300, now: start))
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start + .seconds(299)))
        XCTAssertFalse(state.shouldLock(after: .background, delay: 300, now: start + .seconds(300)))
        XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start + .seconds(301)))
    }

    func testNeverAndPlaybackDoNotExpire() {
        let start = ContinuousClock.now
        let never = TVProfileForegroundState()
        XCTAssertFalse(never.shouldLock(after: .active, delay: nil, now: start))
        XCTAssertFalse(never.shouldLock(after: .background, delay: nil, now: start))
        XCTAssertFalse(never.shouldLock(after: .active, delay: nil, now: start + .seconds(86_400)))
        for externalPlayer in [false, true] {
            let state = TVProfileForegroundState()
            let player = UUID()
            state.setPlayback(!externalPlayer, id: player)
            XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start))
            XCTAssertFalse(state.shouldLock(after: .inactive, leavingForExternalPlayer: externalPlayer, delay: 300, now: start))
            state.setPlayback(false, id: player)
            XCTAssertFalse(state.shouldLock(after: .background, delay: 300, now: start))
            XCTAssertFalse(state.shouldLock(after: .active, delay: 300, now: start + .seconds(86_400)))
        }
    }

    func testOnlyARealBackgroundAfterBrowsingLocks() {
        let state = TVProfileForegroundState()
        XCTAssertFalse(state.shouldLock(after: .inactive))
        XCTAssertFalse(state.shouldLock(after: .background))
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .inactive))
        XCTAssertFalse(state.shouldLock(after: .active), "Control Center does not lock.")
        XCTAssertFalse(state.shouldLock(after: .inactive))
        XCTAssertTrue(state.shouldLock(after: .background))
        XCTAssertFalse(state.shouldLock(after: .background))
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertTrue(state.shouldLock(after: .background), "A direct background transition also locks.")
    }

    func testOpenPlayerSurvivesSuspensionButClosingItRestoresTheBrowsingGate() {
        let state = TVProfileForegroundState()
        let player = UUID()
        state.setPlayback(true, id: player)
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .inactive))
        state.setPlayback(false, id: player)
        XCTAssertFalse(state.shouldLock(after: .background), "Suspension must not revoke the captured player exemption.")
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .inactive))
        XCTAssertTrue(state.shouldLock(after: .background))
    }

    func testMultiplePlayersBalanceTheirOwnPresence() {
        let state = TVProfileForegroundState()
        let first = UUID(), second = UUID()
        state.setPlayback(true, id: first)
        state.setPlayback(true, id: second)
        state.setPlayback(false, id: first)
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .background))
        state.setPlayback(false, id: second)
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertTrue(state.shouldLock(after: .background))
    }

    func testExternalHandoffExemptsOnlyItsOwnDeparture() {
        let state = TVProfileForegroundState()
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .inactive, leavingForExternalPlayer: true))
        XCTAssertFalse(state.shouldLock(after: .background))
        XCTAssertFalse(state.shouldLock(after: .active))
        XCTAssertFalse(state.shouldLock(after: .inactive))
        XCTAssertTrue(state.shouldLock(after: .background))
    }
}
#endif
