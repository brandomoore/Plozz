#if os(tvOS)
import CoreModels
import XCTest
@testable import AppShell

@MainActor
final class NavigationDestinationFocusHandoffTests: XCTestCase {
    func testOnlyTheRequestedDestinationCanCompleteTheHandoff() throws {
        let handoff = NavigationDestinationFocusHandoff()
        XCTAssertFalse(handoff.isWaiting)
        handoff.begin(.settings)
        let request = try XCTUnwrap(handoff.request)
        XCTAssertFalse(handoff.complete(.init(destination: .home, generation: request.generation)))
        XCTAssertTrue(handoff.isWaiting)
        XCTAssertTrue(handoff.complete(request))
        XCTAssertFalse(handoff.isWaiting)
        XCTAssertFalse(handoff.complete(request))
    }

    func testAnOlderPageCannotReleaseANewerHandoff() throws {
        let handoff = NavigationDestinationFocusHandoff()
        handoff.begin(.settings)
        let old = try XCTUnwrap(handoff.request)
        handoff.begin(.music)
        let latest = try XCTUnwrap(handoff.request)
        XCTAssertFalse(handoff.complete(old))
        XCTAssertEqual(handoff.request, latest)
        XCTAssertTrue(handoff.complete(latest))
    }

    func testCancelledRequestsStayInvalidAfterReturningToTheSameDestination() throws {
        let handoff = NavigationDestinationFocusHandoff()
        handoff.begin(.settings)
        let old = try XCTUnwrap(handoff.request)
        handoff.cancel()
        XCTAssertFalse(handoff.isWaiting)
        handoff.begin(.settings)
        let latest = try XCTUnwrap(handoff.request)
        XCTAssertNotEqual(old.generation, latest.generation)
        XCTAssertFalse(handoff.complete(old))
        XCTAssertTrue(handoff.complete(latest))
    }

    func testReselectingAPendingDestinationDoesNotRestartItsReadiness() {
        let handoff = NavigationDestinationFocusHandoff()
        handoff.begin(.settings)
        let original = handoff.request
        handoff.begin(.settings)
        XCTAssertEqual(handoff.request, original)
    }
}
#endif
