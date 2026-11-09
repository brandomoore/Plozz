import XCTest
import FeatureHomeCore
import TestSupportContentRefresh

@MainActor
final class ContentRefreshCoordinatorTests: XCTestCase {
    func testFirstVisibilityDoesNotRefresh() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)

        XCTAssertNil(harness.coordinator.request)
    }

    func testShortForegroundAbsenceDoesNotRefresh() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.shortAway)
        harness.coordinator.applicationDidBecomeActive()

        XCTAssertNil(harness.coordinator.request)
    }

    func testLongForegroundAbsenceRefreshesHome() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.home)
        XCTAssertEqual(harness.coordinator.request?.action, .reloadHome)
    }

    func testSeriesSurfaceRefreshesSeriesContext() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.series)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.series)
        XCTAssertEqual(harness.coordinator.request?.action, .reloadSeriesContext)
    }

    func testEpisodeSurfaceRefreshesWatchStateOnly() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.series)
        harness.show(ContentRefreshTestConstants.episode)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.episode)
        XCTAssertEqual(harness.coordinator.request?.action, .refreshWatchStateOnly)
    }

    func testOnlyTopSurfaceReceivesForegroundRefresh() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.show(ContentRefreshTestConstants.series)
        harness.show(ContentRefreshTestConstants.episode)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.episode)
    }

    func testReturningToCoveredSurfaceRefreshesAfterThreshold() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.series)
        harness.show(ContentRefreshTestConstants.episode)
        harness.hide(ContentRefreshTestConstants.episode)

        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.surfaceDidBecomeVisible(ContentRefreshTestConstants.series)

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.series)
        XCTAssertEqual(harness.coordinator.request?.action, .reloadSeriesContext)
    }

    func testManualRefreshUsesTopSurfaceAction() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.movie)

        harness.coordinator.requestManualRefresh()

        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.movie)
        XCTAssertEqual(harness.coordinator.request?.action, .refreshWatchStateOnly)
    }

    func testProfileThresholdsAreUsed() {
        let harness = ContentRefreshHarness(profile: .iOS)
        harness.show(ContentRefreshTestConstants.episode)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.detailThreshold - 1)
        harness.coordinator.applicationDidBecomeActive()
        XCTAssertNil(harness.coordinator.request)

        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.detailThreshold)
        harness.coordinator.applicationDidBecomeActive()
        XCTAssertEqual(harness.coordinator.request?.action, .refreshWatchStateOnly)
    }
}
