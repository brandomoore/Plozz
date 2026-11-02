import CoreModels
import Foundation
import Observation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVGuidePreparationTests: XCTestCase {
    func testProgressUsesOnlyReliableStageTotals() {
        XCTAssertNil(ServerLiveTVGuideProgress(stage: .downloading, completed: 20).fractionCompleted)
        XCTAssertNil(ServerLiveTVGuideProgress(stage: .downloading, completed: 20, total: 0).fractionCompleted)
        XCTAssertNil(ServerLiveTVGuideProgress(stage: .downloading, completed: 20, total: 10).fractionCompleted)
        XCTAssertEqual(ServerLiveTVGuideProgress(stage: .downloading, completed: 20, total: 100).fractionCompleted, 0.2)
    }

    func testProgressContinuesAfterToastDismissalWithoutDuplicatingInlineStatus() async {
        let started = expectation(description: "Guide request started")
        let provider = PreparationProvider(started: { started.fulfill() }, suspended: true)
        let model = model(provider)
        XCTAssertNil(model.notificationStatus)
        model.start(accountID: "one")
        await fulfillment(of: [started], timeout: 3)
        let progress = ServerLiveTVGuideProgress(stage: .downloading, completed: 512, total: 1_024)
        await provider.emit(progress)
        for _ in 0..<100 where model.statuses["one"]?.progress != progress { await Task.yield() }
        XCTAssertEqual(model.notificationStatus?.progress, progress)
        let first = UUID()
        let second = UUID()
        model.setInlinePresentation(first, accountID: "one")
        model.setInlinePresentation(second, accountID: "one")
        XCTAssertNil(model.notificationStatus)
        model.setInlinePresentation(first, accountID: nil)
        XCTAssertNil(model.notificationStatus)
        model.setInlinePresentation(second, accountID: nil)
        let requestID = model.statuses["one"]!.requestID
        XCTAssertNotNil(model.notificationStatus)
        model.dismissNotification(accountID: "one", requestID: requestID)
        XCTAssertNil(model.notificationStatus)
        await provider.resume()
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.phase, .loaded)
        XCTAssertNil(model.notificationStatus)
        model.start(accountID: "one", refresh: true)
        model.dismissNotification(accountID: "one", requestID: requestID)
        XCTAssertNotNil(model.notificationStatus, "An old toast cannot dismiss a new refresh.")
        await model.waitForCompletion(accountID: "one")
    }

    func testCancelledRequestIgnoresLateProgress() async {
        let started = expectation(description: "Guide request started")
        let provider = PreparationProvider(started: { started.fulfill() }, suspended: true)
        let model = model(provider)
        model.start(accountID: "one")
        await fulfillment(of: [started], timeout: 3)
        model.cancel(accountID: "one")
        await provider.emit(.init(stage: .downloading, completed: 100))
        await provider.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.statuses["one"]?.phase, .paused)
        XCTAssertNil(model.statuses["one"]?.progress)
        XCTAssertNil(model.notificationStatus)
    }

    @Observable final class Authorization {
        var identity: String? = "first"
    }

    private func model(
        _ provider: PreparationProvider, authorization: Authorization = Authorization()
    ) -> LiveTVGuidePreparationModel {
        LiveTVGuidePreparationModel { id in
            authorization.identity.map {
                LiveTVAuthorizedServerProvider(accountID: id, authorizationID: $0, kind: .iptv, provider: provider)
            }
        }
    }

    func testInitialImportRemainsVisibleUntilListingsArriveAndCoalescesRepeatedStarts() async {
        let started = expectation(description: "Guide request started")
        let provider = PreparationProvider(started: { started.fulfill() }, suspended: true)
        let model = model(provider)
        model.start(accountID: "one")
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(model.statuses["one"]?.phase, .loading)
        XCTAssertEqual(model.statuses["one"]?.isRefresh, false)
        model.start(accountID: "one", refresh: true)
        await provider.resume()
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.phase, .loaded)
        XCTAssertEqual(model.statuses["one"]?.channelCount, 1)
        XCTAssertEqual(model.statuses["one"]?.channelsWithListings, 1)
        XCTAssertNotNil(model.statuses["one"]?.refreshedAt)
        let counts = await provider.counts
        XCTAssertEqual(counts.requests, 1)
        XCTAssertEqual(counts.invalidations, 0)
    }

    func testLargeLineupUsesBoundedBatchesAndCountsAllMatchingChannels() async {
        let provider = PreparationProvider(channelCount: 2_001)
        let model = model(provider)
        model.start(accountID: "one")
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.channelsWithListings, 2_001)
        let batches = await provider.batches
        XCTAssertEqual(batches, [2_000, 1])
        XCTAssertEqual(model.completionRevision, 1)
    }

    func testMissingGuideAndEmptyGuideAreDifferentOutcomes() async {
        let missingProvider = PreparationProvider(supportsGuide: false)
        let missing = model(missingProvider)
        missing.start(accountID: "one")
        await missing.waitForCompletion(accountID: "one")
        XCTAssertEqual(missing.statuses["one"]?.phase, .notConfigured)
        let counts = await missingProvider.counts
        XCTAssertEqual(counts.requests, 0)

        let empty = model(PreparationProvider(hasListings: false))
        empty.start(accountID: "one")
        await empty.waitForCompletion(accountID: "one")
        XCTAssertEqual(empty.statuses["one"]?.phase, .empty)
        XCTAssertNotNil(empty.statuses["one"]?.refreshedAt)
    }

    func testManualRefreshInvalidatesOnlyGuideAndRetainsLastSuccessOnFailure() async {
        let provider = PreparationProvider()
        let model = model(provider)
        model.start(accountID: "one")
        await model.waitForCompletion(accountID: "one")
        let previous = model.statuses["one"]
        await provider.fail()
        model.start(accountID: "one", refresh: true)
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.phase, .failed(.guideUnavailable))
        XCTAssertEqual(model.statuses["one"]?.channelsWithListings, previous?.channelsWithListings)
        XCTAssertEqual(model.statuses["one"]?.refreshedAt, previous?.refreshedAt)
        let counts = await provider.counts
        XCTAssertEqual(counts.invalidations, 1)
        XCTAssertEqual(counts.catalogRefreshes, 0)
        XCTAssertEqual(model.completionRevision, 1)
    }

    func testPendingGuideDiscoveryFinishesBeforeReportingMissingGuide() async {
        let provider = PreparationProvider(supportsGuide: false, discoveredGuide: true)
        let model = model(provider)
        model.start(accountID: "one")
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.phase, .loaded)
    }

    func testPermissionRefusalDoesNotFetchOrInvalidateGuide() async {
        let provider = PreparationProvider(availability: .permissionDenied)
        let model = model(provider)
        model.start(accountID: "one", refresh: true)
        await model.waitForCompletion(accountID: "one")
        XCTAssertEqual(model.statuses["one"]?.phase, .failed(.permissionDenied))
        let counts = await provider.counts
        XCTAssertEqual(counts.requests, 0)
        XCTAssertEqual(counts.invalidations, 0)
        XCTAssertEqual(model.completionRevision, 0)
    }

    func testProfileChangeDiscardsAnInFlightResult() async {
        let started = expectation(description: "Guide request started")
        let provider = PreparationProvider(started: { started.fulfill() }, suspended: true)
        let authorization = Authorization()
        let model = model(provider, authorization: authorization)
        model.start(accountID: "one")
        await fulfillment(of: [started], timeout: 3)
        authorization.identity = "second"
        for _ in 0..<100 where model.statuses["one"] != nil { await Task.yield() }
        await provider.resume()
        await model.waitForCompletion(accountID: "one")
        XCTAssertNil(model.statuses["one"])
        XCTAssertEqual(model.completionRevision, 0)
    }

    func testCancellationIsPausedNotSuccess() async {
        let started = expectation(description: "Guide request started")
        let provider = PreparationProvider(started: { started.fulfill() }, suspended: true)
        let model = model(provider)
        model.start(accountID: "one")
        await fulfillment(of: [started], timeout: 3)
        model.cancel(accountID: "one")
        await provider.resume()
        XCTAssertEqual(model.statuses["one"]?.phase, .paused)
        XCTAssertNil(model.statuses["one"]?.refreshedAt)
    }
}

private actor PreparationProvider: ServerLiveTVProviding {
    let supportsGuide: Bool
    let discoveredGuide: Bool?
    let availability: ServerLiveTVAvailability.Status
    let hasListings: Bool
    let channelCount: Int
    let started: @Sendable () -> Void
    var suspended: Bool
    var continuation: CheckedContinuation<Void, Never>?
    var shouldFail = false
    var batches: [Int] = []
    var counts = (requests: 0, invalidations: 0, catalogRefreshes: 0)
    var report: ServerLiveTVGuideProgress.Handler?

    init(
        channelCount: Int = 1, supportsGuide: Bool = true, hasListings: Bool = true,
        discoveredGuide: Bool? = nil, availability: ServerLiveTVAvailability.Status = .available,
        started: @escaping @Sendable () -> Void = {}, suspended: Bool = false
    ) {
        self.channelCount = channelCount
        self.supportsGuide = supportsGuide
        self.discoveredGuide = discoveredGuide
        self.availability = availability
        self.hasListings = hasListings
        self.started = started
        self.suspended = suspended
    }

    func liveTVAvailability() -> ServerLiveTVAvailability {
        .init(status: availability, channelCount: channelCount, supportsGuide: supportsGuide)
    }

    func completeLiveTVGuideDiscovery() -> Bool? { discoveredGuide }

    func refreshLiveTVAvailability() -> ServerLiveTVAvailability {
        counts.catalogRefreshes += 1
        return liveTVAvailability()
    }

    func liveTVChannels() -> [ServerLiveTVChannel] {
        (0..<channelCount).map { .init(id: String($0), name: "Channel \($0)") }
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        counts.requests += 1
        batches.append(channelIDs.count)
        report = ServerLiveTVGuideProgress.report
        if counts.requests == 1 { started() }
        if suspended { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return hasListings ? channelIDs.map {
            .init(id: $0, channelID: $0, title: "Programme", startDate: from, endDate: to)
        } : []
    }

    func invalidateLiveTVGuideCache() { counts.invalidations += 1 }
    func emit(_ progress: ServerLiveTVGuideProgress) { report?(progress) }
    func fail() { shouldFail = true }
    func resume() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }
    func openLiveTVChannel(id: String) throws -> any LiveTVStreamLease {
        throw ServerLiveTVError.unsupportedAPI
    }
}
