import CoreModels
import Foundation

/// The transport-agnostic download orchestrator: turns ``DownloadRequest``s into
/// durable, resumable downloads, draining them with bounded concurrency while
/// honoring the network/data-saver policy.
///
/// It composes the pieces and owns none of their internals: the ``DownloadedMediaRegistry``
/// owns state, a ``MediaDownloadEngine`` moves bytes, ``DownloadStorageLocating``
/// owns paths, and ``DownloadNetworkObserving`` + ``DownloadNetworkPolicy`` gate
/// progress. Groups (seasons) are just many requests sharing a `groupID`.
public actor DownloadQueue {
    private let registry: DownloadedMediaRegistry
    private let storage: any DownloadStorageLocating
    private let engine: any MediaDownloadEngine
    private let observer: any DownloadNetworkObserving
    private let fileManager: FileManager
    private var policy: DownloadNetworkPolicy
    private let limiter: ConcurrencyLimiter

    /// Max retry attempts for a transient (non-cancellation) error before failing.
    private let maxAttempts: Int
    private let backoff: @Sendable (Int) async -> Void

    private var running: [String: Task<Void, Never>] = [:]
    private var attemptPermits: [String: DownloadMutationPermit] = [:]
    private var pendingPauses: [String: Set<UUID>] = [:]
    private let lifetimePermit = DownloadMutationPermit()
    private var activityPermit = DownloadMutationPermit()
    private var schedulingEnabled = true
    private var applicationIsActive = true
    private var applicationActivityRevision: UInt64 = 0
    private var backgroundExecutionLease: DownloadBackgroundExecutionLease?

    public init(
        registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating,
        engine: any MediaDownloadEngine,
        observer: any DownloadNetworkObserving = StaticDownloadNetworkObserver(),
        policy: DownloadNetworkPolicy = .default,
        applicationIsActive: Bool = true,
        fileManager: FileManager = .default,
        maxAttempts: Int = 3,
        backoff: @escaping @Sendable (Int) async -> Void = { attempt in
            let seconds = min(30, pow(2.0, Double(attempt)))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.registry = registry
        self.storage = storage
        self.engine = engine
        self.observer = observer
        self.policy = policy
        self.applicationIsActive = applicationIsActive
        self.fileManager = fileManager
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff
        self.limiter = ConcurrencyLimiter(limit: policy.maxConcurrentDownloads)
        (engine as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
    }

    /// Updates the active policy (e.g. the user toggled Wi‑Fi‑only). Applies to
    /// the next scheduling decision; the concurrency cap is fixed at init.
    public func updatePolicy(
        _ policy: DownloadNetworkPolicy,
        applicationRevision: UInt64? = nil
    ) async {
        guard admits(applicationRevision) else { return }
        let revision = applicationActivityRevision
        self.policy = policy
        (engine as? any DownloadPolicyApplying)?.applyDownloadPolicy(policy)
        let conditions = await observer.currentConditions()
        guard admits(revision) else { return }
        await networkConditionsDidChange(conditions)
    }

    public func setApplicationActive(_ isActive: Bool, revision: UInt64) {
        guard revision > applicationActivityRevision
                || (revision == applicationActivityRevision
                    && isActive == applicationIsActive) else {
            return
        }
        if revision > applicationActivityRevision {
            activityPermit.invalidate()
            activityPermit = DownloadMutationPermit()
            applicationActivityRevision = revision
        }
        applicationIsActive = isActive
    }

    public func setBackgroundExecutionLease(_ lease: DownloadBackgroundExecutionLease) {
        guard schedulingEnabled, lease.isValid else { return }
        activityPermit.invalidate()
        activityPermit = DownloadMutationPermit()
        backgroundExecutionLease = lease
    }

    public func networkConditionsDidChange(
        _ conditions: DownloadNetworkConditions
    ) async {
        guard schedulingEnabled else { return }
        let revision = applicationActivityRevision
        if policy.allows(conditions) {
            await resumePaused(reason: .networkPolicy, applicationRevision: revision)
            return
        }
        for identityKey in Array(running.keys) {
            await pause(identityKey: identityKey, reason: .networkPolicy,
                        applicationRevision: revision)
        }
    }

    public func reevaluateNetworkConditions() async {
        let revision = applicationActivityRevision
        let conditions = await observer.currentConditions()
        guard admits(revision) else { return }
        await networkConditionsDidChange(conditions)
    }

    // MARK: - Enqueue

    /// Enqueues a single download. Idempotent: re-enqueuing an in-flight or
    /// completed identity is a no-op beyond refreshing reopen info.
    @discardableResult
    public func enqueue(
        _ request: DownloadRequest,
        startImmediately: Bool = true
    ) async throws -> DownloadedMediaRecord {
        try lifetimePermit.check()
        let record = makeRecord(for: request)
        if let existing = await registry.record(forKey: record.identityKey),
           existing.quality != record.quality {
            try await prepareQualityReplacement(
                existing: existing,
                replacement: record
            )
        }
        // Idempotency: the `.downloading`/`.queued` marker is persisted BEFORE any
        // byte is fetched, so a kill leaves a recoverable record.
        let stored = try await registry.withMutationPermit(lifetimePermit) {
            try $0.beginDownload(record)
        }
        if startImmediately, stored.status != .completed {
            schedule(stored.identityKey)
        }
        return stored
    }

    /// Enqueues a whole group (e.g. a season) under one `groupID`.
    @discardableResult
    public func enqueueGroup(
        _ requests: [DownloadRequest],
        startImmediately: Bool = true
    ) async throws -> [DownloadedMediaRecord] {
        try lifetimePermit.check()
        let records = requests.map(makeRecord(for:))
        for record in records {
            if let existing = await registry.record(forKey: record.identityKey),
               existing.quality != record.quality {
                try await prepareQualityReplacement(
                    existing: existing,
                    replacement: record
                )
            }
        }
        let stored = try await registry.withMutationPermit(lifetimePermit) {
            try $0.beginDownloads(records)
        }
        if startImmediately {
            for record in stored where record.status != .completed {
                schedule(record.identityKey)
            }
        }
        return stored
    }

    private func makeRecord(
        for request: DownloadRequest
    ) -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            identity: request.identity,
            versionID: request.versionID,
            versionLabel: request.versionLabel,
            groupID: request.groupID,
            batchID: request.batchID,
            batchKind: request.batchKind,
            batchTitle: request.batchTitle,
            batchExpectedCount: request.batchExpectedCount,
            sourceKind: request.sourceKind,
            quality: request.quality,
            status: .queued,
            directShareSource: request.directShareSource,
            managedHTTPSource: request.managedHTTPSource,
            localFileName: request.makeLocalFileName(),
            totalBytes: request.expectedBytes,
            contentType: request.contentType,
            snapshot: request.snapshot
        )
    }

    // MARK: - Controls

    /// Permanently closes enqueue admission and scheduling for a retired profile.
    /// Previously persisted requests remain available to a new queue.
    public func suspendScheduling() {
        schedulingEnabled = false
        backgroundExecutionLease?.invalidate()
        lifetimePermit.invalidate()
        activityPermit.invalidate()
        for permit in attemptPermits.values { permit.invalidate() }
        for task in running.values { task.cancel() }
    }

    public func pause(
        identityKey: String,
        reason: DownloadPauseReason = .manual,
        applicationRevision: UInt64? = nil
    ) async {
        guard applicationRevision == nil || admits(applicationRevision) else { return }
        let pauseID = UUID()
        pendingPauses[identityKey, default: []].insert(pauseID)
        let permit = activityPermit
        let task = running[identityKey]
        attemptPermits[identityKey]?.invalidate()
        task?.cancel()
        if let record = await registry.record(forKey: identityKey), record.status != .completed {
            let description = pauseDescription(reason)
            // Retirement can pause existing records; lifecycle pauses must reject
            // their commit when a newer activity revision has already won.
            if applicationRevision == nil {
                try? await registry.setStatus(identityKey: identityKey, .paused,
                                              failureReason: description, pauseReason: reason)
            } else {
                try? await registry.withMutationPermit(permit) {
                    try $0.setStatus(identityKey: identityKey, .paused,
                                     failureReason: description, pauseReason: reason)
                }
            }
        }
        pendingPauses[identityKey]?.remove(pauseID)
        guard pendingPauses[identityKey]?.isEmpty == true else { return }
        pendingPauses[identityKey] = nil
        // A newer foreground resume may have queued work while this pause was
        // waiting for the registry. Admit it only after every pause has settled.
        if await registry.record(forKey: identityKey)?.status == .queued {
            schedule(identityKey)
        }
    }

    public func resume(identityKey: String, applicationRevision: UInt64? = nil) async {
        guard admits(applicationRevision) else { return }
        let permit = activityPermit
        guard let record = await registry.record(forKey: identityKey),
              record.status != .completed else { return }
        guard schedulingEnabled else { return }
        guard permitsRunning(record) else {
            let reason = lifecyclePauseReason(for: record)
            let description = pauseDescription(reason)
            try? await registry.withMutationPermit(permit) {
                try $0.setStatus(identityKey: identityKey, .paused,
                                 failureReason: description, pauseReason: reason)
            }
            return
        }
        if record.status.isActive, let task = running[identityKey], !task.isCancelled {
            return
        }
        do {
            try await registry.withMutationPermit(permit) {
                try $0.setStatus(identityKey: identityKey, .queued)
            }
        } catch is CancellationError {
            return
        } catch {
            NSLog("Download status update failed: %@", error.localizedDescription)
            return
        }
        schedule(identityKey)
    }

    /// Rebuilds a failed transfer from fresh secret-free source metadata. Unlike
    /// resume, this deliberately discards stale background work and partial bytes.
    @discardableResult
    public func restartFailed(
        _ request: DownloadRequest
    ) async throws -> DownloadedMediaRecord {
        try lifetimePermit.check()
        let replacement = makeRecord(for: request)
        guard let existing = await registry.record(
            forKey: replacement.identityKey
        ), existing.status == .failed else {
            return try await enqueue(request)
        }

        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(
                identityKey: existing.identityKey
            )
        }
        let task = running[existing.identityKey]
        task?.cancel()
        await task?.value
        running[existing.identityKey] = nil
        try lifetimePermit.check()

        let folder = try storage.pinnedFolderURL(
            forKey: existing.identityKey
        )
        for fileName in Set([
            existing.localFileName,
            replacement.localFileName
        ]) {
            let file = folder.appendingPathComponent(fileName)
            try? fileManager.removeItem(at: file)
            try? fileManager.removeItem(
                at: file.appendingPathExtension("source")
            )
            try? fileManager.removeItem(
                at: file.appendingPathExtension("resume")
            )
        }

        let stored = try await registry.withMutationPermit(lifetimePermit) {
            try $0.beginQualityReplacement(replacement)
        }
        schedule(stored.identityKey)
        return stored
    }

    public func pause(batchID: String, reason: DownloadPauseReason = .manual) async {
        for record in await registry.records(inBatch: batchID)
        where record.status.isActive {
            await pause(identityKey: record.identityKey, reason: reason)
        }
    }

    public func resume(batchID: String) async {
        for record in await registry.records(inBatch: batchID)
        where record.status == .paused || record.status == .failed {
            await resume(identityKey: record.identityKey)
        }
    }

    public func resumePaused(
        reason: DownloadPauseReason,
        applicationRevision: UInt64? = nil
    ) async {
        guard admits(applicationRevision) else { return }
        let revision = applicationActivityRevision
        for record in await registry.all()
        where record.status == .paused && record.pauseReason == reason {
            await resume(identityKey: record.identityKey, applicationRevision: revision)
        }
    }

    public func cancelAndRemove(identityKey: String) async throws {
        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(identityKey: identityKey)
        }
        let task = running[identityKey]
        task?.cancel()
        await task?.value
        running[identityKey] = nil
        if let folder = try? storage.pinnedFolderURL(forKey: identityKey) {
            try? fileManager.removeItem(at: folder)
        }
        if let backup = try? storage.replacementBackupFolderURL(
            forKey: identityKey
        ) {
            try? fileManager.removeItem(at: backup)
        }
        try await registry.remove(identityKey: identityKey)
    }

    public func discardPersistentWork(identityKey: String) async {
        guard let persistentEngine = engine as? any DownloadPersistentWorkCancelling else {
            return
        }
        await persistentEngine.discardPersistentWork(identityKey: identityKey)
    }

    /// Restarts work interrupted by process termination. Explicitly paused records
    /// stay paused until the corresponding user/policy action resumes them.
    public func resumeInterrupted(applicationRevision: UInt64? = nil) async {
        guard admits(applicationRevision) else { return }
        let revision = applicationActivityRevision
        for record in await registry.all() where record.status.isActive {
            await resume(identityKey: record.identityKey, applicationRevision: revision)
        }
    }

    // MARK: - Draining

    private func schedule(_ identityKey: String) {
        guard schedulingEnabled,
              running[identityKey] == nil,
              pendingPauses[identityKey] == nil else { return }
        let permit = DownloadMutationPermit()
        attemptPermits[identityKey] = permit
        let task = Task { [weak self] in
            guard let self else { return }
            await self.limiterRun(identityKey, permit: permit)
        }
        running[identityKey] = task
    }

    private func limiterRun(_ identityKey: String, permit: DownloadMutationPermit) async {
        _ = await limiter.runUnlessCancelled { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.performDownload(identityKey, permit: permit)
        }
        permit.invalidate()
        guard attemptPermits[identityKey] === permit else { return }
        attemptPermits[identityKey] = nil
        running[identityKey] = nil
        guard schedulingEnabled else { return }
        let record = await registry.record(forKey: identityKey)
        guard schedulingEnabled, record?.status == .queued else {
            return
        }
        schedule(identityKey)
    }

    private func performDownload(_ identityKey: String, permit: DownloadMutationPermit) async {
        guard let record = await registry.record(forKey: identityKey),
              record.status.isActive,
              !Task.isCancelled else { return }
        guard permitsRunning(record) else {
            let reason = lifecyclePauseReason(for: record)
            await setAttemptStatus(
                identityKey: identityKey,
                .paused,
                failureReason: pauseDescription(reason),
                pauseReason: reason,
                permit: permit
            )
            return
        }

        // Network / data-saver gate.
        let conditions = await observer.currentConditions()
        guard !Task.isCancelled else { return }
        guard policy.allows(conditions) else {
            await setAttemptStatus(
                identityKey: identityKey, .paused,
                failureReason: "Waiting for an allowed network",
                pauseReason: .networkPolicy,
                permit: permit
            )
            return
        }

        // Storage budget: block NEW downloads over the soft cap (never evict).
        if let budget = policy.storageBudgetBytes {
            let currentBytes = await usedBytes()
            guard !Task.isCancelled else { return }
            if currentBytes >= budget {
                await setAttemptStatus(
                    identityKey: identityKey, .failed,
                    failureReason: "Storage budget reached",
                    permit: permit
                )
                return
            }
        }

        guard !Task.isCancelled else { return }
        guard let destination = try? storage.pinnedFileURL(for: record) else {
            await setAttemptStatus(
                identityKey: identityKey, .failed,
                failureReason: "Download location unavailable",
                permit: permit
            )
            return
        }
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let totalBytes = record.totalBytes,
           let freeBytes = try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [
                .volumeAvailableCapacityKey
            ])
            .volumeAvailableCapacity,
           max(0, totalBytes - record.bytesDownloaded) > Int64(freeBytes) {
            await setAttemptStatus(
                identityKey: identityKey,
                .failed,
                failureReason: "Not enough device storage",
                permit: permit
            )
            return
        }

        var attempt = 0
        while true {
            do {
                let progressPermit = DownloadMutationPermit()
                defer { progressPermit.invalidate() }
                guard !Task.isCancelled else { return }
                guard let currentRecord = await registry.record(
                    forKey: identityKey
                ) else {
                    return
                }
                guard !Task.isCancelled else { return }
                try await registry.withMutationPermit(permit) {
                    try $0.setStatus(identityKey: identityKey,
                                     currentRecord.quality == .original ? .downloading : .preparing)
                }
                let registry = self.registry
                let total = try await engine.download(
                    record: currentRecord,
                    to: destination
                ) { bytes, total in
                    try? await registry.withMutationPermit(permit) { registry in
                        try progressPermit.withAccess {
                            if bytes > 0, registry.record(forKey: identityKey)?.status == .preparing {
                                try registry.setStatus(identityKey: identityKey, .downloading)
                            }
                            try registry.updateProgress(identityKey: identityKey,
                                                        bytesDownloaded: bytes,
                                                        totalBytes: total > 0 ? total : nil)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                try await registry.withMutationPermit(permit) {
                    try $0.markCompleted(identityKey: identityKey, totalBytes: total)
                }
                if let backup = try? storage.replacementBackupFolderURL(
                    forKey: identityKey
                ) {
                    try? fileManager.removeItem(at: backup)
                }
                return
            } catch is CancellationError {
                if !Task.isCancelled {
                    let status = await registry.record(
                        forKey: identityKey
                    )?.status
                    if status != .paused {
                        await setAttemptStatus(
                            identityKey: identityKey,
                            .paused,
                            failureReason: "Paused",
                            pauseReason: .manual,
                            permit: permit
                        )
                    }
                }
                return
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    let message = error.localizedDescription
                    await setAttemptStatus(identityKey: identityKey, .failed,
                                           failureReason: message, permit: permit)
                    return
                }
                await backoff(attempt)
                if Task.isCancelled {
                    return
                }
            }
        }
    }

    private func prepareQualityReplacement(
        existing: DownloadedMediaRecord,
        replacement: DownloadedMediaRecord
    ) async throws {
        if let persistentEngine = engine as? any DownloadPersistentWorkCancelling {
            await persistentEngine.discardPersistentWork(
                identityKey: existing.identityKey
            )
        }
        let task = running[existing.identityKey]
        task?.cancel()
        await task?.value
        running[existing.identityKey] = nil
        try lifetimePermit.check()

        let folder = try storage.pinnedFolderURL(forKey: existing.identityKey)
        let backup = try storage.replacementBackupFolderURL(
            forKey: existing.identityKey
        )
        if existing.status == .completed {
            let hasFolder = fileManager.fileExists(atPath: folder.path)
            let hasBackup = fileManager.fileExists(atPath: backup.path)
            if hasFolder {
                if hasBackup {
                    try fileManager.removeItem(at: backup)
                }
                let recordURL = folder.appendingPathComponent(
                    ".record.json",
                    isDirectory: false
                )
                try JSONEncoder().encode(existing).write(
                    to: recordURL,
                    options: .atomic
                )
                try fileManager.moveItem(at: folder, to: backup)
            }
        } else {
            try? fileManager.removeItem(at: folder)
        }

        do {
            _ = try await registry.withMutationPermit(lifetimePermit) {
                try $0.beginQualityReplacement(replacement)
            }
        } catch {
            if existing.status == .completed,
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: folder)
            }
            throw error
        }

        if let artworkFileName = replacement.snapshot.artworkFileName {
            let backupArtwork = backup.appendingPathComponent(artworkFileName)
            if fileManager.fileExists(atPath: backupArtwork.path) {
                try fileManager.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
                try? fileManager.copyItem(
                    at: backupArtwork,
                    to: folder.appendingPathComponent(artworkFileName)
                )
            }
        }
    }

    private func usedBytes() async -> Int64 {
        await registry.all().reduce(Int64(0)) { $0 + $1.bytesDownloaded }
    }

    private func setAttemptStatus(
        identityKey: String,
        _ status: DownloadStatus,
        failureReason: String? = nil,
        pauseReason: DownloadPauseReason? = nil,
        permit: DownloadMutationPermit
    ) async {
        do {
            try await registry.withMutationPermit(permit) {
                try $0.setStatus(identityKey: identityKey, status,
                                 failureReason: failureReason, pauseReason: pauseReason)
            }
        } catch is CancellationError {
            return
        } catch {
            NSLog("Download status update failed: %@", error.localizedDescription)
        }
    }

    private func admits(_ revision: UInt64?) -> Bool {
        schedulingEnabled && (revision == nil || revision == applicationActivityRevision)
    }

    private func pauseDescription(_ reason: DownloadPauseReason) -> String {
        switch reason {
        case .manual:
            "Paused"
        case .networkPolicy:
            "Waiting for an allowed network"
        case .speedLimitPolicy:
            "Paused because this server cannot apply the download speed limit"
        case .inactiveProfile:
            "Paused while another profile is active"
        case .backgroundPolicy:
            "Paused while Plozz is in the background"
        case .directShareBackground:
            "This server connection resumes when Plozz is open"
        }
    }

    private func permitsRunning(_ record: DownloadedMediaRecord) -> Bool {
        guard !applicationIsActive else { return true }
        switch record.sourceKind {
        case .directShare:
            return backgroundExecutionLease?.isValid == true
                && (policy.maximumBytesPerSecond == nil
                    || policy.cappedBackgroundBehavior == .continueAtFullSpeed)
        case .managedHTTP:
            return policy.maximumBytesPerSecond == nil
                || policy.cappedBackgroundBehavior == .continueAtFullSpeed
        }
    }

    private func lifecyclePauseReason(
        for record: DownloadedMediaRecord
    ) -> DownloadPauseReason {
        record.sourceKind == .directShare && backgroundExecutionLease?.isValid != true
            ? .directShareBackground
            : .backgroundPolicy
    }

    #if DEBUG
    func hasPendingPauseForTesting(identityKey: String) -> Bool {
        pendingPauses[identityKey] != nil
    }

    /// Test hook: awaits every in-flight drain task so tests can assert terminal
    /// state deterministically. Not for production use.
    func drainForTesting() async {
        while !running.isEmpty {
            let tasks = Array(running.values)
            for task in tasks { await task.value }
        }
    }
    #endif
}
