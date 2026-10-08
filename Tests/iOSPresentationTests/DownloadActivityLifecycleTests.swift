#if os(iOS)
import CoreModels
import Foundation
import MediaDownloads
import UserNotifications
import XCTest
@testable import AppShelliOS

@MainActor
final class DownloadActivityLifecycleTests: XCTestCase {
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
            resolveURL: { _, _, _ in
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
            beforeCompletion: {
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
            beforeCompletion: {
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
}

@MainActor
final class DownloadNotificationDeliveryTests: XCTestCase {
    func testColdDeliveryDoesNotRequireAVisibleDownloadsViewAndDoesNotRepeat() async throws {
        let store = InMemoryDownloadedMediaStore()
        let original = DownloadedMediaRegistry(store: store)
        let record = downloadActivityRecord()
        try await original.beginDownload(record)
        try await original.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        let registry = DownloadedMediaRegistry(store: store)
        let client = DownloadNotificationClientStub()
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
        await notifications.deliverPending()
        await notifications.deliverPending()
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.requests[0].identifier.hasPrefix("plozz.download."))
        let pending = await registry.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testSavedOptOutAndDeniedPermissionSuppressCompletion() async throws {
        for optedOut in [true, false] {
            let registry = try await completedRegistry()
            let client = DownloadNotificationClientStub(authorization: optedOut ? .authorized : .denied)
            var preferences = PlozziOSDownloadPreferences.default
            preferences.notifiesOnStandaloneCompletion = !optedOut
            let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { preferences }
            await notifications.deliverPending()
            XCTAssertTrue(client.requests.isEmpty)
            let pending = await registry.pendingNotifications()
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testCompletionWaitsForFirstPermissionDecision() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub(authorization: .notDetermined)
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
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
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
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
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
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
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
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
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
        await notifications.deliverPending()
        XCTAssertTrue(client.requests.isEmpty)
        let pending = await registry.pendingNotifications()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRetiredProfileDoesNotDeliverAnotherProfilesOutbox() async throws {
        let registry = try await completedRegistry()
        let client = DownloadNotificationClientStub()
        let notifications = PlozziOSDownloadNotifications(registry: registry, client: client) { .default }
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
    func onExpiration(_ handler: @escaping @Sendable () -> Void) { expiration = handler }
    func update(_ progress: DownloadActivityProgress) { updates.append(progress) }
    func complete(success: Bool) { completions.append(success) }
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

private func downloadActivityRecord(id: String = "episode") -> DownloadedMediaRecord {
    DownloadedMediaRecord(
        identity: .external(source: "example", value: id),
        sourceKind: .managedHTTP, status: .downloading, localFileName: "media.mkv",
        bytesDownloaded: 0, totalBytes: 100,
        snapshot: .init(title: id, kind: .episode)
    )
}

@MainActor
private func waitForDownloadCondition(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate())
}
#endif
