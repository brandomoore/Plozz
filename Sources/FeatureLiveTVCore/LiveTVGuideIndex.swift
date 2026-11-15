import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

public struct LiveTVGuideIndexState: Codable, Sendable {
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
}

enum LiveTVGuideIndexError: Error { case generationChanged }

/// One account/authorization's XMLTV documents. The cache owns synchronous SQLite
/// work; this actor stays available to cancel or invalidate an in-flight import.
public actor LiveTVGuideIndex {
    public typealias Download = @Sendable () async throws -> XMLTVDownloadedDocument
    public typealias Revalidate = @Sendable (XMLTVGuideCacheMetadata?) async throws -> XMLTVGuideResponse
    private let cache: LiveTVIndexedCache
    private let language: String?
    private let clock: @Sendable () -> Date
    private var epoch = UUID()
    private var closed = false
    private var invalidating = false
    private var validated: [URL: UUID] = [:]
    private var requiresValidation = false
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
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cache = cache
        language = preferredLanguage
        self.clock = clock
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

    public func programs(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel],
        range: DateInterval, revalidate: @escaping Revalidate
    ) async throws -> [LiveTVPrototypeProgram] {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000, catalog.count <= 100_000 else { throw LiveTVCacheError.invalidRange }
        let projection = try Self.projection(catalog, language: language)
        let sourceID = Self.sourceID(url)
        while true {
            try Task.checkCancellation()
            guard !closed, !invalidating else { throw CancellationError() }
            let requestEpoch = epoch
            let resolution = try await resolution(
                url: url, catalog: catalog, projection: projection, range: range, download: revalidate
            )
            try Task.checkCancellation()
            guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
            switch resolution {
            case .indexed(let state):
                guard state.contains(range) else { continue }
                do {
                    let result = try await cache.indexedAccountPrograms(
                        sourceID: sourceID, sourceURL: url, generation: state.generation,
                        channels: channels, range: range
                    )
                    try Task.checkCancellation()
                    guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
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
                        let guide = try data.starts(with: [0x1f, 0x8b])
                            ? parser.parse(gzipData: data, channels: channels, now: range.start)
                            : parser.parseXML(data: data, channels: channels, now: range.start)
                        return guide.programs.filter { $0.start < range.end && $0.end > range.start }
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
    }

    /// Answers from a fresh saved index without starting or joining a download.
    /// `nil` means only a source that can load the guide can answer.
    public func cachedPrograms(
        from url: URL, catalog: [LiveTVPrototypeChannel], channels: [LiveTVPrototypeChannel], range: DateInterval
    ) async throws -> [LiveTVPrototypeProgram]? {
        guard range.duration > 0, range.duration <= 172_800,
              range.start.timeIntervalSince1970.isFinite, range.end.timeIntervalSince1970.isFinite,
              channels.count <= 2_000, catalog.count <= 100_000 else { throw LiveTVCacheError.invalidRange }
        try Task.checkCancellation()
        guard !closed, !invalidating else { throw CancellationError() }
        // An explicit refresh must reach the provider before saved rows are trusted again.
        guard !requiresValidation || validated[url] == epoch else { return nil }
        let requestEpoch = epoch
        let projection = try Self.projection(catalog, language: language)
        let sourceID = Self.sourceID(url)
        let now = clock()
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var result: [LiveTVPrototypeProgram]?
        if let state = saved, state.projection == projection, state.contains(range), state.expiresAt > now,
           state.cacheMetadata?.isFresh(at: now) ?? true {
            do {
                result = try await cache.indexedAccountPrograms(
                    sourceID: sourceID, sourceURL: url, generation: state.generation,
                    channels: channels, range: range
                )
            } catch LiveTVGuideIndexError.generationChanged { result = nil }
        }
        // A miss is still an answer: it must not outlive cancellation or an invalidation.
        try Task.checkCancellation()
        guard epoch == requestEpoch, !closed, !invalidating else { throw CancellationError() }
        return result
    }

    public func invalidate() async {
        epoch = UUID()
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
        url: URL, catalog: [LiveTVPrototypeChannel], projection: String,
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
                                    cache: cache, language: language, force: force, now: self.clock(), download: download
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
        url: URL, catalog: [LiveTVPrototypeChannel], projection: String, range: DateInterval,
        cache: LiveTVIndexedCache, language: String?, force: Bool, now: Date, download: Revalidate
    ) async throws -> Resolution {
        let sourceID = sourceID(url)
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        var eligible = saved.flatMap { $0.projection == projection && $0.contains(range) ? $0 : nil }
        if !force, let eligible, eligible.expiresAt > now,
           eligible.cacheMetadata?.isFresh(at: now) ?? true {
            PlozzLog.networking.info("IPTV_INDEX outcome=reused")
            return .indexed(eligible)
        }
        // Only validate a representation that can answer this exact projection
        // and window. A 304 cannot supply stations/intervals we never indexed.
        let previous = eligible?.cacheMetadata.flatMap { $0.hasValidator ? $0 : nil }
        var downloaded = try await download(previous)
        if case .notModified(let metadata) = downloaded {
            guard var validated = eligible, let previous, metadata.responseURL == previous.responseURL else {
                throw LiveTVSourceImportError.invalidResponse
            }
            if metadata.permitsPersistence {
                try Task.checkCancellation()
                validated.expiresAt = metadata.expiresAt
                validated.cacheMetadata = metadata
                try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, state: validated)
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
        if var eligible, eligible.digest == digest {
            eligible.expiresAt = response.expiresAt
            eligible.cacheMetadata = response.cacheMetadata
            try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, state: eligible)
            PlozzLog.networking.info("IPTV_INDEX outcome=unchanged")
            return .indexed(eligible)
        }
        let state = LiveTVGuideIndexState(
            generation: UUID(), projection: projection, digest: digest,
            lowerBound: range.start.addingTimeInterval(-86_400),
            upperBound: range.start.addingTimeInterval(7 * 86_400), expiresAt: response.expiresAt,
            cacheMetadata: response.cacheMetadata
        )
        _ = try await cache.importGuide(
            data: response.data, sourceID: sourceID, channels: catalog,
            provider: LiveTVGuideSource.provider(for: url), now: range.start,
            sourceURL: url, preferredLanguage: language, indexState: state
        )
        PlozzLog.networking.info("IPTV_INDEX outcome=imported channels=\(catalog.count)")
        return .indexed(state)
    }

    static func sourceID(_ url: URL) -> String {
        LiveTVIdentityDigest.hex(SHA256.hash(data: Data(url.absoluteString.utf8)))
    }

    private static func projection(_ catalog: [LiveTVPrototypeChannel], language: String?) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try JSONEncoder().encode([
            "account-xmltv-stations-v1", String(LiveTVXMLTVParser.cacheVersion), language
        ]))
        for channel in catalog.sorted(by: { $0.id < $1.id }) {
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
