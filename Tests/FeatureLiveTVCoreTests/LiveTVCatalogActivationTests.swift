import XCTest
@testable import FeatureLiveTVCore

final class LiveTVCatalogActivationTests: XCTestCase {
    func testOpeningJoinsHiddenPreload() {
        let hidden = activation(active: false)
        let open = activation(active: true, visited: true)
        XCTAssertTrue(hidden.loadsCatalog)
        XCTAssertEqual(hidden.taskID(reloadRequest: 7), 7)
        XCTAssertEqual(open.taskID(reloadRequest: 7), 7)
    }

    func testPreloadDoesNotRestartAfterFirstVisitAndReentryLoads() {
        let hidden = activation(active: false, visited: true)
        XCTAssertFalse(hidden.loadsCatalog)
        XCTAssertEqual(hidden.taskID(reloadRequest: 7), -1)
        XCTAssertEqual(activation(active: true, visited: true).taskID(reloadRequest: 7), 7)
    }

    func testAuthorizationLossCancelsCatalogTask() {
        XCTAssertEqual(activation(active: false, authorized: false).taskID(reloadRequest: 7), -1)
        XCTAssertEqual(activation(active: true, authorized: false).taskID(reloadRequest: 7), -1)
    }

    func testNonPreloadingShellsIncludingIOSOnlyLoadWhileVisible() {
        XCTAssertFalse(activation(active: false, preloads: false).loadsCatalog)
        XCTAssertTrue(activation(active: true, preloads: false).loadsCatalog)
    }

    func testRetainedDestinationMountsForVisitOrCompletedPreload() {
        XCTAssertFalse(LiveTVCatalogActivation.mountsDestination(isActive: false, hasAppeared: false))
        XCTAssertTrue(LiveTVCatalogActivation.mountsDestination(isActive: true, hasAppeared: false))
        XCTAssertTrue(LiveTVCatalogActivation.mountsDestination(isActive: false, hasAppeared: true))
        XCTAssertTrue(LiveTVCatalogActivation.shouldPreload(preloads: true, hasAppeared: false))
        XCTAssertFalse(LiveTVCatalogActivation.shouldPreload(preloads: false, hasAppeared: false))
        XCTAssertFalse(LiveTVCatalogActivation.shouldPreload(preloads: true, hasAppeared: true))
    }

    private func activation(
        active: Bool, visited: Bool = false, preloads: Bool = true, authorized: Bool = true
    ) -> LiveTVCatalogActivation {
        .init(isActive: active, hasBeenActive: visited, preloadsCatalog: preloads, isAuthorized: authorized)
    }
}
