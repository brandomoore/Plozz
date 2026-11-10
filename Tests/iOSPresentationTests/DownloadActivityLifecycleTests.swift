#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads
import MediaTransportCore
import UserNotifications
import XCTest
@testable import AppShelliOS

@MainActor
final class DownloadActivityLifecycleTests: XCTestCase {
    func testRTLActivityDetailsKeepEpisodeCodesAndProgressInSeparateDirectionalRuns() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native continued-processing task requires iOS 26.") }
        var record = downloadActivityRecord()
        record.bytesDownloaded = 50
        record.snapshot = .init(title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 4)
        let progress = DownloadActivityProgress(records: [record], bytesPerSecond: 0)
        for language in ["ar", "he", "fa"] {
            let locale = Locale(identifier: language)
            for text in [
                PlozziOSSystemDownloadActivityScheduler.title(for: progress, locale: locale),
                PlozziOSSystemDownloadActivityScheduler.subtitle(for: progress, locale: locale)
            ] {
                XCTAssertTrue(text.hasPrefix("\u{2068}"), text)
                XCTAssertTrue(text.contains("\u{2069} · \u{2068}"), text)
                XCTAssertTrue(text.hasSuffix("\u{2069}"), text)
            }
        }
    }

    func testNativeSubtitleShowsEpisodeAndWholeBatchProgress() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native continued-processing task requires iOS 26.") }
        let records = (1...10).map { index in
            var record = downloadActivityRecord(id: "episode-\(index)")
            record.status = index < 4 ? .completed : (index == 4 ? .downloading : .queued)
            record.bytesDownloaded = index < 4 ? 100 : (index == 4 ? 62 : 0)
            record.totalBytes = 100
            record.batchID = "season"
            record.batchTitle = "Example Show"
            record.snapshot.kind = .episode
            record.snapshot.seasonNumber = 1
            record.snapshot.episodeNumber = index
            return record
        }
        let progress = DownloadActivityProgress(records: records)
        XCTAssertEqual(progress.displayTitle, "Example Show")
        XCTAssertEqual(progress.completedUnitCount, 3_620)
        XCTAssertEqual(
            PlozziOSSystemDownloadActivityScheduler.title(for: progress, locale: Locale(identifier: "en")),
            "Example Show · S1 · E4"
        )
        XCTAssertEqual(
            PlozziOSSystemDownloadActivityScheduler.subtitle(for: progress, locale: Locale(identifier: "en")),
            "Downloading 4 of 10 · 62% · Cancel to pause"
        )
    }

    func testMixedMovieQueueKeepsTitleSeparateFromOneBasedProgress() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native continued-processing task requires iOS 26.") }
        var first = downloadActivityRecord(id: "first")
        first.snapshot = .init(title: "Spider-Man: Far From Home", kind: .movie)
        first.bytesDownloaded = 53
        var second = downloadActivityRecord(id: "second")
        second.status = .queued
        second.snapshot = .init(title: "Another movie", kind: .movie)
        let locale = Locale(identifier: "en")
        func assertPresentation(_ title: String, _ subtitle: String) {
            let progress = DownloadActivityProgress(records: [second, first])
            XCTAssertEqual(PlozziOSSystemDownloadActivityScheduler.title(for: progress, locale: locale), title)
            let expected = progress.hasActiveWork ? "\(subtitle) · Cancel to pause" : subtitle
            XCTAssertEqual(PlozziOSSystemDownloadActivityScheduler.subtitle(for: progress, locale: locale), expected)
        }
        assertPresentation("Spider-Man: Far From Home", "Downloading 1 of 2 · 53%")
        first.status = .preparing
        first.preparationFraction = 0.4
        assertPresentation("Spider-Man: Far From Home", "Preparing 1 of 2 · 40%")
        first.preparationFraction = nil
        assertPresentation("Spider-Man: Far From Home", "Preparing 1 of 2")
        first.status = .downloading
        first.totalBytes = nil
        assertPresentation("Spider-Man: Far From Home", "Downloading 1 of 2")
        first.totalBytes = 100
        first.bytesDownloaded = 100
        assertPresentation("Spider-Man: Far From Home", "Finishing 1 of 2")
        first.status = .completed
        second.status = .downloading
        second.bytesDownloaded = 25
        assertPresentation("Another movie", "Downloading 2 of 2 · 25%")
        second.status = .completed
        assertPresentation("Downloads", "Completed: 2 of 2")
    }

    func testNativeSubtitleDoesNotConfuseTransferAndFinalization() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native continued-processing task requires iOS 26.") }
        var record = downloadActivityRecord()
        record.snapshot.kind = .episode
        record.snapshot.seasonNumber = 1
        record.snapshot.episodeNumber = 4
        func subtitle() -> String {
            PlozziOSSystemDownloadActivityScheduler.subtitle(
                for: DownloadActivityProgress(records: [record]), locale: Locale(identifier: "en")
            )
        }
        record.status = .preparing
        record.preparationFraction = 0.4
        XCTAssertEqual(subtitle(), "Preparing 40% · Cancel to pause")
        record.preparationFraction = nil
        XCTAssertEqual(subtitle(), "Preparing Download · Cancel to pause")
        record.status = .downloading
        record.totalBytes = 1_000
        record.bytesDownloaded = 999
        XCTAssertEqual(subtitle(), "Downloading · 99% · Cancel to pause")
        record.bytesDownloaded = 1_000
        XCTAssertEqual(subtitle(), "Finishing · Cancel to pause")
        record.totalBytes = nil
        XCTAssertEqual(subtitle(), "Downloading · Cancel to pause")
        record.snapshot.seasonNumber = nil
        XCTAssertEqual(subtitle(), "Downloading · Cancel to pause")
        XCTAssertEqual(
            PlozziOSSystemDownloadActivityScheduler.title(
                for: DownloadActivityProgress(records: [record]), locale: Locale(identifier: "en")
            ),
            "episode · E4"
        )
        record.snapshot.episodeNumber = nil
        XCTAssertEqual(subtitle(), "Downloading · Cancel to pause")
        record.bytesDownloaded = 40
        record.totalBytes = 100
        XCTAssertEqual(subtitle(), "Downloading · 40% · Cancel to pause")
    }

    func testNativeSubtitleReportsParallelAndTerminalQueueStates() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native continued-processing task requires iOS 26.") }
        var first = downloadActivityRecord()
        var second = downloadActivityRecord(id: "second")
        first.status = .downloading
        second.status = .preparing
        func subtitle() -> String {
            PlozziOSSystemDownloadActivityScheduler.subtitle(
                for: DownloadActivityProgress(records: [first, second]), locale: Locale(identifier: "en")
            )
        }
        XCTAssertEqual(subtitle(), "Completed: 0 of 2 · Cancel to pause")
        XCTAssertEqual(
            PlozziOSSystemDownloadActivityScheduler.title(
                for: DownloadActivityProgress(records: [first, second]), locale: Locale(identifier: "en")
            ),
            "Active downloads: 2"
        )
        first.batchID = "show"
        second.batchID = "show"
        first.batchTitle = "Example Show"
        second.batchTitle = "Example Show"
        XCTAssertEqual(subtitle(), "Active: 2 · Completed: 0 of 2 · Cancel to pause")
        XCTAssertEqual(
            PlozziOSSystemDownloadActivityScheduler.title(
                for: DownloadActivityProgress(records: [first, second]), locale: Locale(identifier: "en")
            ),
            "Example Show"
        )
        first.status = .queued
        second.status = .queued
        XCTAssertEqual(subtitle(), "Queued · Completed: 0 of 2 · Cancel to pause")
        first.status = .completed
        second.status = .paused
        XCTAssertEqual(subtitle(), "Download Paused · Completed: 1 of 2")
        second.status = .failed
        XCTAssertEqual(subtitle(), "Download Failed · Completed: 1 of 2")
        second.status = .completed
        XCTAssertEqual(subtitle(), "Completed: 2 of 2")
        second.status = .downloading
        second.bytesDownloaded = 53
        first.status = .paused
        XCTAssertEqual(subtitle(), "Downloading · 53% · Completed: 0 of 2 · Cancel to pause")
        first.status = .failed
        XCTAssertEqual(subtitle(), "Downloading · 53% · Completed: 0 of 2 · Cancel to pause")
    }

    func testCurrentEpisodeAdvancesWithinTheSameActivityAfterFinalization() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler, beginExecution: { _ in true }, pauseExpiredWork: { _ in }
        )
        var first = downloadActivityRecord()
        var second = downloadActivityRecord(id: "second")
        first.snapshot.kind = .episode
        first.snapshot.episodeNumber = 1
        second.snapshot.kind = .episode
        second.snapshot.episodeNumber = 2
        first.status = .downloading
        second.status = .queued
        await activity.start(records: [first, second])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.updates.isEmpty }
        first.bytesDownloaded = first.totalBytes ?? 100
        activity.update(records: [first, second], bytesPerSecond: 10)
        XCTAssertEqual(task.updates.last?.currentItem?.phase, .finishing)
        XCTAssertEqual(task.updates.last?.completedCount, 0)
        XCTAssertEqual(task.updates.last?.currentItemNumber, 1)
        first.status = .completed
        second.status = .downloading
        second.bytesDownloaded = 62
        activity.update(records: [second, first], bytesPerSecond: 10)
        XCTAssertEqual(task.updates.last?.currentItem?.episodeNumber, 2)
        XCTAssertEqual(task.updates.last?.currentItem?.fractionCompleted, 0.62)
        XCTAssertEqual(task.updates.last?.completedCount, 1)
        XCTAssertEqual(task.updates.last?.currentItemNumber, 2)
        XCTAssertEqual(task.updates.last?.totalCount, 2)
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertTrue(task.completions.isEmpty)
        activity.retire()
    }

    func testSystemActivityReceivesRealHTTPDownloadProgressOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_VERIFY_SYSTEM_DOWNLOAD_ACTIVITY"] == "1" else {
            throw XCTSkip("Opt in on an owned physical iPhone/iPad to exercise system admission.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued-processing admission requires a physical device.")
        #else
        guard let scheduler = PlozziOSDownloadActivity.systemScheduler() else {
            throw XCTSkip("Requires iOS/iPadOS 26 or later.")
        }
        let bytes = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024)
        let server = try IPTVTestHTTPServer { _ in
            .init(data: bytes, delay: .milliseconds(100))
        }
        let url = try await server.start()
        let profile = "activity-test-\(UUID().uuidString)"
        let storage = PlatformDownloadStorageLocator(subdirectory: "PlozzDownloads/\(profile)")
        let directory = try storage.pinnedMediaDirectory()
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = PlozziOSBackgroundHTTPDownloadEngine(
            profileID: profile, registry: registry,
            resolveURL: { _, _, _, _ in
                .init(url: url, expectedDuration: nil, cleanupURL: nil, expectedBytes: Int64(bytes.count))
            }
        )
        let queue = DownloadQueue(
            registry: registry, storage: storage, engine: engine, observer: StaticDownloadNetworkObserver()
        )
        let record = try await queue.enqueue(
            DownloadRequest(
                identity: .external(source: "activity-fixture", value: profile),
                expectedBytes: Int64(bytes.count),
                sourceKind: .managedHTTP,
                managedHTTPSource: .init(provider: .emby, accountID: "fixture", itemID: "fixture"),
                contentType: "application/octet-stream", fileExtension: "bin",
                snapshot: .init(title: "Download activity check", kind: .movie)
            ),
            startImmediately: false
        )
        var wasAdmitted = false
        var observedPartialProgress = false
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { lease in
                wasAdmitted = true
                await queue.setBackgroundExecutionLease(lease)
                await queue.resume(identityKey: record.identityKey)
                return true
            },
            pauseExpiredWork: { _ in await queue.pause(identityKey: record.identityKey) }
        )
        let events = await registry.events()
        let observation = Task {
            for await event in events {
                if case .item(let item) = event {
                    observedPartialProgress = observedPartialProgress
                        || (item.bytesDownloaded > 0 && item.bytesDownloaded < Int64(bytes.count))
                    activity.update(records: [item], bytesPerSecond: 0)
                }
                if Task.isCancelled { return }
            }
        }
        addTeardownBlock {
            await MainActor.run {
                observation.cancel()
                activity.retire()
            }
            await queue.pause(identityKey: record.identityKey)
            await queue.discardPersistentWork(identityKey: record.identityKey)
            await server.stop()
            try FileManager.default.removeItem(at: directory)
        }
        await activity.start(records: [record])
        try await waitForDownloadCondition { wasAdmitted }
        let deadline = Date().addingTimeInterval(30)
        while await registry.record(forKey: record.identityKey)?.status.isActive == true,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(result?.status, .completed)
        XCTAssertTrue(observedPartialProgress)
        XCTAssertEqual(try Data(contentsOf: storage.pinnedFileURL(for: record)), bytes)
        #endif
    }

    func testSubmissionDoesNotGrantExecutionUntilSystemStartsTask() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        var lease: DownloadBackgroundExecutionLease?
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { lease = $0; return true },
            pauseExpiredWork: { _ in XCTFail("No cancellation expected") }
        )
        var record = downloadActivityRecord()
        await activity.start(records: [record])
        XCTAssertFalse(activity.hasExecutionLease)
        XCTAssertEqual(scheduler.submissions.count, 1)
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { activity.hasExecutionLease && !task.updates.isEmpty }
        XCTAssertTrue(lease?.isValid == true)
        record.bytesDownloaded = 100
        activity.update(records: [record], bytesPerSecond: 10)
        XCTAssertEqual(task.updates.last?.completedUnitCount, 999)
        XCTAssertTrue(task.completions.isEmpty)
        record.status = .completed
        activity.update(records: [record], bytesPerSecond: 0)
        try await waitForDownloadCondition { !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [true])
        XCTAssertFalse(lease?.isValid == true)
    }

    func testDeniedSubmissionKeepsNormalPolicyAndDoesNotRetryOnEveryProgressEvent() async {
        let scheduler = DownloadActivitySchedulerStub()
        scheduler.rejects = true
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { _ in XCTFail("Rejected request cannot grant execution"); return false },
            pauseExpiredWork: { _ in XCTFail("Rejected request cannot cancel downloads") }
        )
        let record = downloadActivityRecord()
        for _ in 0..<10 { await activity.start(records: [record]) }
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertFalse(activity.hasExecutionLease)
        activity.allowRetry()
        await activity.start(records: [record])
        XCTAssertEqual(scheduler.submissions.count, 2)
    }

    func testLateStartAfterProfileRetirementCannotStartOrCancelWork() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { _ in XCTFail("Retired profile"); return false },
            pauseExpiredWork: { _ in XCTFail("Retired profile") }
        )
        await activity.start(records: [downloadActivityRecord()])
        activity.retire()
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(activity.hasExecutionLease)
    }

    func testExpirationRevokesLeaseAndPausesOnlyOwnedRecordGenerations() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        var lease: DownloadBackgroundExecutionLease?
        var paused: [String: Date] = [:]
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { lease = $0; return true },
            pauseExpiredWork: { paused = $0 }
        )
        let record = downloadActivityRecord()
        await activity.start(records: [record])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { activity.hasExecutionLease }
        let expiration = try XCTUnwrap(task.expiration)
        await Task.detached { expiration() }.value
        XCTAssertFalse(lease?.isValid == true)
        try await waitForDownloadCondition { !task.completions.isEmpty }
        XCTAssertEqual(paused, [record.identityKey: record.createdAt])
        XCTAssertEqual(task.completions, [false])
    }

    func testExpirationDuringExecutionAdmissionCannotLeaveDownloadsRunning() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        var admission: CheckedContinuation<Bool, Never>?
        var paused = false
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler,
            beginExecution: { _ in await withCheckedContinuation { admission = $0 } },
            pauseExpiredWork: { _ in paused = true }
        )
        await activity.start(records: [downloadActivityRecord()])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { admission != nil }
        task.expiration?()
        admission?.resume(returning: true)
        try await waitForDownloadCondition { paused && !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(activity.hasExecutionLease)
    }

    func testModelActivityExpirationCancelsInitialSubtitlesWithoutHidingFinishedVideo() async throws {
        try await exerciseSubtitleCompletion(hasRemainingVideo: true, expires: true)
    }

    func testLastVideoKeepsBackgroundExecutionUntilSubtitlesAreSaved() async throws {
        try await exerciseSubtitleCompletion(hasRemainingVideo: false, expires: false)
    }

    func testLastVideoSubtitleFailureCompletesActivityAndRetainsWarning() async throws {
        try await exerciseSubtitleCompletion(hasRemainingVideo: false, expires: false, subtitleResult: .unavailable)
    }

    func testLastVideoSubtitleWaitStillHonorsActivityExpiration() async throws {
        try await exerciseSubtitleCompletion(hasRemainingVideo: false, expires: true)
    }

    private func exerciseSubtitleCompletion(
        hasRemainingVideo: Bool, expires: Bool, subtitleResult: DownloadSubtitleStatus = .saved
    ) async throws {
        let previousOffline = OfflineMode.shared.isEnabled
        OfflineMode.shared.setEnabled(false)
        defer { OfflineMode.shared.setEnabled(previousOffline) }
        let bytes = Data(repeating: 0x5a, count: 1_024)
        let server = try IPTVTestHTTPServer { _ in .init(data: bytes) }
        let url = try await server.start()
        let profile = "subtitle-expiration-\(UUID().uuidString)"
        let policyKey = "downloads.policy.\(profile)"
        // Registry iteration order must not let the blocked video starve the subtitle fixture.
        UserDefaults.standard.set(
            try JSONEncoder().encode(DownloadNetworkPolicy(maxConcurrentDownloads: 2)),
            forKey: policyKey
        )
        defer { UserDefaults.standard.removeObject(forKey: policyKey) }
        let storage = PlatformDownloadStorageLocator(subdirectory: "PlozzDownloads/\(profile)")
        let directory = try storage.pinnedMediaDirectory()
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var records = [downloadActivityRecord(id: "first")]
        if hasRemainingVideo { records.append(downloadActivityRecord(id: "next")) }
        for index in records.indices {
            records[index].status = .queued
            records[index].totalBytes = Int64(bytes.count)
            records[index].contentType = "application/octet-stream"
            records[index].managedHTTPSource = .init(
                provider: .emby, accountID: "fixture", itemID: index == 0 ? "first" : "next"
            )
            try await registry.beginDownload(records[index])
        }
        let videoGate = DownloadActivitySavingGate()
        let subtitleGate = DownloadActivitySavingGate()
        let scheduler = DownloadActivitySchedulerStub()
        let model = PlozziOSDownloadsModel(
            profileID: profile, registry: registry, storage: storage,
            networkObserver: StaticDownloadNetworkObserver(),
            networkFileResolver: DownloadActivityUnusedResolver(),
            providerKind: { _ in .emby }, preferredAudioLanguages: { _ in [] },
            activityScheduler: scheduler,
            notificationClient: DownloadNotificationClientStub(authorization: .denied),
            managedURLResolver: { source, _, _, _ in
                try await videoGate.wait()
                if source.itemID == "next" { try await Task.sleep(for: .seconds(30)) }
                return .init(url: url, expectedDuration: nil, cleanupURL: nil, expectedBytes: Int64(bytes.count))
            },
            saveSubtitles: { _, _, _ in
                try await subtitleGate.wait()
                return subtitleResult
            }
        )
        addTeardownBlock {
            await MainActor.run { model.beginProfileTransition() }
            await videoGate.open()
            await subtitleGate.open()
            await model.quiesceForProfileSwitch()
            await server.stop()
            try FileManager.default.removeItem(at: directory)
        }
        try await waitForDownloadCondition { !scheduler.submissions.isEmpty }
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.updates.isEmpty }
        await model.setApplicationActive(false)
        let prematureCompletion = expectation(description: "Activity must remain alive while subtitles are saving")
        prematureCompletion.isInverted = true
        task.onCompletion = { _ in prematureCompletion.fulfill() }
        await videoGate.open()
        try await waitForDownloadCondition { await subtitleGate.entered }
        let finishedVideo = await registry.record(forKey: records[0].identityKey)
        XCTAssertEqual(finishedVideo?.status, .completed)
        await fulfillment(of: [prematureCompletion], timeout: 0.15)
        task.onCompletion = nil
        XCTAssertTrue(task.completions.isEmpty, "Subtitle work must keep even the last video's activity active")
        if expires {
            try XCTUnwrap(task.expiration)()
            try await waitForDownloadCondition { !task.completions.isEmpty }
            XCTAssertEqual(task.completions, [false])
        }
        await subtitleGate.open()
        try await waitForDownloadCondition { await subtitleGate.finished }
        let cancelled = await subtitleGate.wasCancelled
        XCTAssertEqual(cancelled, expires, "Expiration must reach subtitle work even though its video is complete")
        if !expires {
            try await waitForDownloadCondition { !task.completions.isEmpty }
            XCTAssertEqual(task.completions, [true])
        }
        let current = await registry.record(forKey: records[0].identityKey)
        XCTAssertEqual(current?.status, .completed)
        if expires {
            XCTAssertNil(current?.subtitleStatus)
        } else {
            XCTAssertEqual(current?.subtitleStatus, subtitleResult)
            XCTAssertEqual(current?.subtitleWarningID != nil, subtitleResult == .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: storage.pinnedFileURL(for: records[0])), bytes)
        if hasRemainingVideo {
            let remaining = await registry.record(forKey: records[1].identityKey)
            XCTAssertEqual(remaining?.status, .paused)
        }
    }

    func testAdditionalItemsShareOneActivityAndUnknownETAIsCleared() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler, beginExecution: { _ in true }, pauseExpiredWork: { _ in }
        )
        var first = downloadActivityRecord()
        await activity.start(records: [first])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.updates.isEmpty }
        first.bytesDownloaded = 50
        activity.update(records: [first], bytesPerSecond: 10)
        XCTAssertEqual(task.updates.last?.estimatedTimeRemaining, 5)
        var second = downloadActivityRecord(id: "second")
        second.totalBytes = nil
        await activity.start(records: [first, second])
        XCTAssertEqual(scheduler.submissions.count, 1)
        XCTAssertEqual(task.updates.last?.totalCount, 2)
        XCTAssertNil(task.updates.last?.estimatedTimeRemaining)
        activity.retire()
    }

    func testEveryTerminalUpdateKeepsExecutionUntilNotificationsFinish() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        var notificationDelivery: CheckedContinuation<Void, Never>?
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler, beginExecution: { _ in true }, pauseExpiredWork: { _ in },
            beforeCompletion: { _ in
                await withCheckedContinuation { notificationDelivery = $0 }
            }
        )
        defer { notificationDelivery?.resume(); activity.retire() }
        var record = downloadActivityRecord()
        await activity.start(records: [record])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.updates.isEmpty }
        record.status = .completed
        activity.update(records: [record], bytesPerSecond: 0)
        try await waitForDownloadCondition { notificationDelivery != nil }
        activity.update(records: [record], bytesPerSecond: 0)
        XCTAssertTrue(activity.hasExecutionLease)
        XCTAssertTrue(task.completions.isEmpty)
        XCTAssertNotEqual(task.updates.last?.status, .completed)
        notificationDelivery?.resume()
        notificationDelivery = nil
        try await waitForDownloadCondition { !task.completions.isEmpty }
        XCTAssertEqual(task.completions, [true])
        XCTAssertFalse(activity.hasExecutionLease)
    }

    func testNewWorkDuringNotificationDeliveryKeepsTheExistingActivity() async throws {
        let scheduler = DownloadActivitySchedulerStub()
        var notificationDelivery: CheckedContinuation<Void, Never>?
        var deliveryFinished = false
        let activity = PlozziOSDownloadActivity(
            scheduler: scheduler, beginExecution: { _ in true }, pauseExpiredWork: { _ in },
            beforeCompletion: { _ in
                await withCheckedContinuation { notificationDelivery = $0 }
                deliveryFinished = true
            }
        )
        defer { notificationDelivery?.resume(); activity.retire() }
        var record = downloadActivityRecord()
        await activity.start(records: [record])
        let task = DownloadActivityTaskStub()
        scheduler.launch(task)
        try await waitForDownloadCondition { !task.updates.isEmpty }
        record.status = .completed
        activity.update(records: [record], bytesPerSecond: 0)
        try await waitForDownloadCondition { notificationDelivery != nil }
        await activity.start(records: [record, downloadActivityRecord(id: "next")])
        notificationDelivery?.resume()
        notificationDelivery = nil
        try await waitForDownloadCondition { deliveryFinished }
        XCTAssertTrue(activity.hasExecutionLease)
        XCTAssertTrue(task.completions.isEmpty)
        XCTAssertEqual(scheduler.submissions.count, 1)
    }

    func testWorkCompletedDuringFinalizationWaitsForItsOwnPendingSubtitles() async throws {
        for replacesGeneration in [false, true] {
            let scheduler = DownloadActivitySchedulerStub()
            var pendingWork: CheckedContinuation<Void, Never>?
            var prepared: [[String: Date]] = []
            let activity = PlozziOSDownloadActivity(
                scheduler: scheduler, beginExecution: { _ in true }, pauseExpiredWork: { _ in },
                beforeCompletion: { tracked in
                    prepared.append(tracked)
                    await withCheckedContinuation { pendingWork = $0 }
                }
            )
            defer { pendingWork?.resume(); activity.retire() }
            var first = downloadActivityRecord()
            await activity.start(records: [first])
            let task = DownloadActivityTaskStub()
            scheduler.launch(task)
            try await waitForDownloadCondition { !task.updates.isEmpty }
            first.status = .completed
            activity.update(records: [first], bytesPerSecond: 0)
            try await waitForDownloadCondition { pendingWork != nil }
            XCTAssertEqual(prepared, [[first.identityKey: first.createdAt]])

            var next = downloadActivityRecord(id: "next")
            if replacesGeneration {
                next = first
                next.status = .downloading
                next.createdAt = first.createdAt.addingTimeInterval(1)
            }
            await activity.start(records: replacesGeneration ? [next] : [first, next])
            next.status = .completed
            activity.update(records: replacesGeneration ? [next] : [first, next], bytesPerSecond: 0)
            pendingWork?.resume()
            pendingWork = nil
            try await waitForDownloadCondition { pendingWork != nil || !task.completions.isEmpty }
            XCTAssertEqual(prepared.count, 2, "Newly completed work needs its own finalization pass")
            XCTAssertEqual(prepared.last?[next.identityKey], next.createdAt)
            XCTAssertTrue(activity.hasExecutionLease)
            XCTAssertTrue(task.completions.isEmpty)
            pendingWork?.resume()
            pendingWork = nil
            try await waitForDownloadCondition { !task.completions.isEmpty }
            XCTAssertEqual(task.completions, [true])
            XCTAssertEqual(scheduler.submissions.count, 1)
        }
    }
}

@MainActor
final class DownloadNotificationDeliveryTests: XCTestCase {
    func testBatchCompletionPayloadPreservesTheProfileAndBatchRatherThanOnlyTheLastEpisode() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var records = [downloadActivityRecord(id: "first"), downloadActivityRecord(id: "last")]
        for index in records.indices {
            records[index].batchID = "season-batch"
            records[index].batchKind = .season
            records[index].batchTitle = "Show"
            records[index].batchExpectedCount = 2
            try await registry.beginDownload(records[index])
        }
        for record in records {
            try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        }
        let client = DownloadNotificationClientStub()
        let notifications = PlozziOSDownloadNotifications(profileID: "batch-profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        let target = try XCTUnwrap(PlozziOSDownloadNotificationTarget(userInfo: request.content.userInfo))
        XCTAssertEqual(target.profileID, "batch-profile")
        XCTAssertEqual(target.batchID, "season-batch")
        XCTAssertEqual(target.identityKey, records[1].identityKey)
        XCTAssertEqual(target.recordCreatedAt, records[1].createdAt)
    }

    func testColdDeliveryDoesNotRequireAVisibleDownloadsViewAndDoesNotRepeat() async throws {
        let store = InMemoryDownloadedMediaStore()
        let original = DownloadedMediaRegistry(store: store)
        let record = downloadActivityRecord()
        try await original.beginDownload(record)
        try await original.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let registry = DownloadedMediaRegistry(store: store)
        let client = DownloadNotificationClientStub()
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        await notifications.deliverPending()
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.requests[0].identifier.hasPrefix("plozz.download."))
        let target = try XCTUnwrap(PlozziOSDownloadNotificationTarget(userInfo: client.requests[0].content.userInfo))
        XCTAssertEqual(target.profileID, "profile")
        XCTAssertEqual(target.identityKey, record.identityKey)
        XCTAssertEqual(target.recordCreatedAt, record.createdAt)
        XCTAssertNil(target.batchID)
        let pending = await registry.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testSavedOptOutAndDeniedPermissionSuppressCompletion() async throws {
        for optedOut in [true, false] {
            let registry = try await completedRegistry()
            let client = DownloadNotificationClientStub(authorization: optedOut ? .authorized : .denied)
            var preferences = PlozziOSDownloadPreferences.default
            preferences.notifiesOnStandaloneCompletion = !optedOut
            let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { preferences }
            await notifications.deliverPending()
            XCTAssertTrue(client.requests.isEmpty)
            let pending = await registry.pendingNotifications()
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testCompletionWaitsForFirstPermissionDecision() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub(authorization: .notDetermined)
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        XCTAssertTrue(client.requests.isEmpty)
        let waiting = await registry.pendingNotifications()
        XCTAssertEqual(waiting.count, 1)
        await notifications.requestPermissionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testDeliveryFailureRetainsOutboxAndSuccessfulRetryUsesStableIdentifier() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub()
        client.failsNextAdd = true
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        let retained = await registry.pendingNotifications()
        XCTAssertEqual(retained.count, 1)
        await notifications.deliverPending()
        XCTAssertEqual(client.attemptedIdentifiers.count, 2)
        XCTAssertEqual(Set(client.attemptedIdentifiers).count, 1)
        XCTAssertEqual(client.requests.count, 1)
    }

    func testAlreadyDeliveredOutboxReplayIsAcknowledgedWithoutAnotherAlert() async throws {
        let registry = try await completedRegistry()
        let pending = await registry.pendingNotifications()
        let notice = try XCTUnwrap(pending.first)
        let client = DownloadNotificationClientStub()
        client.existing = ["plozz.download.\(notice.id.uuidString)"]
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        XCTAssertTrue(client.requests.isEmpty)
        let remaining = await registry.pendingNotifications()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testConcurrentDrainsWaitForNotificationSchedulingBeforeReturning() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub()
        var releaseDelivery: CheckedContinuation<Void, Never>?
        client.beforeAdd = {
            await withCheckedContinuation { releaseDelivery = $0 }
        }
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        let first = Task { await notifications.deliverPending() }
        defer { releaseDelivery?.resume() }
        try await waitForDownloadCondition { releaseDelivery != nil }
        var secondStarted = false
        var secondFinished = false
        let second = Task {
            secondStarted = true
            await notifications.deliverPending()
            secondFinished = true
        }
        try await waitForDownloadCondition { secondStarted }
        XCTAssertFalse(secondFinished)
        releaseDelivery?.resume()
        releaseDelivery = nil
        await first.value
        await second.value
        XCTAssertTrue(secondFinished)
        XCTAssertEqual(client.requests.count, 1)
        let pending = await registry.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRemovedCompletionIsNotDeliveredAfterAuthorizationLookup() async throws {
        let registry = try await completedRegistry()
        let record = downloadActivityRecord()
        let client = DownloadNotificationClientStub()
        client.beforeAuthorization = {
            do { try await registry.remove(identityKey: record.identityKey) }
            catch { XCTFail("Could not remove completed record: \(error)") }
        }
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        await notifications.deliverPending()
        XCTAssertTrue(client.requests.isEmpty)
        let pending = await registry.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRetiredProfileDoesNotDeliverAnotherProfilesOutbox() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub()
        let notifications = PlozziOSDownloadNotifications(profileID: "profile", registry: registry, client: client) { .default }
        notifications.retire()
        await notifications.deliverPending()
        await notifications.requestPermissionIfNeeded()
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(client.permissionRequests, 0)
        let retained = await registry.pendingNotifications()
        XCTAssertEqual(retained.count, 1)
    }

    func testSavedNotificationPreferencesAreNotChangedByNewDefaults() throws {
        let name = "download-activity-preferences-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = PlozziOSDownloadPreferences(
            asksBeforeDownloading: false, notifiesOnStandaloneCompletion: false,
            notifiesOnBatchCompletion: false, notifiesOnFailure: true
        )
        defaults.set(try JSONEncoder().encode(previous), forKey: "preferences")
        let loaded = PlozziOSDownloadPreferences.load(key: "preferences", defaults: defaults)
        XCTAssertFalse(loaded.notifiesOnStandaloneCompletion)
        XCTAssertFalse(loaded.notifiesOnBatchCompletion)
        XCTAssertTrue(loaded.notifiesOnFailure)
        XCTAssertTrue(PlozziOSDownloadPreferences.load(key: "new-profile", defaults: defaults).notifiesOnStandaloneCompletion)
        defaults.set(Data("invalid".utf8), forKey: "broken")
        XCTAssertFalse(PlozziOSDownloadPreferences.load(key: "broken", defaults: defaults).notificationsEnabled)
    }

    private func completedRegistry() async throws -> DownloadedMediaRegistry {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let record = downloadActivityRecord()
        try await registry.beginDownload(record)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        return registry
    }
}

@MainActor
final class DownloadNotificationClientStub: PlozziOSDownloadNotificationClient {
    struct Failure: Error {}
    var authorization: UNAuthorizationStatus
    var existing: Set<String> = []
    var requests: [UNNotificationRequest] = []
    var attemptedIdentifiers: [String] = []
    var permissionRequests = 0
    var failsNextAdd = false
    var beforeAdd: (() async -> Void)?
    var beforeAuthorization: (() async -> Void)?

    init(authorization: UNAuthorizationStatus = .authorized) { self.authorization = authorization }
    func authorizationStatus() async -> UNAuthorizationStatus {
        await beforeAuthorization?()
        return authorization
    }
    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        authorization = .authorized
        return true
    }
    func existingIdentifiers() async -> Set<String> { existing }
    func add(_ request: UNNotificationRequest) async throws {
        attemptedIdentifiers.append(request.identifier)
        await beforeAdd?()
        if failsNextAdd {
            failsNextAdd = false
            throw Failure()
        }
        requests.append(request)
        existing.insert(request.identifier)
    }
}

@MainActor
private final class DownloadActivityTaskStub: PlozziOSDownloadActivityTask {
    var expiration: (@Sendable () -> Void)?
    var updates: [DownloadActivityProgress] = []
    var completions: [Bool] = []
    var onCompletion: ((Bool) -> Void)?
    func onExpiration(_ handler: @escaping @Sendable () -> Void) { expiration = handler }
    func update(_ progress: DownloadActivityProgress) { updates.append(progress) }
    func complete(success: Bool) {
        completions.append(success)
        onCompletion?(success)
    }
}

@MainActor
private final class DownloadActivitySchedulerStub: PlozziOSDownloadActivityScheduling {
    struct Failure: Error {}
    var rejects = false
    var submissions: [String] = []
    var cancelled: [String] = []
    var onStart: (@MainActor @Sendable (any PlozziOSDownloadActivityTask) -> Void)?
    func submit(
        identifier: String, progress: DownloadActivityProgress,
        onStart: @escaping @MainActor @Sendable (any PlozziOSDownloadActivityTask) -> Void
    ) async throws {
        submissions.append(identifier)
        self.onStart = onStart
        if rejects { throw Failure() }
    }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func launch(_ task: any PlozziOSDownloadActivityTask) { onStart?(task) }
}

private actor DownloadActivitySavingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    private(set) var finished = false
    private(set) var wasCancelled = false

    func wait() async throws {
        entered = true
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        wasCancelled = Task.isCancelled
        finished = true
        try Task.checkCancellation()
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct DownloadActivityUnusedResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw CancellationError()
    }
}

private func downloadActivityRecord(id: String = "episode") -> DownloadedMediaRecord {
    DownloadedMediaRecord(
        identity: .external(source: "example", value: id),
        sourceKind: .managedHTTP, status: .downloading, localFileName: "media.mkv",
        bytesDownloaded: 0, totalBytes: 100,
        snapshot: .init(title: id, kind: .episode)
    )
}

@MainActor
private func waitForDownloadCondition(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let satisfied = await predicate()
    XCTAssertTrue(satisfied)
}
#endif
