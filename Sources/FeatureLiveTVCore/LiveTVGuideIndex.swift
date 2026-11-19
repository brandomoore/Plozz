import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

public struct LiveTVGuideIndexState: Codable, Equatable, Sendable {
    let generation: UUID
    let projection: String
    let digest: String
    let lowerBound: Date
    let upperBound: Date
    var expiresAt: Date
    var cacheMetadata: XMLTVGuideCacheMetadata? = nil

    func contains(_ range: DateInterval) -> Bool {
        range.start >= lowerBound && range.end <= upperBound
    }

    /// Whether the saved listings may be used without asking the server again.
    /// `updateInterval` is the profile's chosen limit; nil keeps the response's own lifetime.
    func isReusable(at now: Date, updateInterval: TimeInterval?) -> Bool {
        guard let cacheMetadata else { return expiresAt > now }
        guard let updateInterval else { return expiresAt > now && cacheMetadata.isFresh(at: now) }
        // An expiry earlier than the response's own marks an index that must be rebuilt soon.
        if expiresAt < cacheMetadata.expiresAt, expiresAt <= now { return false }
        return cacheMetadata.isFresh(at: now, updateInterval: updateInterval)
    }

    /// When an automatic update next falls due. Shorter lifetimes stated by the server are
    /// honoured when listings are requested, not by updating in the background more often.
    func updateDue(interval: TimeInterval) -> Date {
        cacheMetadata?.checkedAt.addingTimeInterval(interval) ?? expiresAt
    }
}

enum LiveTVGuideIndexError: Error { case generationChanged }

/// One account/authorization's XMLTV documents. The cache owns synchronous SQLite
/// work; this actor stays available to cancel or invalidate an in-flight import.
public actor LiveTVGuideIndex {
    public typealias PinnedCatalog = @Sendable () throws -> [LiveTVPrototypeChannel]
    public typealias Download = @Sendable () async throws -> XMLTVDownloadedDocument
    public typealias Revalidate = @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    private let cache: LiveTVIndexedCache
    private let language: String?
    private let clock: @Sendable () -> Date
    private let updateInterval: @Sendable () -> TimeInterval?
    private var epoch = UUID()
    private var closed = false
    private var invalidating = false
    private var validated: [URL: UUID] = [:]
    private var requiresValidation = false
    private var cachedProjection: (revision: String, value: String)?
    private var flight: Flight?
    private var transientTasks: [UUID: Task<[LiveTVPrototypeProgram], any Error>] = [:]
    private var admissionWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    private enum Resolution: Sendable {
        case indexed(LiveTVGuideIndexState)
        case transient(Data)
    }

    private struct Flight {
        let id: UUID
        let url: URL
        let projection: String
        let epoch: UUID
        let task: Task<Void, Never>
        let progress: GuideProgressRelay
        var cancelling = false
        var waiters: [UUID: CheckedContinuation<Resolution, any Error>] = [:]
    }

    public init(
        cache: LiveTVIndexedCache, preferredLanguage: String? = LanguageMatch.deviceLanguageCode,
        clock: @escaping @Sendable () -> Date = Date.init,
        updateInterval: @escaping @Sendable () -> TimeInterval? = { nil }
    ) {
        self.cache = cache
        language = preferredLanguage
        self.clock = clock
        self.updateInterval = updateInterval
    }

    #if DEBUG
    func waitForWaitersForTesting(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while (flight?.waiters.count ?? 0) < count, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
    func waitForAdmissionForTesting() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while admissionWaiters.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    }
    #endif

    public func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, download: @escaping Download
    ) async throws -> [LiveTVPrototypeProgram] {
        try await programs(from: url, catalog: catalog, channels: channels, range: range) { _ in
            .document(try await download())
        }
    }

    /// `trustsGuideIDs`: the lineup and this guide come from the same provider account, so
    /// a channel's guide ID alone decides its listings.
    public func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, trustsGuideIDs: Bool = false, revalidate: @escaping Revalidate
    ) async throws -> [LiveTVPrototypeProgram] {
        try await programs(from: url, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs,
                           catalogRevision: nil, pinnedCatalog: { catalog }, revalidate: revalidate)
    }

    public func programs(
        from url: URL, channels: [LiveTVPrototypeChannel], range: DateInterval,
        trustsGuideIDs: Bool = false, catalogRevision: String?,
        pinnedCatalog: @escaping PinnedCatalog, revalidate: @escaping Revalidate
    ) async throws -> [LiveTVPrototypeProgram] {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000 else { throw LiveTVCacheError.invalidRange }
        let (projection, catalog) = try prepareProjection(revision: catalogRevision, catalog: pinnedCatalog)
        let loadCatalog: PinnedCatalog
        if let catalog { loadCatalog = { catalog } } else { loadCatalog = pinnedCatalog }
        let sourceID = Self.sourceID(url)
        let requestEpoch = epoch
        for _ in 0..<2 {
            try checkRequest(requestEpoch)
            let resolution = try await resolution(
                url: url, catalog: loadCatalog, projection: projection, range: range, download: revalidate
            )
            try Task.checkCancellation()
            guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
            switch resolution {
            case .indexed(let state):
                guard state.contains(range) else { continue }
                do {
                    let result = try await cache.indexedAccountPrograms(
                        sourceID: sourceID, sourceURL: url, generation: state.generation,
                        channels: channels, range: range, trustsGuideIDs: trustsGuideIDs, expectedState: state
                    )
                    try Task.checkCancellation()
                    guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
                    #if DEBUG
                    if !result.isEmpty { IPTVLineupProbe.record?(.nonemptySourceQueries) }
                    #endif
                    return result
                } catch LiveTVGuideIndexError.generationChanged { continue }
            case .transient(let data):
                let language = language
                let transientID = UUID()
                let progress = ServerLiveTVGuideProgress.report
                let task = Task.detached(priority: .utility) {
                    try ServerLiveTVGuideProgress.$report.withValue(progress) {
                        let parser = LiveTVXMLTVParser(
                            provider: LiveTVGuideSource.provider(for: url), preferredLanguage: language
                        )
                        return try parser.accountPrograms(
                            data: data, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs
                        )
                    }
                }
                transientTasks[transientID] = task
                defer { transientTasks.removeValue(forKey: transientID) }
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
                return result
            }
        }
        throw LiveTVGuideIndexError.generationChanged
    }

    /// Answers from a fresh saved index without starting or joining a download.
    /// `nil` means only a source that can load the guide can answer. The lineup is
    /// read only once a saved index could answer, so a miss costs no catalogue load.
    /// A supplied revision must change whenever the catalog's matching fields change.
    /// Without one, every lookup validates the full lineup.
    public func cachedPrograms(
        from url: URL, channels: [LiveTVPrototypeChannel], range: DateInterval,
        trustsGuideIDs: Bool = false, catalogRevision: String? = nil,
        catalog: @Sendable () async throws -> [LiveTVPrototypeChannel]
    ) async throws -> [LiveTVPrototypeProgram]? {
        try await cachedPrograms(from: url, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs,
                                 catalogRevision: catalogRevision, pinnedCatalog: nil, catalog: catalog)
    }

    public func cachedPrograms(
        from url: URL, channels: [LiveTVPrototypeChannel], range: DateInterval,
        trustsGuideIDs: Bool = false, catalogRevision: String?, pinnedCatalog: @escaping PinnedCatalog
    ) async throws -> [LiveTVPrototypeProgram]? {
        // Keep the pinned supplier synchronous through the projection memo check and install.
        try await cachedPrograms(from: url, channels: channels, range: range, trustsGuideIDs: trustsGuideIDs,
                                 catalogRevision: catalogRevision, pinnedCatalog: pinnedCatalog, catalog: pinnedCatalog)
    }

    private func cachedPrograms(
        from url: URL, channels: [LiveTVPrototypeChannel], range: DateInterval,
        trustsGuideIDs: Bool, catalogRevision: String?, pinnedCatalog: PinnedCatalog?,
        catalog: @Sendable () async throws -> [LiveTVPrototypeChannel]
    ) async throws -> [LiveTVPrototypeProgram]? {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000 else { throw LiveTVCacheError.invalidRange }
        try Task.checkCancellation()
        guard !closed, !invalidating else { throw CancellationError() }
        // An explicit refresh must reach the provider before saved rows are trusted again.
        guard !requiresValidation || validated[url] == epoch else { return nil }
        let requestEpoch = epoch
        let sourceID = Self.sourceID(url)
        let now = clock()
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var result: [LiveTVPrototypeProgram]?
        if let state = saved, state.contains(range), state.isReusable(at: now, updateInterval: updateInterval()) {
            try checkRequest(requestEpoch)
            let projection: String
            if let pinnedCatalog {
                (projection, _) = try prepareProjection(revision: catalogRevision, catalog: pinnedCatalog)
            } else if let catalogRevision, cachedProjection?.revision == catalogRevision,
                      let value = cachedProjection?.value {
                projection = value
            } else {
                let lineup = try await catalog()
                try checkRequest(requestEpoch)
                (projection, _) = try prepareProjection(revision: catalogRevision, catalog: { lineup })
            }
            if state.projection == projection {
                do {
                    result = try await cache.indexedAccountPrograms(
                        sourceID: sourceID, sourceURL: url, generation: state.generation,
                        channels: channels, range: range, trustsGuideIDs: trustsGuideIDs,
                        isEligible: { [clock, updateInterval] current in
                            current.projection == projection && current.isReusable(at: clock(), updateInterval: updateInterval())
                        }
                    )
                } catch LiveTVGuideIndexError.generationChanged { result = nil }
            }
        }
        // A miss is still an answer: it must not outlive cancellation or an invalidation.
        try Task.checkCancellation()
        guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
        return result
    }

    private func prepareProjection(
        revision: String?, catalog: PinnedCatalog
    ) throws -> (String, [LiveTVPrototypeChannel]?) {
        try checkRequest(epoch)
        if let revision, let cachedProjection, cachedProjection.revision == revision {
            return (cachedProjection.value, nil)
        }
        // No suspension between memo lookup and publication. A second cold caller shares
        // this result, but cancellation of the builder cannot cancel that caller's work.
        let lineup = try catalog()
        guard lineup.count <= 100_000 else { throw LiveTVCacheError.invalidRange }
        let projection = try Self.projection(lineup, language: language)
        try Task.checkCancellation()
        if let revision { cachedProjection = (revision, projection) }
        return (projection, lineup)
    }

    private func checkRequest(_ requestEpoch: UUID) throws {
        try Task.checkCancellation()
        guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
    }

    /// Brings a guide that is already saved for `url` up to date once it is older than the
    /// chosen update interval. Returns when it next falls due, or nil when automatic updates
    /// are off or nothing is saved; a guide is never downloaded here for the first time.
    public func updateSaved(
        from url: URL, catalog: @Sendable () async throws -> [LiveTVPrototypeChannel],
        revalidate: @escaping Revalidate
    ) async throws -> Date? {
        guard let interval = updateInterval(), !closed else { return nil }
        let requestEpoch = epoch
        let sourceID = Self.sourceID(url)
        let state = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        try checkRequest(requestEpoch)
        guard let saved = state else { return nil }
        let now = clock()
        let due = saved.updateDue(interval: interval)
        if now < due { return due }
        let lineup = try await catalog()
        try checkRequest(requestEpoch)
        _ = try await programs(
            from: url, catalog: lineup, channels: [],
            range: DateInterval(start: now, duration: 6 * 3_600), revalidate: revalidate
        )
        let next = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)?
            .updateDue(interval: interval)
        try checkRequest(requestEpoch)
        return next
    }

    public func invalidate() async {
        epoch = UUID()
        cachedProjection = nil
        requiresValidation = true
        validated.removeAll()
        invalidating = true
        let task = flight?.task
        let transient = Array(transientTasks.values)
        flight?.cancelling = true
        task?.cancel()
        for task in transient { task.cancel() }
        await task?.value
        for task in transient { _ = await task.result }
        invalidating = false
    }

    public func cancel() async {
        closed = true
        await invalidate()
    }

    private func resolution(
        url: URL, catalog: @escaping PinnedCatalog, projection: String,
        range: DateInterval, download: @escaping Revalidate
    ) async throws -> Resolution {
        while let existing = flight,
              existing.url != url || existing.projection != projection || existing.cancelling {
            try await waitForAdmission()
            try Task.checkCancellation()
            guard !closed, !invalidating else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard !closed, !invalidating else { throw CancellationError() }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flight == nil {
                    let id = UUID()
                    let requestEpoch = epoch
                    let force = requiresValidation && validated[url] != epoch
                    let cache = cache
                    let language = language
                    let progress = GuideProgressRelay()
                    let task = Task(priority: .utility) {
                        let result: Result<Resolution, any Error>
                        do {
                            result = .success(try await ServerLiveTVGuideProgress.$report.withValue(progress.send) {
                                try await Self.resolve(
                                    url: url, catalog: catalog, projection: projection, range: range,
                                    cache: cache, language: language, force: force, now: self.clock(),
                                    updateInterval: self.updateInterval(), download: download
                                )
                            })
                        } catch { result = .failure(error) }
                        self.finish(id: id, epoch: requestEpoch, result: result)
                    }
                    flight = Flight(id: id, url: url, projection: projection, epoch: requestEpoch, task: task, progress: progress)
                }
                flight?.waiters[waiterID] = continuation
                if let report = ServerLiveTVGuideProgress.report {
                    flight?.progress.add(waiterID, report)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = flight?.waiters.removeValue(forKey: id) else { return }
        flight?.progress.remove(id)
        continuation.resume(throwing: CancellationError())
        if flight?.waiters.isEmpty == true {
            flight?.cancelling = true
            flight?.task.cancel()
        }
    }

    private func waitForAdmission() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                admissionWaiters[id] = continuation
            }
        } onCancel: { Task { await self.cancelAdmission(id) } }
    }

    private func cancelAdmission(_ id: UUID) {
        admissionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, epoch requestEpoch: UUID, result: Result<Resolution, any Error>) {
        guard let current = flight, current.id == id else { return }
        flight = nil
        let admissions = admissionWaiters.values
        admissionWaiters.removeAll()
        for continuation in admissions { continuation.resume() }
        let admitted = !closed && !invalidating && epoch == requestEpoch && !current.cancelling
        if admitted, case .success = result { validated[current.url] = epoch }
        for continuation in current.waiters.values {
            if admitted { continuation.resume(with: result) }
            else { continuation.resume(throwing: CancellationError()) }
        }
    }

    private static func resolve(
        url: URL, catalog: @escaping PinnedCatalog, projection: String, range: DateInterval,
        cache: LiveTVIndexedCache, language: String?, force: Bool, now: Date,
        updateInterval: TimeInterval?, download: Revalidate
    ) async throws -> Resolution {
        let sourceID = sourceID(url)
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var eligible = saved.flatMap { $0.projection == projection && $0.contains(range) ? $0 : nil }
        if !force, let eligible, eligible.isReusable(at: now, updateInterval: updateInterval) {
            PlozzLog.networking.info("IPTV_INDEX outcome=reused")
            return .indexed(eligible)
        }
        let reason = saved == nil ? "none" : saved?.projection != projection ? "lineupChanged"
            : saved?.contains(range) != true ? "window" : force ? "forced" : "due"
        PlozzLog.networking.info("IPTV_INDEX outcome=download reason=\(reason)")
        // Only validate a representation that can answer this exact projection
        // and window. A 304 cannot supply stations/intervals we never indexed.
        let previous = eligible?.cacheMetadata.flatMap { $0.hasValidator ? $0 : nil }
        #if DEBUG
        IPTVLineupProbe.record?(.guideDownloads)
        #endif
        var downloaded = try await download(previous)
        if case .notModified(let metadata) = downloaded {
            guard let saved = eligible, let previous, metadata.responseURL == previous.responseURL else {
                throw LiveTVSourceImportError.invalidResponse
            }
            if metadata.permitsPersistence {
                try Task.checkCancellation()
                var validated = saved
                validated.expiresAt = metadata.expiresAt
                validated.cacheMetadata = metadata
                try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, previous: saved, state: validated)
                PlozzLog.networking.info("IPTV_INDEX outcome=notModified")
                return .indexed(validated)
            }
            // A 304 no-store revokes the saved representation. Obtain a full
            // response instead of publishing success from a deleted index.
            let revoke = Task.detached(priority: .utility) {
                try await cache.removeDownloadedGuide(sourceID: sourceID, sourceURL: url)
            }
            try await revoke.value
            try Task.checkCancellation()
            eligible = nil
            #if DEBUG
            IPTVLineupProbe.record?(.guideDownloads)
            #endif
            downloaded = try await download(nil)
        }
        guard case .document(let response) = downloaded else {
            throw LiveTVSourceImportError.invalidResponse
        }
        ServerLiveTVGuideProgress.report?(.init(stage: .readingGuide))
        // A no-store replacement revokes persistence even when its XML is bad.
        if !response.permitsPersistence {
            let revoke = Task.detached(priority: .utility) {
                try await cache.removeDownloadedGuide(sourceID: sourceID, sourceURL: url)
            }
            try await revoke.value
            try Task.checkCancellation()
            return .transient(response.data)
        }
        try Task.checkCancellation()
        var hasher = SHA256()
        for offset in stride(from: 0, to: response.data.count, by: 65_536) {
            try Task.checkCancellation()
            hasher.update(data: response.data.subdata(in: offset..<min(response.data.count, offset + 65_536)))
        }
        let digest = LiveTVIdentityDigest.hex(hasher.finalize())
        if let eligible, eligible.digest == digest {
            var validated = eligible
            validated.expiresAt = response.expiresAt
            validated.cacheMetadata = response.cacheMetadata
            try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, previous: eligible, state: validated)
            PlozzLog.networking.info("IPTV_INDEX outcome=unchanged")
            return .indexed(validated)
        }
        let state = LiveTVGuideIndexState(
            generation: UUID(), projection: projection, digest: digest,
            lowerBound: range.start.addingTimeInterval(-86_400),
            upperBound: range.start.addingTimeInterval(7 * 86_400), expiresAt: response.expiresAt,
            cacheMetadata: response.cacheMetadata
        )
        let lineup = try catalog()
        try Task.checkCancellation()
        _ = try await cache.importGuide(
            data: response.data, sourceID: sourceID, channels: lineup,
            provider: LiveTVGuideSource.provider(for: url), now: range.start,
            sourceURL: url, preferredLanguage: language, indexState: state
        )
        #if DEBUG
        IPTVLineupProbe.record?(.guideImports)
        #endif
        PlozzLog.networking.info("IPTV_INDEX outcome=imported channels=\(lineup.count)")
        return .indexed(state)
    }

    static func sourceID(_ url: URL) -> String {
        LiveTVIdentityDigest.hex(SHA256.hash(data: Data(url.absoluteString.utf8)))
    }

    private static func projection(_ catalog: [LiveTVPrototypeChannel], language: String?) throws -> String {
        #if DEBUG
        IPTVLineupProbe.record?(.projectionBuilds)
        #endif
        var hasher = SHA256()
        hasher.update(data: try JSONEncoder().encode([
            "account-xmltv-stations-v2", String(LiveTVXMLTVParser.cacheVersion), language
        ]))
        // Only a channel with a guide ID can be given listings. Leaving the others out keeps
        // a saved guide usable when a provider renames its event channels through the day.
        let guided = catalog.filter {
            $0.guideID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        for channel in guided.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            hasher.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        return LiveTVIdentityDigest.hex(hasher.finalize())
    }
}

/// Foreground consumers can join a quiet background import without downloading again.
private final class GuideProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ServerLiveTVGuideProgress?
    private var handlers: [UUID: ServerLiveTVGuideProgress.Handler] = [:]

    func add(_ id: UUID, _ handler: @escaping ServerLiveTVGuideProgress.Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
        // Consumers enqueue only; serialize replay with updates so old progress cannot win.
        if let latest { handler(latest) }
    }

    func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    func send(_ progress: ServerLiveTVGuideProgress) {
        lock.lock()
        defer { lock.unlock() }
        latest = progress
        for callback in handlers.values { callback(progress) }
    }
}
