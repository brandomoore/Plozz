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
        XCTAssertEqual(request.focusTarget, .content)
        XCTAssertFalse(handoff.complete(.init(
            destination: .home, generation: request.generation, focusTarget: .content
        )))
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

    func testHomeBackRetainsItsNavigationFocusTargetUntilPresentation() throws {
        let handoff = NavigationDestinationFocusHandoff()
        handoff.begin(.home, focusTarget: .navigation)
        let request = try XCTUnwrap(handoff.request)
        XCTAssertEqual(request.focusTarget, .navigation)
        handoff.begin(.home, focusTarget: .navigation)
        XCTAssertEqual(handoff.request, request)
        XCTAssertTrue(handoff.complete(request))
        XCTAssertFalse(handoff.isWaiting)
    }

    func testSelectingPendingHomeReplacesNavigationFocusWithContentFocus() throws {
        let handoff = NavigationDestinationFocusHandoff()
        handoff.begin(.home, focusTarget: .navigation)
        let menuRequest = try XCTUnwrap(handoff.request)
        handoff.begin(.home)
        let contentRequest = try XCTUnwrap(handoff.request)
        XCTAssertEqual(contentRequest.focusTarget, .content)
        XCTAssertNotEqual(contentRequest.generation, menuRequest.generation)
        XCTAssertFalse(handoff.complete(menuRequest))
        XCTAssertEqual(handoff.request, contentRequest)
        XCTAssertTrue(handoff.complete(contentRequest))
    }
}
#endif
