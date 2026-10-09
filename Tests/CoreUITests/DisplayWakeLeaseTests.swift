#if canImport(UIKit)
import XCTest
@testable import CoreUI

@MainActor
final class DisplayWakeLeaseTests: XCTestCase {
    func testImportAndPlaybackReleaseOnlyTheirOwnAssertions() {
        var requests: [Bool] = []
        let group = DisplayWakeGroup { requests.append($0) }
        let importLease = DisplayWakeLease(group: group)
        let playbackLease = DisplayWakeLease(group: group)
        importLease.keepAwake(true)
        importLease.keepAwake(true)
        playbackLease.keepAwake(true)
        importLease.allowSleep()
        importLease.allowSleep()
        XCTAssertFalse(requests.contains(false))
        playbackLease.allowSleep()
        XCTAssertEqual(requests.last, false)
    }

    func testLateDeinitializationDoesNotReleaseANewOwner() async {
        var requests: [Bool] = []
        let group = DisplayWakeGroup { requests.append($0) }
        var outgoing: DisplayWakeLease? = DisplayWakeLease(group: group)
        outgoing?.keepAwake(true)
        let incoming = DisplayWakeLease(group: group)
        incoming.keepAwake(true)
        weak var released = outgoing
        outgoing = nil
        for _ in 0..<100 where requests.count < 3 { await Task.yield() }
        XCTAssertNil(released)
        XCTAssertGreaterThanOrEqual(requests.count, 3)
        XCTAssertFalse(requests.contains(false))
        incoming.allowSleep()
        XCTAssertEqual(requests.last, false)
    }

    func testFinalOwnerDeinitializationAllowsSleep() async {
        var requests: [Bool] = []
        let group = DisplayWakeGroup { requests.append($0) }
        var lease: DisplayWakeLease? = DisplayWakeLease(group: group)
        lease?.keepAwake(true)
        lease = nil
        for _ in 0..<100 where requests.count < 2 { await Task.yield() }
        XCTAssertEqual(requests, [true, false])
    }
}
#endif
