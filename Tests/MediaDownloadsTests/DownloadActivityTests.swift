import Foundation
import XCTest
@testable import MediaDownloads

final class DownloadActivityTests: XCTestCase {
    func testProgressIsItemWeightedAndWaitsForFinalization() throws {
        var first = try DownloadTestFactory.record(status: .completed, bytesDownloaded: 10, totalBytes: 10)
        var second = try DownloadTestFactory.record(
            identity: DownloadTestFactory.imdbIdentity("second"),
            status: .downloading, bytesDownloaded: 100, totalBytes: 100
        )
        first.batchID = "season"
        first.batchTitle = "Season One"
        second.batchID = "season"
        second.batchTitle = "Season One"
        let progress = DownloadActivityProgress(records: [first, second], bytesPerSecond: 10)
        XCTAssertEqual(progress.totalUnitCount, 2_000)
        XCTAssertEqual(progress.completedUnitCount, 1_999)
        XCTAssertEqual(progress.completedCount, 1)
        XCTAssertEqual(progress.displayTitle, second.snapshot.title)
        XCTAssertEqual(progress.currentItemNumber, 2)
        XCTAssertTrue(progress.hasActiveWork)
        XCTAssertFalse(progress.succeeded)
        XCTAssertNil(progress.estimatedTimeRemaining)
        second.status = .completed
        XCTAssertTrue(DownloadActivityProgress(records: [first, second]).succeeded)
    }

    func testUnknownTotalsAndPreparationDoNotInventETA() throws {
        var record = try DownloadTestFactory.record(status: .downloading, bytesDownloaded: 10, totalBytes: nil)
        var progress = DownloadActivityProgress(records: [record], bytesPerSecond: 10)
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertNil(progress.estimatedTimeRemaining)
        record.totalBytes = 100
        progress = DownloadActivityProgress(records: [record], bytesPerSecond: 10)
        XCTAssertEqual(progress.estimatedTimeRemaining, 9)
        XCTAssertNil(DownloadActivityProgress(records: [record], bytesPerSecond: 0).estimatedTimeRemaining)
        record.status = .preparing
        XCTAssertNil(DownloadActivityProgress(records: [record], bytesPerSecond: 10).estimatedTimeRemaining)
        record.status = .paused
        XCTAssertNil(DownloadActivityProgress(records: [record], bytesPerSecond: 10).estimatedTimeRemaining)
    }

    func testLargeKnownTotalsDoNotOverflowETA() throws {
        let records = try (0..<3).map {
            try DownloadTestFactory.record(
                identity: DownloadTestFactory.imdbIdentity("item-\($0)"),
                status: .downloading, bytesDownloaded: 0, totalBytes: Int64.max
            )
        }
        let progress = DownloadActivityProgress(records: records, bytesPerSecond: Int64.max)
        XCTAssertEqual(progress.estimatedTimeRemaining, 3)
    }

    func testRenditionProgressIncludesMeasuredPreparationWithoutInventingETA() throws {
        var record = try DownloadTestFactory.record(status: .preparing, totalBytes: 100)
        record.quality = .hd720
        record.preparationFraction = 0.5
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 250)
        XCTAssertNil(DownloadActivityProgress(records: [record], bytesPerSecond: 10).estimatedTimeRemaining)
        record.preparationFraction = .nan
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 0)
        record.preparationFraction = 1
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 500)
        record.status = .downloading
        record.bytesDownloaded = 20
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 600)
        record.bytesDownloaded = 100
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 999)
        record.status = .completed
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 1_000)
        record.status = .queued
        record.bytesDownloaded = 0
        XCTAssertEqual(DownloadActivityProgress(records: [record]).completedUnitCount, 0)
        XCTAssertNil(DownloadActivityProgress(records: [record], bytesPerSecond: 10).estimatedTimeRemaining)
    }

    func testRemovingEveryItemDoesNotReportSuccessfulCompletion() {
        let progress = DownloadActivityProgress(records: [])
        XCTAssertEqual(progress.status, .paused)
        XCTAssertFalse(progress.succeeded)
        XCTAssertEqual(progress.totalUnitCount, 0)
    }

    func testRevokedLeaseCannotBecomeValidAgain() {
        let lease = DownloadBackgroundExecutionLease()
        XCTAssertTrue(lease.isValid)
        lease.invalidate()
        lease.invalidate()
        XCTAssertFalse(lease.isValid)
        XCTAssertTrue(DownloadBackgroundExecutionLease().isValid)
    }

    func testBatchKeepsEpisodeProgressSeparateFromOverallProgress() throws {
        var records = try (1...10).map { index in
            var record = try DownloadTestFactory.record(
                identity: DownloadTestFactory.imdbIdentity("episode-\(index)"),
                status: index < 4 ? .completed : (index == 4 ? .downloading : .queued),
                bytesDownloaded: index < 4 ? 100 : (index == 4 ? 62 : 0), totalBytes: 100
            )
            record.snapshot.kind = .episode
            record.snapshot.seasonNumber = 1
            record.snapshot.episodeNumber = index
            record.batchID = "season"
            record.batchTitle = "Example Show"
            return record
        }
        let progress = DownloadActivityProgress(records: records)
        XCTAssertEqual(progress.completedUnitCount, 3_620)
        XCTAssertEqual(progress.totalUnitCount, 10_000)
        XCTAssertEqual(progress.completedCount, 3)
        XCTAssertEqual(progress.activeItemCount, 1)
        XCTAssertEqual(progress.currentItemNumber, 4)
        XCTAssertEqual(progress.currentItem?.seasonNumber, 1)
        XCTAssertEqual(progress.currentItem?.episodeNumber, 4)
        XCTAssertEqual(progress.currentItem?.fractionCompleted, 0.62)
        XCTAssertEqual(progress.currentItem?.phase, .downloading)
        records.reverse()
        XCTAssertEqual(DownloadActivityProgress(records: records), progress)
    }

    func testCurrentItemDistinguishesPreparationTransferAndFinalization() throws {
        var record = try DownloadTestFactory.record(status: .preparing, totalBytes: 100)
        record.quality = .hd720
        record.preparationFraction = 0.4
        var progress = DownloadActivityProgress(records: [record])
        XCTAssertEqual(progress.currentItem?.phase, .preparing)
        XCTAssertEqual(progress.currentItem?.fractionCompleted, 0.4)
        XCTAssertEqual(progress.completedUnitCount, 200)
        record.preparationFraction = .nan
        XCTAssertNil(DownloadActivityProgress(records: [record]).currentItem?.fractionCompleted)
        record.status = .downloading
        record.bytesDownloaded = 40
        progress = DownloadActivityProgress(records: [record])
        XCTAssertEqual(progress.currentItem?.phase, .downloading)
        XCTAssertEqual(progress.currentItem?.fractionCompleted, 0.4)
        XCTAssertEqual(progress.completedUnitCount, 700)
        record.bytesDownloaded = 100
        progress = DownloadActivityProgress(records: [record])
        XCTAssertEqual(progress.currentItem?.phase, .finishing)
        XCTAssertNil(progress.currentItem?.fractionCompleted)
        XCTAssertEqual(progress.completedCount, 0)
        record.status = .completed
        progress = DownloadActivityProgress(records: [record])
        XCTAssertNil(progress.currentItem)
        XCTAssertEqual(progress.completedCount, 1)
    }

    func testParallelWorkDoesNotPretendThereIsOneCurrentItem() throws {
        let first = try DownloadTestFactory.record(status: .downloading, totalBytes: 100)
        var second = try DownloadTestFactory.record(
            identity: DownloadTestFactory.imdbIdentity("second"), status: .preparing
        )
        var progress = DownloadActivityProgress(records: [first, second])
        XCTAssertEqual(progress.activeItemCount, 2)
        XCTAssertNil(progress.currentItem)
        XCTAssertNil(progress.currentItemNumber)
        second.status = .queued
        progress = DownloadActivityProgress(records: [second, first])
        XCTAssertEqual(progress.activeItemCount, 1)
        XCTAssertEqual(progress.currentItemNumber, 1)
        XCTAssertEqual(progress.currentItem?.title, first.snapshot.title)
    }

    func testCurrentMediaTitleDoesNotDependOnMixedQueueOrderOrCompletedItems() throws {
        var first = try DownloadTestFactory.record(status: .completed)
        first.snapshot.title = "Earlier movie"
        var second = try DownloadTestFactory.record(
            identity: DownloadTestFactory.imdbIdentity("second"), status: .downloading
        )
        second.snapshot.title = "Spider-Man: Far From Home"
        var third = try DownloadTestFactory.record(
            identity: DownloadTestFactory.imdbIdentity("third"), status: .queued
        )
        third.snapshot.title = "Later movie"
        let progress = DownloadActivityProgress(records: [third, second, first])
        XCTAssertEqual(progress.displayTitle, "Spider-Man: Far From Home")
        XCTAssertEqual(progress.currentItemNumber, 2)
        XCTAssertEqual(progress, DownloadActivityProgress(records: [first, third, second]))
    }

    func testEpisodeTitleUsesPinnedSeriesThenBatchThenEpisodeWithoutBlankTitles() throws {
        var record = try DownloadTestFactory.record(status: .downloading)
        record.snapshot.kind = .episode
        record.snapshot.title = "Episode title"
        record.snapshot.seriesTitle = "Your Honor"
        record.batchTitle = "Season One"
        XCTAssertEqual(DownloadActivityProgress(records: [record]).displayTitle, "Your Honor")
        record.snapshot.seriesTitle = " \n"
        XCTAssertEqual(DownloadActivityProgress(records: [record]).displayTitle, "Season One")
        record.batchTitle = nil
        XCTAssertEqual(DownloadActivityProgress(records: [record]).displayTitle, "Episode title")
        record.snapshot.title = ""
        XCTAssertNil(DownloadActivityProgress(records: [record]).displayTitle)
    }

    func testPausedOrFailedPeersDoNotPretendThereIsASequentialPosition() throws {
        let current = try DownloadTestFactory.record(status: .downloading)
        var peer = try DownloadTestFactory.record(
            identity: DownloadTestFactory.imdbIdentity("peer"), status: .paused
        )
        for status in [DownloadStatus.paused, .failed] {
            peer.status = status
            let progress = DownloadActivityProgress(records: [current, peer])
            XCTAssertNil(progress.currentItemNumber)
            XCTAssertEqual(progress.activeItemCount, 1)
            XCTAssertEqual(progress.completedCount, 0)
            XCTAssertEqual(progress.displayTitle, current.snapshot.title)
        }
    }

    func testUnknownSizeAndInactiveRecordsDoNotInventCurrentProgress() throws {
        var record = try DownloadTestFactory.record(status: .downloading, totalBytes: nil)
        XCTAssertEqual(DownloadActivityProgress(records: [record]).currentItem?.phase, .downloading)
        XCTAssertNil(DownloadActivityProgress(records: [record]).currentItem?.fractionCompleted)
        for status in [DownloadStatus.queued, .paused, .failed, .completed] {
            record.status = status
            let progress = DownloadActivityProgress(records: [record])
            XCTAssertEqual(progress.activeItemCount, 0)
            XCTAssertNil(progress.currentItem)
            XCTAssertNil(progress.currentItemNumber)
        }
    }
}

final class DownloadNotificationOutboxTests: XCTestCase {
    func testCompletionAndOutboxSurviveRegistryRelaunchTogether() async throws {
        let store = InMemoryDownloadedMediaStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try DownloadTestFactory.record(status: .downloading)
        try await registry.beginDownload(record)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let reloaded = DownloadedMediaRegistry(store: store)
        let notices = await reloaded.pendingNotifications()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, .completed)
        let completed = await reloaded.record(forKey: record.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        let notice = try XCTUnwrap(notices.first)
        try await reloaded.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let repeated = await reloaded.pendingNotifications()
        XCTAssertEqual(repeated, notices)
        try await reloaded.acknowledgeNotification(notice.id)
        let afterAcknowledgement = DownloadedMediaRegistry(store: store)
        let pending = await afterAcknowledgement.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testBatchNotifiesOnlyAfterEveryExpectedItemCompletes() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var records = try (0..<3).map {
            try DownloadTestFactory.record(
                identity: DownloadTestFactory.imdbIdentity("episode-\($0)"), status: .queued
            )
        }
        for index in records.indices {
            records[index].batchID = "show"
            records[index].batchExpectedCount = 3
            records[index].batchTitle = "Example Show"
        }
        try await registry.beginDownloads(Array(records.prefix(2)))
        for record in records.prefix(2) {
            try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        }
        let premature = await registry.pendingNotifications()
        XCTAssertTrue(premature.isEmpty)
        try await registry.beginDownload(records[2])
        try await registry.markCompleted(identityKey: records[2].identityKey, totalBytes: 100)
        let notices = await registry.pendingNotifications()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, .batchCompleted)
        XCTAssertEqual(notices.first?.title, "Example Show")
    }

    func testLegacyCompletedDownloadsDoNotGenerateUpgradeNotifications() async throws {
        let record = try DownloadTestFactory.record(status: .completed)
        let state = DownloadedMediaRegistryState(records: [record.identityKey: record])
        let encoded = try JSONEncoder().encode(state)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "pendingNotifications")
        let decoded = try JSONDecoder().decode(
            DownloadedMediaRegistryState.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertTrue(decoded.pendingNotifications.isEmpty)
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore(decoded))
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let notices = await registry.pendingNotifications()
        XCTAssertTrue(notices.isEmpty)
    }

    func testRetryReplacementAndRemovalInvalidateStaleNotices() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var record = try DownloadTestFactory.record(status: .downloading)
        try await registry.beginDownload(record)
        try await registry.setStatus(identityKey: record.identityKey, .failed, failureReason: "Unavailable")
        let failedNotices = await registry.pendingNotifications()
        let failed = try XCTUnwrap(failedNotices.first)
        try await registry.setStatus(identityKey: record.identityKey, .queued)
        let failureStillCurrent = await registry.notificationIsCurrent(failed)
        XCTAssertFalse(failureStillCurrent)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let completedNotices = await registry.pendingNotifications()
        let completed = try XCTUnwrap(completedNotices.last)
        record.createdAt = record.createdAt.addingTimeInterval(1)
        try await registry.beginQualityReplacement(record)
        let completionStillCurrent = await registry.notificationIsCurrent(completed)
        XCTAssertFalse(completionStillCurrent)
        try await registry.remove(identityKey: record.identityKey)
        let noticeAfterRemoval = await registry.notificationIsCurrent(completed)
        XCTAssertFalse(noticeAfterRemoval)
    }

    func testFailedPersistenceDoesNotPublishCompletionOrOutbox() async throws {
        let store = FailingDownloadNotificationStore()
        let registry = DownloadedMediaRegistry(store: store)
        let record = try DownloadTestFactory.record(status: .downloading)
        try await registry.beginDownload(record)
        store.failNextSave()
        do {
            try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
            XCTFail("Completion must fail when its durable commit fails")
        } catch is FailingDownloadNotificationStore.Failure {}
        let retained = await registry.record(forKey: record.identityKey)
        let notices = await registry.pendingNotifications()
        XCTAssertEqual(retained?.status, .downloading)
        XCTAssertTrue(notices.isEmpty)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let retried = await registry.pendingNotifications()
        XCTAssertEqual(retried.count, 1)
    }
}

private final class FailingDownloadNotificationStore: DownloadedMediaStoring, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var state = DownloadedMediaRegistryState.empty
    private var fails = false
    func failNextSave() { lock.withLock { fails = true } }
    func load() -> DownloadedMediaRegistryState { lock.withLock { state } }
    func save(_ state: DownloadedMediaRegistryState) throws {
        try lock.withLock {
            if fails {
                fails = false
                throw Failure()
            }
            self.state = state
        }
    }
}
