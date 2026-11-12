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
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.hide(ContentRefreshTestConstants.episode)

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

    func testEveryPlatformAndSurfaceUsesExactBoundary() {
        for profile in [ContentRefreshProfile.tvOS, .iOS] {
            for surface in [
                ContentRefreshTestConstants.home, ContentRefreshTestConstants.series,
                ContentRefreshTestConstants.episode, ContentRefreshTestConstants.movie
            ] {
                let threshold = surface.kind == .home
                    ? ContentRefreshTestConstants.homeThreshold : ContentRefreshTestConstants.detailThreshold
                for foreground in [true, false] {
                    for duration in [threshold - 1, threshold, threshold + 1] {
                        let harness = ContentRefreshHarness(profile: profile)
                        harness.show(surface)
                        if foreground { harness.coordinator.applicationWillResignActive() }
                        else { harness.hide(surface) }
                        harness.advance(by: duration)
                        if foreground { harness.coordinator.applicationDidBecomeActive() }
                        else { harness.show(surface) }
                        XCTAssertEqual(harness.coordinator.request != nil, duration >= threshold)
                    }
                }
            }
        }
    }

    func testRepeatedCallbacksDoNotResetAbsenceOrEmitAgain() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.applicationWillResignActive()
        harness.advance(by: ContentRefreshTestConstants.homeThreshold)
        harness.coordinator.applicationWillResignActive()
        harness.coordinator.applicationDidBecomeActive()
        let request = harness.coordinator.request
        XCTAssertNotNil(request)
        harness.coordinator.applicationDidBecomeActive()
        harness.show(ContentRefreshTestConstants.home)
        XCTAssertEqual(harness.coordinator.request, request)
    }

    func testVisibleTimeDoesNotCountAsTimeAway() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.series)
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.show(ContentRefreshTestConstants.episode)
        harness.advance(by: ContentRefreshTestConstants.shortAway)
        harness.hide(ContentRefreshTestConstants.episode)
        XCTAssertNil(harness.coordinator.request)
    }

    func testVisibilityBeforeActivationDefersTheRequest() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.applicationWillResignActive()
        harness.hide(ContentRefreshTestConstants.home)
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.show(ContentRefreshTestConstants.home)
        XCTAssertNil(harness.coordinator.request)
        harness.coordinator.applicationDidBecomeActive()
        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.home)
    }

    func testActivationBeforeVisibilityPreservesTheRequest() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.applicationWillResignActive()
        harness.hide(ContentRefreshTestConstants.home)
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()
        XCTAssertNil(harness.coordinator.request)
        harness.show(ContentRefreshTestConstants.home)
        XCTAssertEqual(harness.coordinator.request?.surface, ContentRefreshTestConstants.home)
    }

    func testResetInvalidatesOldRequestsAndRetainedRegistration() throws {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.requestManualRefresh()
        let old = try XCTUnwrap(harness.coordinator.request)
        harness.coordinator.reset()
        XCTAssertFalse(harness.coordinator.isCurrent(old))
        harness.show(ContentRefreshTestConstants.home)
        XCTAssertNil(harness.coordinator.request)
        harness.coordinator.requestManualRefresh()
        let current = try XCTUnwrap(harness.coordinator.request)
        XCTAssertGreaterThan(current.generation, old.generation)
    }

    func testResetWhileInactiveCannotRefreshUntilActivation() {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.applicationWillResignActive()
        harness.coordinator.reset()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.requestManualRefresh()
        XCTAssertNil(harness.coordinator.request)
        harness.advance(by: ContentRefreshTestConstants.longAway)
        harness.coordinator.applicationDidBecomeActive()
        XCTAssertEqual(harness.coordinator.request?.action, .reloadHome)
    }

    func testRepeatedTitlePagesHaveIndependentOwnership() throws {
        let harness = ContentRefreshHarness()
        let first = ContentRefreshRegistration(surface: ContentRefreshTestConstants.movie)
        let second = ContentRefreshRegistration(surface: ContentRefreshTestConstants.movie)
        harness.coordinator.surfaceDidBecomeVisible(first)
        harness.coordinator.surfaceDidBecomeVisible(second)
        harness.coordinator.requestManualRefresh()
        let old = try XCTUnwrap(harness.coordinator.request)
        XCTAssertEqual(old.registrationID, second.id)
        harness.coordinator.surfaceDidDisappear(second)
        XCTAssertFalse(harness.coordinator.isCurrent(old))
        harness.coordinator.requestManualRefresh()
        XCTAssertEqual(harness.coordinator.request?.registrationID, first.id)
    }

    func testHideAndBackgroundInvalidateInFlightRequests() throws {
        let harness = ContentRefreshHarness()
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.requestManualRefresh()
        let old = try XCTUnwrap(harness.coordinator.request)
        harness.hide(ContentRefreshTestConstants.home)
        XCTAssertFalse(harness.coordinator.isCurrent(old))
        harness.show(ContentRefreshTestConstants.home)
        harness.coordinator.requestManualRefresh()
        let current = try XCTUnwrap(harness.coordinator.request)
        harness.coordinator.applicationWillResignActive()
        XCTAssertFalse(harness.coordinator.isCurrent(current))
    }
}
