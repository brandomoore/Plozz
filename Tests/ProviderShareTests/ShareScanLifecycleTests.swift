import CoreModels
import Foundation
import MediaTransportCore
import XCTest
@testable import ProviderShare
@testable import TestSupportPerformance

/// Batch 3 (findings A5 + A7): explicit scan outcomes drive *conditional* background
/// completion stamping (a cancelled/superseded/invalidated pass must never suppress the
/// next needed scan), every non-completing scan is attributed to an exact secret-safe
/// owner, and a per-account arbiter is retired (drained + removed) once its account is
/// invalidated so arbiters never accumulate.
///
/// These are behavior tests against the real `ShareCatalogCoordinator`/`ShareScanner`
/// (only the transport session + diagnostics sink are injected), so they exercise the
/// production completion-gating, owner-attribution, and arbiter-retirement paths.
final class ShareScanLifecycleTests: XCTestCase {

    private final class ListingLoad: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var peak = 0
        private var total = 0

        func begin() {
            lock.withLock {
                active += 1
                total += 1
                peak = max(peak, active)
            }
        }

        func end() { lock.withLock { active -= 1 } }
        var counts: (peak: Int, total: Int) { lock.withLock { (peak, total) } }
    }

    @MainActor
    func testPerformanceTwentyShareScans() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "multi-share-scanning") {
            let load = ListingLoad()
            let coordinator = self.makeCoordinator(
                diagnostics: ScanDiagnosticsSpy(), initialWorkScope: .paused
            )
            let ids = (0..<20).map { _ in "load-\(UUID())" }
            let revision = CredentialRevision()
            var tree = ["": (0..<24).map { "Folder \($0)" }]
            for folder in tree[""]! {
                tree[folder] = (0..<8).map { "\(folder)/Film \($0) (2000).mkv" }
            }
            var stores: [ShareCatalogStore] = []
            for id in ids {
                let controller = LifecycleListController(
                    blocksRoot: false, tree: tree, listingLoad: load
                )
                let store = await coordinator.store(
                    accountKey: id, displayName: "Fixture", credentialRevision: revision,
                    sessionFactory: self.makeSessionFactory(
                        accountID: id, revision: revision, controller: controller
                    )
                )
                stores.append(store)
            }
            let sampler = Task.detached {
                var samples = 0
                var maximum: Int64 = 0
                while !Task.isCancelled {
                    let start = ContinuousClock.now
                    await MainActor.run {}
                    let elapsed = start.duration(to: .now).components
                    maximum = max(maximum, elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
                    samples += 1
                    do { try await Task.sleep(for: .milliseconds(5)) }
                    catch { break }
                }
                return (samples, maximum)
            }
            await coordinator.setAutomaticWorkScope(
                .init(profileID: "fixture", accountKeys: Set(ids)), revision: 1
            )
            var cachedReads = 0
            var maximumRead: Int64 = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(45))
            var completed = 0
            repeat {
                completed = 0
                for id in ids {
                    if await coordinator.backgroundScanCompletedAt(id) != nil { completed += 1 }
                }
                let start = ContinuousClock.now
                _ = await stores[cachedReads % stores.count].movies(offset: 0, limit: 20)
                let elapsed = start.duration(to: .now).components
                maximumRead = max(maximumRead, elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
                cachedReads += 1
                if completed < ids.count { try await Task.sleep(for: .milliseconds(10)) }
            } while completed < ids.count && ContinuousClock.now < deadline
            sampler.cancel()
            let scheduling = await sampler.value
            var assets = 0
            for store in stores { assets += await store.assetDiscoveryStats(newerThan: 0).total }
            for id in ids { await coordinator.invalidate(accountKey: id) }
            XCTAssertEqual(completed, 20, "Every queued source must finish; deferring all work is not a speedup.")
            XCTAssertEqual(assets, 20 * 24 * 8)
            XCTAssertEqual(load.counts.total, 20 * 25)
            XCTAssertGreaterThan(scheduling.0, 0)
            return [
                "shares": ids.count, "completedScans": completed, "assets": assets,
                "directoryListings": load.counts.total, "peakListings": load.counts.peak,
                "cachedReads": cachedReads, "maximumCachedReadMicroseconds": Int(maximumRead),
                "mainActorSamples": scheduling.0, "mainActorMaxDelayMicroseconds": Int(scheduling.1)
            ]
        }
    }

    // MARK: - Test doubles

    private actor LifecycleShutdownGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    /// Captures the secret-safe non-completion records the coordinator emits so a test
    /// can assert the exact owner/generation of each scan that did not stamp completion.
    private final class ScanDiagnosticsSpy: ShareScanDiagnostics, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ShareScanCancellationRecord] = []
        var records: [ShareScanCancellationRecord] { lock.withLock { storage } }
        func recordCancellation(_ record: ShareScanCancellationRecord) {
            lock.withLock { storage.append(record) }
        }
    }

    /// Controls a scan's directory walk deterministically:
    /// - optionally *blocks* the root listing until the scan task is cancelled OR the
    ///   session is force-closed (mirroring a real SMB read aborting on teardown),
    /// - counts how many real walks reached the root (so a coalesced re-access proves it
    ///   spawned no new scan),
    /// - can inject a subdirectory whose listing fails, forcing a `.completedPartial`.
    private final class LifecycleListController: @unchecked Sendable {
        private let lock = NSLock()
        private var openedFlag = false
        private var startedCount = 0
        private var rootListCountValue = 0
        private var shutdownCountValue = 0
        private var rootWaiters: [CheckedContinuation<Void, Never>] = []
        private var blocksRootFlag: Bool
        private let ignoresTaskCancellation: Bool
        let tree: [String: [String]]
        let failingDirs: Set<String>
        let listingLoad: ListingLoad?

        init(
            blocksRoot: Bool,
            ignoresTaskCancellation: Bool = false,
            tree: [String: [String]] = [:],
            failingDirs: Set<String> = [],
            listingLoad: ListingLoad? = nil
        ) {
            self.blocksRootFlag = blocksRoot
            self.ignoresTaskCancellation = ignoresTaskCancellation
            self.tree = tree
            self.failingDirs = failingDirs
            self.listingLoad = listingLoad
        }

        var rootLists: Int { lock.withLock { rootListCountValue } }
        var shutdownCount: Int { lock.withLock { shutdownCountValue } }
        private var isOpened: Bool { lock.withLock { openedFlag } }
        private var hasStarted: Bool { lock.withLock { startedCount > 0 } }

        func noteShutdown() {
            let waiters = lock.withLock {
                shutdownCountValue += 1
                openedFlag = true
                let pending = rootWaiters
                rootWaiters.removeAll()
                return pending
            }
            waiters.forEach { $0.resume() }
        }

        func noteRootList() {
            lock.withLock {
                rootListCountValue += 1
                startedCount += 1
            }
        }

        func setBlocksRoot(_ blocksRoot: Bool) {
            lock.withLock {
                blocksRootFlag = blocksRoot
                openedFlag = false
            }
        }

        func children(of relativePath: String) -> [String] {
            tree[relativePath] ?? []
        }

        func shouldFail(_ relativePath: String) -> Bool {
            failingDirs.contains(relativePath)
        }

        func waitUntilListing(timeout: TimeInterval = 3) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !hasStarted && Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        /// Blocks the root listing until force-close (open) or task cancellation.
        func blockRoot() async {
            guard lock.withLock({ blocksRootFlag }) else { return }
            if ignoresTaskCancellation {
                await withCheckedContinuation { continuation in
                    let opened = lock.withLock {
                        if openedFlag { return true }
                        rootWaiters.append(continuation)
                        return false
                    }
                    if opened { continuation.resume() }
                }
                return
            }
            while !isOpened && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private final class LifecycleFileSystem: MediaTransportFileSystem, @unchecked Sendable {
        private let controller: LifecycleListController
        init(controller: LifecycleListController) { self.controller = controller }

        func validate() async throws {}

        func probe() async throws -> MediaTransportProbe {
            MediaTransportProbe(
                capabilities: try MediaTransportCapabilities(
                    supportsList: true,
                    supportsStat: true,
                    supportsBoundedWholeFileRead: false,
                    byteRangeBehavior: .unsupported,
                    maximumBoundedWholeFileReadBytes: nil,
                    consistency: .changeDetecting
                )
            )
        }

        func list(relativePath: String) async throws -> [RemoteFileEntry] {
            controller.listingLoad?.begin()
            defer { controller.listingLoad?.end() }
            if controller.listingLoad != nil { try await Task.sleep(for: .milliseconds(30)) }
            if relativePath.isEmpty {
                controller.noteRootList()
                await controller.blockRoot()
            }
            if controller.shouldFail(relativePath) {
                throw MediaTransportError.unsupportedCapability("injected listing failure")
            }
            return try controller.children(of: relativePath).map {
                try RemoteFileEntry(
                    relativePath: $0, kind: $0.hasSuffix(".mkv") ? .file : .directory,
                    size: $0.hasSuffix(".mkv") ? 1_000 : nil,
                    modifiedAt: Date(timeIntervalSince1970: 100)
                )
            }
        }

        func stat(relativePath: String) async throws -> RemoteFileEntry {
            throw MediaTransportError.unsupportedCapability("stat")
        }

        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            throw MediaTransportError.unsupportedCapability("bounded read")
        }

        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            throw MediaTransportError.unsupportedCapability("source")
        }
    }

    private final class LifecycleSession: MediaTransportSession, @unchecked Sendable {
        let key: MediaTransportSessionKey
        let fileSystem: any MediaTransportFileSystem
        private let controller: LifecycleListController
        private let shutdownGate: LifecycleShutdownGate?

        init(
            key: MediaTransportSessionKey,
            controller: LifecycleListController,
            shutdownGate: LifecycleShutdownGate? = nil
        ) {
            self.key = key
            self.controller = controller
            self.shutdownGate = shutdownGate
            self.fileSystem = LifecycleFileSystem(controller: controller)
        }

        func shutdown() async {
            controller.noteShutdown()
            await shutdownGate?.wait()
        }

        /// Always healthy: this fake models a stateless session, so the registry
        /// reuses it while idle. Health-driven eviction is covered by
        /// `ResolverStaleSessionTests`.
        func isHealthy() async -> Bool { true }
    }

    // MARK: - Harness

    private func makeSessionFactory(
        accountID: String,
        revision: CredentialRevision,
        controller: LifecycleListController,
        shutdownGate: LifecycleShutdownGate? = nil
    ) -> ShareTransportSessionFactory {
        { role in
            LifecycleSession(
                key: try! MediaTransportSessionKey(
                    accountID: accountID,
                    credentialRevision: revision,
                    endpoint: try! MediaTransportEndpointIdentity(
                        transportIdentifier: "smb",
                        host: "nas.invalid",
                        rootPath: "/Media"
                    ),
                    trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                    role: role
                ),
                controller: controller,
                shutdownGate: shutdownGate
            )
        }
    }

    private func makeCoordinator(
        diagnostics: ScanDiagnosticsSpy,
        initialWorkScope: MediaShareWorkScope? = nil
    ) -> ShareCatalogCoordinator {
        ShareCatalogCoordinator(
            arbiterFactory: { MediaIOArbiter(accountID: $0) },
            diagnostics: diagnostics,
            pipelineFactory: TestPipelineFactory { MetadataResolverSpy() },
            initialWorkScope: initialWorkScope
        )
    }

    @discardableResult
    private func poll(
        timeout: TimeInterval = 3,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    // MARK: - A5: completion gating and owner attribution

    func testTwentyCatalogsQueueScansWithoutBlockingCachedReadsAndAllEventuallyComplete() async {
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let revision = CredentialRevision()
        let ids = (0..<20).map { _ in "bounded-\(UUID())" }
        let controllers = ids.map { _ in LifecycleListController(blocksRoot: true) }
        for (index, id) in ids.enumerated() {
            let store = await coordinator.store(
                accountKey: id, displayName: "Fixture", credentialRevision: revision,
                sessionFactory: makeSessionFactory(
                    accountID: id, revision: revision, controller: controllers[index]
                )
            )
            await store.setMeta("cached-value", id)
            if index < 2 { await controllers[index].waitUntilListing() }
        }
        XCTAssertEqual(controllers.map(\.rootLists).reduce(0, +), 2)
        let cached = await coordinator.store(
            accountKey: ids[19], displayName: "Fixture", credentialRevision: revision,
            sessionFactory: makeSessionFactory(
                accountID: ids[19], revision: revision, controller: controllers[19]
            )
        )
        let value = await cached.meta("cached-value")
        XCTAssertEqual(value, ids[19], "Catalog reads must not wait behind scan admission.")
        for controller in controllers { controller.setBlocksRoot(false); controller.noteShutdown() }
        let finished = await poll(timeout: 10) {
            for id in ids where await coordinator.backgroundScanCompletedAt(id) == nil { return false }
            return true
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(controllers.allSatisfy { $0.rootLists == 1 })
        for id in ids { await coordinator.invalidate(accountKey: id) }
    }

    func testQueuedScanYieldsToPlaybackAndProfileExclusionWithoutOpeningTransport() async throws {
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let revision = CredentialRevision()
        let ids = (0..<4).map { _ in "queued-\(UUID())" }
        let controllers = ids.map { _ in LifecycleListController(blocksRoot: true) }
        for (index, id) in ids.enumerated() {
            _ = await coordinator.store(
                accountKey: id, displayName: "Fixture", credentialRevision: revision,
                sessionFactory: makeSessionFactory(
                    accountID: id, revision: revision, controller: controllers[index]
                )
            )
            if index < 2 { await controllers[index].waitUntilListing() }
        }
        let playback = try await coordinator.acquirePlayback(accountKey: ids[2])
        XCTAssertEqual(controllers[2].rootLists, 0)
        let stamp = await coordinator.backgroundScanCompletedAt(ids[2])
        XCTAssertNil(stamp)
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "replacement", accountKeys: Set(ids.prefix(2))), revision: 1
        )
        await playback.releaseAndWait()
        for controller in controllers { controller.setBlocksRoot(false); controller.noteShutdown() }
        let drained = await poll {
            let third = await coordinator.scanTaskCountForTesting(ids[2])
            let fourth = await coordinator.scanTaskCountForTesting(ids[3])
            return third == 0 && fourth == 0
        }
        XCTAssertTrue(drained)
        XCTAssertEqual(controllers[2].rootLists + controllers[3].rootLists, 0)
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "replacement", accountKeys: Set(ids)), revision: 2
        )
        let resumed = await poll(timeout: 10) {
            for id in ids where await coordinator.backgroundScanCompletedAt(id) == nil { return false }
            return true
        }
        XCTAssertTrue(resumed, "Cancelled waiters must not leak capacity or lose eligible work.")
        for id in ids { await coordinator.invalidate(accountKey: id) }
    }

    func testScanCapacityStaysOwnedUntilCancelledTransportFinishesDraining() async {
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let revision = CredentialRevision()
        let ids = (0..<3).map { _ in "draining-budget-\(UUID())" }
        let controllers = ids.map { _ in LifecycleListController(blocksRoot: true) }
        let shutdown = LifecycleShutdownGate()
        for (index, id) in ids.enumerated() {
            _ = await coordinator.store(
                accountKey: id, displayName: "Fixture", credentialRevision: revision,
                sessionFactory: makeSessionFactory(
                    accountID: id, revision: revision, controller: controllers[index],
                    shutdownGate: index == 0 ? shutdown : nil
                )
            )
            if index < 2 { await controllers[index].waitUntilListing() }
        }
        let removal = Task { await coordinator.invalidate(accountKey: ids[0]) }
        let closing = await poll { controllers[0].shutdownCount > 0 }
        XCTAssertTrue(closing)
        XCTAssertEqual(controllers[2].rootLists, 0, "Cancellation is not a released scan slot.")
        await shutdown.open()
        await removal.value
        let admitted = await poll { controllers[2].rootLists == 1 }
        XCTAssertTrue(admitted)
        for controller in controllers { controller.noteShutdown() }
        for id in ids { await coordinator.invalidate(accountKey: id) }
    }

    func testBrowsingAnyAccountPacesEveryRegisteredScanner() async throws {
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy(), initialWorkScope: .paused)
        let revision = CredentialRevision()
        let ids = (0..<2).map { _ in "global-pacing-\(UUID())" }
        for id in ids {
            _ = await coordinator.store(
                accountKey: id, displayName: "Fixture", credentialRevision: revision,
                sessionFactory: makeSessionFactory(
                    accountID: id, revision: revision,
                    controller: LifecycleListController(blocksRoot: false)
                )
            )
        }
        let first = await coordinator.scanPacerForTesting(ids[0])
        let second = await coordinator.scanPacerForTesting(ids[1])
        let firstPacer = try XCTUnwrap(first)
        let secondPacer = try XCTUnwrap(second)
        XCTAssertTrue(firstPacer === secondPacer)
        await coordinator.noteInteractiveActivity(accountKey: "unregistered-raw-browser")
        let paced = await secondPacer.paceIfBrowsing()
        XCTAssertTrue(paced)
        for id in ids { await coordinator.invalidate(accountKey: id) }
    }

    func testExcludedSourceRegistrationAndPollingDoNotScanOrDiscardItsCatalog() async {
        let accountID = "scope-paused-\(UUID())"
        let revision = CredentialRevision()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy(), initialWorkScope: .paused)
        await coordinator.setAutomaticWorkScope(.paused, revision: 2)
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "stale", accountKeys: [accountID]), revision: 1
        )
        let store = await coordinator.store(
            accountKey: accountID, displayName: "Excluded",
            credentialRevision: revision,
            sessionFactory: makeSessionFactory(accountID: accountID, revision: revision, controller: controller)
        )
        await store.setMeta("scope-test", "retained")
        for _ in 0..<5 { await coordinator.pollForChanges() }
        XCTAssertEqual(controller.rootLists, 0, "Neither cached reads nor polling grants scan permission.")
        let cached = await store.meta("scope-test")
        XCTAssertEqual(cached, "retained")
        await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        await coordinator.setBackgroundWorkAllowed(true, revision: 2)
        await coordinator.pollForChanges()
        XCTAssertEqual(controller.rootLists, 0, "Returning to foreground cannot reopen an excluded source.")
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "current", accountKeys: [accountID]), revision: 3
        )
        let resumed = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(resumed)
        XCTAssertEqual(controller.rootLists, 1)
        await coordinator.invalidate(accountKey: accountID)
    }

    func testExplicitScanNowStillRunsOnceForAnExcludedSource() async {
        let accountID = "scope-manual-\(UUID())"
        let revision = CredentialRevision()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy(), initialWorkScope: .paused)
        _ = await coordinator.store(
            accountKey: accountID, displayName: "Excluded",
            credentialRevision: revision,
            sessionFactory: makeSessionFactory(accountID: accountID, revision: revision, controller: controller)
        )
        XCTAssertEqual(controller.rootLists, 0)
        await coordinator.rescan(accountKey: accountID)
        let finished = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.rootLists, 1)
        for _ in 0..<5 { await coordinator.pollForChanges() }
        XCTAssertEqual(controller.rootLists, 1)
        await coordinator.invalidate(accountKey: accountID)
    }

    func testProfileScopeChangeDrainsOnlyItsScanAndResumesWithoutOverlappingTransport() async {
        let oldID = "scope-old-\(UUID())"
        let newID = "scope-new-\(UUID())"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let old = LifecycleListController(blocksRoot: true, ignoresTaskCancellation: true)
        let new = LifecycleListController(blocksRoot: false)
        let shutdown = LifecycleShutdownGate()
        let coordinator = makeCoordinator(
            diagnostics: diagnostics,
            initialWorkScope: .init(profileID: "old-profile", accountKeys: [oldID])
        )
        let oldStore = await coordinator.store(
            accountKey: oldID, displayName: "Old", credentialRevision: revision,
            sessionFactory: makeSessionFactory(
                accountID: oldID, revision: revision, controller: old, shutdownGate: shutdown
            )
        )
        await oldStore.setMeta("scope-test", "retained")
        _ = await coordinator.store(
            accountKey: newID, displayName: "New", credentialRevision: revision,
            sessionFactory: makeSessionFactory(accountID: newID, revision: revision, controller: new)
        )
        let oldStarted = await poll { old.rootLists == 1 }
        XCTAssertTrue(oldStarted)
        XCTAssertEqual(new.rootLists, 0)
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "new-profile", accountKeys: [newID]), revision: 1
        )
        let newCompleted = await poll { await coordinator.backgroundScanCompletedAt(newID) != nil }
        XCTAssertTrue(newCompleted, "An old source's transport teardown must not block the new profile.")
        let cached = await oldStore.meta("scope-test")
        XCTAssertEqual(cached, "retained", "Profile pausing must not close or purge the shared catalog.")
        await coordinator.setAutomaticWorkScope(
            .init(profileID: "old-profile", accountKeys: [oldID]), revision: 2
        )
        XCTAssertEqual(old.rootLists, 1, "A quick return must wait for the exact previous transport to drain.")
        old.setBlocksRoot(false)
        await shutdown.open()
        let resumed = await poll { await coordinator.backgroundScanCompletedAt(oldID) != nil }
        XCTAssertTrue(resumed)
        XCTAssertEqual(old.rootLists, 2)
        XCTAssertTrue(diagnostics.records.contains { $0.accountKey == oldID && $0.owner == .profileScopeChanged })
        await coordinator.invalidate(accountKey: oldID)
        await coordinator.invalidate(accountKey: newID)
    }

    func testReopenedFreshCatalogKeepsOriginalCompletionDeadline() async throws {
        let accountID = "fresh-deadline-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let factory = makeSessionFactory(accountID: accountID, revision: revision, controller: controller)
        let original = makeCoordinator(diagnostics: diagnostics)
        let store = await original.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let completed = await poll { await original.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(completed)
        await original.invalidate(accountKey: accountID)
        let lastScan = Date().addingTimeInterval(-170)
        await store.setMeta("last_full_scan_at", String(lastScan.timeIntervalSince1970))
        let reopened = makeCoordinator(diagnostics: diagnostics)
        _ = await reopened.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let coalesced = await poll { await reopened.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(coalesced)
        let completion = await reopened.backgroundScanCompletedAt(accountID)
        XCTAssertEqual(try XCTUnwrap(completion).timeIntervalSince1970,
                       lastScan.timeIntervalSince1970, accuracy: 0.001,
                       "a no-op must not buy another three minutes from the current time")
        XCTAssertEqual(controller.rootLists, 1)
        await reopened.invalidate(accountKey: accountID)
    }

    func testConcurrentCatalogAccessDoesNotSupersedeItsOwnScanAdmission() async throws {
        let accountID = "admission-burst-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let factory = makeSessionFactory(accountID: accountID, revision: revision, controller: controller)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = await coordinator.store(
                        accountKey: accountID, displayName: "NAS",
                        credentialRevision: revision, sessionFactory: factory
                    )
                }
            }
        }
        await controller.waitUntilListing()
        XCTAssertEqual(controller.rootLists, 1)
        XCTAssertTrue(diagnostics.records.isEmpty,
                      "passive reads must not cancel competing admissions for the same scan")
        await coordinator.invalidate(accountKey: accountID)
    }

    func testPersonalVideoConfigurationCompletesWithoutListingOrMetadataPipeline() async throws {
        let accountID = "personal-scan-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let pipeline = PipelineFactorySpy(resolver: MetadataResolverSpy())
        let coordinator = ShareCatalogCoordinator(diagnostics: diagnostics, pipelineFactory: pipeline)
        let store = await coordinator.store(
            accountKey: accountID, displayName: "Videos",
            credentialRevision: revision,
            libraryConfiguration: MediaShareLibraryConfiguration(name: "Videos", contentType: .personalVideos),
            sessionFactory: makeSessionFactory(accountID: accountID, revision: revision, controller: controller)
        )
        let completed = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(completed, "live-only configuration maintenance must not remain pending forever")
        let configuration = await store.meta("library_configuration")
        XCTAssertEqual(configuration, "personalVideos:standard")
        XCTAssertEqual(controller.rootLists, 0)
        XCTAssertEqual(pipeline.makeCount, 0)
        await coordinator.invalidate(accountKey: accountID)
    }

    /// A clean pass stamps completion, and a subsequent access within the coalesce
    /// window spawns no additional walk (fresh no-op). No non-completion record.
    func testCleanScanStampsCompletionAndCoalesces() async throws {
        let accountID = "clean-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let stamped = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(stamped, "a clean completed pass must stamp background completion")
        XCTAssertTrue(diagnostics.records.isEmpty, "a clean pass records no non-completion")

        // A burst of further accesses within the window must coalesce (no new walk).
        for _ in 0..<5 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.rootLists, 1, "repeated access must coalesce to one walk")

        await coordinator.invalidate(accountKey: accountID)
    }

    /// A scan cancelled by playback admission never stamps completion, is attributed to
    /// the playback owner, and the *next* access (after the lease releases) rescans.
    func testCancelledScanByPlaybackLeavesCompletionNilAndRescans() async throws {
        let accountID = "cancel-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        // Playback admission drains (cancels) the in-flight scan.
        XCTAssertEqual(controller.rootLists, 1, "the scan must reach its blocked listing")
        let playback: MediaIOPlaybackLease
        do {
            playback = try await coordinator.acquirePlayback(accountKey: accountID)
        } catch {
            controller.noteShutdown()
            await coordinator.invalidate(accountKey: accountID)
            throw error
        }

        let recorded = await poll {
            diagnostics.records.contains { $0.owner == .playbackAdmission }
        }
        XCTAssertTrue(recorded, "a playback-cancelled scan must record the playback owner")
        let completion = await coordinator.backgroundScanCompletedAt(accountID)
        XCTAssertNil(completion, "a cancelled scan must not stamp completion")
        XCTAssertEqual(
            diagnostics.records.filter { $0.owner == .playbackAdmission }.count, 1,
            "exactly one owner-attributed record"
        )

        // Releasing the lease and re-accessing must spawn a fresh scan (not suppressed).
        await playback.releaseAndWait()
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let rescanned = await poll { controller.rootLists >= 2 }
        XCTAssertTrue(rescanned, "the next access after a cancelled scan must rescan")

        await coordinator.invalidate(accountKey: accountID)
    }

    func testInactiveApplicationCheckpointsScanAndResumesInForeground() async throws {
        let accountID = "inactive-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        let store = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        await coordinator.setBackgroundWorkAllowed(false)
        let suspended = await store.isSuspendedForTesting()
        XCTAssertTrue(
            suspended,
            "inactive transition must close and gate the catalog before returning"
        )
        let stopped = await poll {
            diagnostics.records.contains { $0.owner == .applicationInactive }
        }
        XCTAssertTrue(stopped, "resigning active must stop and attribute the foreground-only scan")
        let completion = await coordinator.backgroundScanCompletedAt(accountID)
        XCTAssertNil(
            completion,
            "an interrupted pass must not suppress its foreground resume"
        )
        let rootListsWhileInactive = controller.rootLists
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            controller.rootLists,
            rootListsWhileInactive,
            "no scan may restart while the application remains inactive"
        )

        await coordinator.setBackgroundWorkAllowed(true)
        let resumedStore = await poll {
            !(await store.isSuspendedForTesting())
        }
        XCTAssertTrue(
            resumedStore,
            "foreground transition must reopen catalog admission before resuming scans"
        )
        let resumed = await poll { controller.rootLists > rootListsWhileInactive }
        XCTAssertTrue(
            resumed,
            "returning active must resume the interrupted durable scan"
        )

        await coordinator.invalidate(accountKey: accountID)
    }

    func testRuntimeCreatedWhileInactiveStartsSuspended() async throws {
        let accountID = "created-inactive-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        let store = await coordinator.store(
            accountKey: accountID,
            displayName: "NAS",
            credentialRevision: revision,
            sessionFactory: factory
        )

        let initiallySuspended = await store.isSuspendedForTesting()
        XCTAssertTrue(initiallySuspended)
        XCTAssertEqual(controller.rootLists, 0)

        await coordinator.setBackgroundWorkAllowed(true, revision: 2)
        let resumed = await store.isSuspendedForTesting()
        XCTAssertFalse(resumed)
        let scanned = await poll { controller.rootLists == 1 }
        XCTAssertTrue(scanned)
        await coordinator.invalidate(accountKey: accountID)
    }

    func testRepeatedInactiveRevisionFencesOlderForegroundDelivery() async throws {
        let accountID = "repeated-inactive-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let factory = makeSessionFactory(
            accountID: accountID,
            revision: revision,
            controller: LifecycleListController(blocksRoot: false)
        )

        await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        await coordinator.setBackgroundWorkAllowed(false, revision: 2)
        let store = await coordinator.store(
            accountKey: accountID,
            displayName: "NAS",
            credentialRevision: revision,
            sessionFactory: factory
        )
        await coordinator.setBackgroundWorkAllowed(true, revision: 1)

        let remainsSuspended = await store.isSuspendedForTesting()
        XCTAssertTrue(
            remainsSuspended,
            "same-state revisions must still advance the stale-delivery fence"
        )
        await coordinator.invalidate(accountKey: accountID)
    }

    func testStaleScannerSuspensionCannotDetachForegroundListers() async {
        let controller = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let fileSystem = LifecycleFileSystem(controller: controller)
        let store = ShareCatalogStore(
            accountKey: "scanner-revision",
            directory: scannerTempDir()
        )
        let scanner = ShareScanner(
            store: store,
            concurrency: 1,
            makeLister: {
                ShareScanner.ScanLister(
                    list: { try await fileSystem.list(relativePath: $0) },
                    close: { controller.noteShutdown() }
                )
            }
        )

        _ = await scanner.setBackgroundWorkAllowed(false, revision: 1)
        _ = await scanner.setBackgroundWorkAllowed(true, revision: 2)
        let scan = Task { await scanner.scan() }
        await controller.waitUntilListing()

        let staleHandoff = await scanner.setBackgroundWorkAllowed(
            false,
            revision: 1
        )
        XCTAssertTrue(
            staleHandoff.listers.isEmpty,
            "an older inactive callback must not detach foreground listers"
        )

        controller.noteShutdown()
        _ = await scan.value
    }

    func testForegroundReopensAfterCheckpointHandoffWhileTransportDrainStalls() async throws {
        let accountID = "stalled-shutdown-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let controller = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let shutdownGate = LifecycleShutdownGate()
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let factory = makeSessionFactory(
            accountID: accountID,
            revision: revision,
            controller: controller,
            shutdownGate: shutdownGate
        )
        let store = await coordinator.store(
            accountKey: accountID,
            displayName: "NAS",
            credentialRevision: revision,
            sessionFactory: factory
        )
        await controller.waitUntilListing()

        let suspension = Task {
            await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        }
        let becameSafe = await poll {
            await store.isSuspendedForTesting()
        }
        XCTAssertTrue(
            becameSafe,
            "local catalog safety must not wait for transport shutdown"
        )
        _ = await suspension.value

        await coordinator.setBackgroundWorkAllowed(true, revision: 2)
        let resumedAfterCheckpoint = await poll {
            !(await store.isSuspendedForTesting())
        }
        XCTAssertTrue(
            resumedAfterCheckpoint,
            "actor checkpoint snapshot must let foreground reads resume before transport closes"
        )
        let checkpointScanID = await store.meta("resume_scan_id")
        let checkpointFrontier = await store.meta("resume_frontier")
        let checkpointState = await store.meta("resume_checkpoint")
        XCTAssertNotNil(
            checkpointScanID,
            "foreground resume must flush the scanner-owned checkpoint first"
        )
        XCTAssertFalse(checkpointFrontier?.isEmpty ?? true)
        XCTAssertFalse(
            checkpointState?.isEmpty ?? true,
            "suspension handoff must preserve the atomic depth/failure-aware checkpoint"
        )
        let listsBeforeDrain = controller.rootLists
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            controller.rootLists,
            listsBeforeDrain,
            "a replacement scan must still wait for exact old transport ownership to drain"
        )

        await shutdownGate.open()
        let rescanned = await poll {
            controller.rootLists > listsBeforeDrain
        }
        XCTAssertTrue(rescanned)
        await coordinator.invalidate(accountKey: accountID)
    }

    func testStalledAccountDrainDoesNotBlockUnrelatedCatalogResume() async throws {
        let stalledAccountID = "stalled-account-\(UUID().uuidString)"
        let readyAccountID = "ready-account-\(UUID().uuidString)"
        let stalledRevision = CredentialRevision()
        let readyRevision = CredentialRevision()
        let stalledController = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let readyController = LifecycleListController(blocksRoot: false)
        let shutdownGate = LifecycleShutdownGate()
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let stalledStore = await coordinator.store(
            accountKey: stalledAccountID,
            displayName: "Stalled",
            credentialRevision: stalledRevision,
            sessionFactory: makeSessionFactory(
                accountID: stalledAccountID,
                revision: stalledRevision,
                controller: stalledController,
                shutdownGate: shutdownGate
            )
        )
        await stalledController.waitUntilListing()
        let readyStore = await coordinator.store(
            accountKey: readyAccountID,
            displayName: "Ready",
            credentialRevision: readyRevision,
            sessionFactory: makeSessionFactory(
                accountID: readyAccountID,
                revision: readyRevision,
                controller: readyController
            )
        )
        let readyScanCompleted = await poll {
            await coordinator.backgroundScanCompletedAt(readyAccountID) != nil
        }
        XCTAssertTrue(readyScanCompleted)
        let readyScanDrained = await poll {
            (await coordinator.scanTaskCountForTesting(readyAccountID)) == 0
        }
        XCTAssertTrue(readyScanDrained)

        await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        let stalledSuspended = await stalledStore.isSuspendedForTesting()
        let readySuspended = await readyStore.isSuspendedForTesting()
        XCTAssertTrue(stalledSuspended)
        XCTAssertTrue(readySuspended)

        await coordinator.setBackgroundWorkAllowed(true, revision: 2)
        let readyStillSuspended = await readyStore.isSuspendedForTesting()
        XCTAssertFalse(
            readyStillSuspended,
            "an unrelated account must resume independently"
        )
        let stalledResumedAfterCheckpoint = await poll {
            !(await stalledStore.isSuspendedForTesting())
        }
        XCTAssertTrue(
            stalledResumedAfterCheckpoint,
            "the stalled account must reopen from its actor checkpoint snapshot"
        )

        let stalledListsBeforeDrain = stalledController.rootLists
        await shutdownGate.open()
        let stalledScanRestarted = await poll {
            stalledController.rootLists > stalledListsBeforeDrain
        }
        XCTAssertTrue(stalledScanRestarted)
        await coordinator.invalidate(accountKey: stalledAccountID)
        await coordinator.invalidate(accountKey: readyAccountID)
    }

    func testStaleInactiveDeliveryCannotOverrideNewerActiveRevision() async throws {
        let accountID = "phase-revision-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        await coordinator.setBackgroundWorkAllowed(true, revision: 2)
        await coordinator.setBackgroundWorkAllowed(false, revision: 1)
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )

        let scanned = await poll { controller.rootLists == 1 }
        XCTAssertTrue(scanned, "a stale inactive delivery must not pause the newer active phase")
        await coordinator.invalidate(accountKey: accountID)
    }

    func testForcedRescanQueuedWhileInactiveBypassesForegroundCoalescing() async throws {
        let accountID = "inactive-force-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let initialScan = await poll { controller.rootLists == 1 }
        let initialCompletion = await poll {
            await coordinator.backgroundScanCompletedAt(accountID) != nil
        }
        XCTAssertTrue(initialScan)
        XCTAssertTrue(initialCompletion)

        await coordinator.setBackgroundWorkAllowed(false)
        await coordinator.rescan(accountKey: accountID)
        await coordinator.setBackgroundWorkAllowed(true)

        let rescanned = await poll { controller.rootLists == 2 }
        XCTAssertTrue(
            rescanned,
            "an explicit rescan must retain its force semantics across inactivity"
        )
        await coordinator.invalidate(accountKey: accountID)
    }

    func testActiveForcedRescanInterruptedByInactivityResumesAsForced() async throws {
        let accountID = "interrupted-force-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let initialCompletion = await poll {
            await coordinator.backgroundScanCompletedAt(accountID) != nil
        }
        XCTAssertTrue(initialCompletion)

        controller.setBlocksRoot(true)
        await coordinator.rescan(accountKey: accountID)
        let forcedScanStarted = await poll { controller.rootLists == 2 }
        XCTAssertTrue(forcedScanStarted)
        await coordinator.setBackgroundWorkAllowed(false)
        await coordinator.setBackgroundWorkAllowed(true)

        let resumedForcedScan = await poll { controller.rootLists == 3 }
        XCTAssertTrue(
            resumedForcedScan,
            "an interrupted explicit rescan must still bypass the recent-completion throttle"
        )
        await coordinator.invalidate(accountKey: accountID)
    }

    func testInactiveTransitionClosesCancellationInsensitiveDrainingRescan() async throws {
        let accountID = "inactive-draining-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(
            blocksRoot: true,
            ignoresTaskCancellation: true
        )
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        let rescan = Task { await coordinator.rescan(accountKey: accountID) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setBackgroundWorkAllowed(false)

        let listerClosed = await poll { controller.shutdownCount > 0 }
        XCTAssertTrue(
            listerClosed,
            "resigning active must close cancellation-insensitive draining scan transports"
        )
        await rescan.value
        await coordinator.setBackgroundWorkAllowed(true)
        await coordinator.invalidate(accountKey: accountID)
    }

    /// A rescan ("Scan now") supersedes an in-flight background pass. The superseded
    /// pass is attributed to the rescan owner and never stamps completion.
    func testRescanSupersessionRecordsRescanOwner() async throws {
        let accountID = "rescan-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        await coordinator.rescan(accountKey: accountID)

        let recorded = await poll {
            diagnostics.records.contains { $0.owner == .rescanSuperseded }
        }
        XCTAssertTrue(recorded, "the superseded pass must record the rescan owner")
        XCTAssertFalse(
            diagnostics.records.contains { $0.owner == .playbackAdmission || $0.owner == .accountInvalidation },
            "no cross-attribution to a different owner"
        )

        await coordinator.invalidate(accountKey: accountID)
    }

    /// A credential rotation replaces the scanner. The superseded (old-revision) pass is
    /// attributed to the credential-change owner and is recorded against the OLD
    /// credential revision — it cannot stamp the replacement generation.
    func testCredentialSupersessionRecordsOldGenerationOwner() async throws {
        let accountID = "cred-\(UUID().uuidString)"
        let revisionOne = CredentialRevision()
        let revisionTwo = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factoryOne = makeSessionFactory(
            accountID: accountID, revision: revisionOne, controller: controller
        )
        let factoryTwo = makeSessionFactory(
            accountID: accountID, revision: revisionTwo, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revisionOne, sessionFactory: factoryOne
        )
        await controller.waitUntilListing()

        // A new credential revision rotates the scanner, superseding the blocked pass.
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revisionTwo, sessionFactory: factoryTwo
        )

        let recorded = await poll {
            diagnostics.records.contains {
                $0.owner == .credentialChange && $0.credentialRevision == revisionOne.rawValue
            }
        }
        XCTAssertTrue(
            recorded,
            "the superseded pass must record the credential-change owner against the OLD revision"
        )
        XCTAssertFalse(
            diagnostics.records.contains { $0.credentialRevision == revisionTwo.rawValue },
            "the replacement generation must not appear in a non-completion record"
        )

        await coordinator.invalidate(accountKey: accountID)
    }

    /// Account invalidation during an in-flight scan attributes that scan to the
    /// account-invalidation owner (and — see A7 — retires the arbiter).
    func testAccountInvalidationDuringScanRecordsOwner() async throws {
        let accountID = "invalidate-scan-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        await coordinator.invalidate(accountKey: accountID)

        XCTAssertTrue(
            diagnostics.records.contains { $0.owner == .accountInvalidation },
            "an invalidated in-flight scan must record the account-invalidation owner"
        )
        let count = await coordinator.arbiterCount()
        XCTAssertEqual(count, 0, "invalidation with no leases retires the arbiter")
    }

    /// A completed *partial* pass (a listing failed, so pruning was skipped) still stamps
    /// completion — preserving the approved throttle so a permanently-inaccessible folder
    /// cannot cause a re-scan storm — and is NOT recorded as a cancellation.
    func testCompletedPartialScanStampsCompletionAndCoalesces() async throws {
        let accountID = "partial-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(
            blocksRoot: false,
            tree: ["": ["Library"]],
            failingDirs: ["Library"]
        )
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let stamped = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(stamped, "a completed partial pass still stamps completion (approved throttle)")
        XCTAssertTrue(
            diagnostics.records.isEmpty,
            "a completed partial pass is not a cancellation — no non-completion record"
        )

        for _ in 0..<5 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.rootLists, 1, "partial completion coalesces like a clean pass")

        await coordinator.invalidate(accountKey: accountID)
    }

    // MARK: - A7: arbiter lifecycle retirement

    /// Invalidating an account whose scan already finished (no leases) removes the
    /// arbiter immediately.
    func testInvalidationWithNoLeasesRemovesArbiterImmediately() async throws {
        let accountID = "retire-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        _ = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        let before = await coordinator.arbiterCount()
        XCTAssertEqual(before, 1)

        await coordinator.invalidate(accountKey: accountID)
        let after = await coordinator.arbiterCount()
        XCTAssertEqual(after, 0, "invalidation retires the arbiter")
    }

    /// Invalidation while a playback lease is held rejects new admission, waits for the
    /// lease to drain, retires the old arbiter, and permits a fresh generation after.
    func testInvalidationWithHeldPlaybackLeaseWaitsThenRetires() async throws {
        let accountID = "retire-lease-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        _ = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }

        let lease = try await coordinator.acquirePlayback(accountKey: accountID)
        let invalidation = Task { await coordinator.invalidate(accountKey: accountID) }

        // While the lease is held the arbiter is shutting down: it rejects new admission
        // yet remains retained (it must not disappear before the live lease drains).
        try? await Task.sleep(nanoseconds: 80_000_000)
        do {
            _ = try await coordinator.acquirePlayback(accountKey: accountID)
            XCTFail("a shutting-down arbiter must reject new playback admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let retainedDuringDrain = await coordinator.arbiterCount()
        XCTAssertEqual(retainedDuringDrain, 1, "arbiter is retained while a live lease drains")

        await lease.releaseAndWait()
        await invalidation.value
        let afterDrain = await coordinator.arbiterCount()
        XCTAssertEqual(afterDrain, 0, "the arbiter retires once the final lease drains")

        // A re-add installs a fresh arbiter generation.
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let reAdded = await coordinator.arbiterCount()
        XCTAssertEqual(reAdded, 1, "re-add after completed invalidation installs a fresh arbiter")

        await coordinator.invalidate(accountKey: accountID)
    }

    /// Many add/invalidate cycles must leave zero retained arbiters (finding A7: no leak).
    func testRepeatedAddInvalidateCyclesLeaveArbiterCountZero() async throws {
        let accountID = "cycles-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        for _ in 0..<50 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
            await coordinator.invalidate(accountKey: accountID)
        }
        let count = await coordinator.arbiterCount()
        XCTAssertEqual(count, 0, "repeated add/invalidate must not retain arbiters")
    }

    // MARK: - B18: playback-vs-removal race (never lazily revive a runtime/arbiter)

    /// A playback request for an account that was never registered must fail bounded
    /// and must NOT lazily install an arbiter/runtime for it. Before B18 `acquirePlayback`
    /// called a lazy `arbiter(for:)` that conjured (and retained) an arbiter for an
    /// account with no store; now an arbiter exists iff a live runtime exists.
    func testPlaybackForUnregisteredAccountInstallsNoArbiter() async {
        let accountID = "absent-\(UUID().uuidString)"
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())

        let initialCount = await coordinator.arbiterCount()
        XCTAssertEqual(initialCount, 0)
        do {
            _ = try await coordinator.acquirePlayback(accountKey: accountID)
            XCTFail("playback for an unregistered account must fail, not lazily create a runtime")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let afterReject = await coordinator.arbiterCount()
        XCTAssertEqual(
            afterReject, 0,
            "a rejected playback request must not install/retain an arbiter"
        )
    }

    /// After an account is fully invalidated (its runtime + arbiter retired to zero), a
    /// playback request racing the removal must fail bounded and must not revive a fresh
    /// arbiter for the torn-down account. Only an explicit re-registration (`store`)
    /// creates a new runtime generation.
    func testPlaybackAfterInvalidationDoesNotReviveRuntime() async throws {
        let accountID = "revive-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        _ = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        let registeredCount = await coordinator.arbiterCount()
        XCTAssertEqual(registeredCount, 1)

        await coordinator.invalidate(accountKey: accountID)
        let retiredCount = await coordinator.arbiterCount()
        XCTAssertEqual(retiredCount, 0, "invalidation retires the runtime")

        do {
            _ = try await coordinator.acquirePlayback(accountKey: accountID)
            XCTFail("playback for a retired account must fail, not revive an arbiter")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let afterRacedPlayback = await coordinator.arbiterCount()
        XCTAssertEqual(
            afterRacedPlayback, 0,
            "a playback request racing removal must not install a replacement arbiter"
        )

        // Only an explicit re-registration creates a fresh runtime/arbiter generation.
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let reAddedCount = await coordinator.arbiterCount()
        XCTAssertEqual(
            reAddedCount, 1,
            "explicit re-registration installs exactly one fresh runtime"
        )

        await coordinator.invalidate(accountKey: accountID)
        let finalCount = await coordinator.arbiterCount()
        XCTAssertEqual(finalCount, 0)
    }

    // MARK: - Scanner outcome contracts (drives the coordinator's gating)

    private func scannerTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-scan-outcome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScanReturnsCompletedCleanWhenEveryListingSucceeds() async {
        let store = ShareCatalogStore(accountKey: "clean", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .completedClean)
    }

    func testScanReturnsCompletedPartialWhenAListingFails() async {
        let store = ShareCatalogStore(accountKey: "partial", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(
                list: { relativePath in
                    if relativePath.isEmpty {
                        return [try RemoteFileEntry(
                            relativePath: "Library", kind: .directory, modifiedAt: Date()
                        )]
                    }
                    throw MediaTransportError.unsupportedCapability("injected listing failure")
                },
                close: {}
            )
        })
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .completedPartial)
    }

    func testScanIfStaleReturnsFreshNoOpWithinInterval() async {
        let store = ShareCatalogStore(accountKey: "throttle", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        let first = await scanner.scan()
        XCTAssertEqual(first, .completedClean)
        let second = await scanner.scanIfStale()
        XCTAssertEqual(second, .freshNoOp, "a recent completed pass throttles the next walk")
    }

    func testScanReturnsInvalidatedAfterInvalidate() async {
        let store = ShareCatalogStore(accountKey: "invalidated", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        await scanner.invalidate()
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .invalidated)
    }

    // MARK: - Late cancellation-reason leak (Batch 3 follow-up)

    /// A reason stamped for a task AFTER `recordScanOutcome` already consumed its first
    /// reason (a racing playback/rescan targeting the still-present task) must be
    /// discarded by `clearScanTask`, or it would leak in `pendingCancellationReasons`
    /// forever. Exercised through the real stamp/consume/clear methods.
    func testReasonStampedInRecordClearWindowIsDiscardedOnClear() async {
        let accountID = "reason-leak-\(UUID().uuidString)"
        let taskID = UUID()
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())

        // 1. Playback admission stamps the task's owner before cancelling it.
        await coordinator.stampCancellationReasonForTesting(
            accountID, taskID: taskID, owner: .playbackAdmission
        )
        // 2. recordScanOutcome consumes that first reason.
        let consumed = await coordinator.takeCancellationReasonForTesting(accountID, taskID: taskID)
        XCTAssertEqual(consumed, .playbackAdmission)
        var pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 0, "the consumed reason is gone")

        // 3. A racing action stamps a NEW reason in the record→clear window.
        await coordinator.stampCancellationReasonForTesting(
            accountID, taskID: taskID, owner: .rescanSuperseded
        )
        pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 1, "a late stamp lands while the task is still present")

        // 4. clearScanTask must discard it — otherwise the reason leaks.
        await coordinator.clearScanTaskForTesting(accountID, taskID: taskID)
        pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 0, "clearScanTask discards a reason stamped after consumption")
    }
}
