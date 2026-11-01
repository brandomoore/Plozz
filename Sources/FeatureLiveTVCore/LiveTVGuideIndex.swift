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

    func contains(_ range: DateInterval) -> Bool {
        range.start >= lowerBound && range.end <= upperBound
    }
}

enum LiveTVGuideIndexError: Error { case generationChanged }

/// One account/authorization's XMLTV documents. The cache owns synchronous SQLite
/// work; this actor stays available to cancel or invalidate an in-flight import.
public actor LiveTVGuideIndex {
    public typealias Download = @Sendable () async throws -> XMLTVDownloadedDocument
    private let cache: LiveTVIndexedCache
    private let language: String?
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
        var cancelling = false
        var waiters: [UUID: CheckedContinuation<Resolution, any Error>] = [:]
    }

    public init(cache: LiveTVIndexedCache, preferredLanguage: String? = LanguageMatch.deviceLanguageCode) {
        self.cache = cache
        language = preferredLanguage
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
                url: url, catalog: catalog, projection: projection, range: range, download: download
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
                let task = Task.detached(priority: .utility) {
                    let parser = LiveTVXMLTVParser(
                        provider: LiveTVGuideSource.provider(for: url), preferredLanguage: language
                    )
                    let guide = try data.starts(with: [0x1f, 0x8b])
                        ? parser.parse(gzipData: data, channels: channels, now: range.start)
                        : parser.parseXML(data: data, channels: channels, now: range.start)
                    return guide.programs.filter { $0.start < range.end && $0.end > range.start }
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
        range: DateInterval, download: @escaping Download
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
                    let task = Task(priority: .utility) {
                        let result: Result<Resolution, any Error>
                        do {
                            result = .success(try await Self.resolve(
                                url: url, catalog: catalog, projection: projection, range: range,
                                cache: cache, language: language, force: force, download: download
                            ))
                        } catch { result = .failure(error) }
                        self.finish(id: id, epoch: requestEpoch, result: result)
                    }
                    flight = Flight(id: id, url: url, projection: projection, epoch: requestEpoch, task: task)
                }
                flight?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = flight?.waiters.removeValue(forKey: id) else { return }
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
        cache: LiveTVIndexedCache, language: String?, force: Bool, download: Download
    ) async throws -> Resolution {
        let sourceID = sourceID(url)
        let saved = try await cache.guideIndexState(sourceID: sourceID, sourceURL: url)
        let eligible = saved.flatMap { $0.projection == projection && $0.contains(range) ? $0 : nil }
        if !force, let eligible, eligible.expiresAt > Date() {
            PlozzLog.networking.info("IPTV_INDEX outcome=reused")
            return .indexed(eligible)
        }
        let response = try await download()
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
            try await cache.revalidateGuideIndex(sourceID: sourceID, sourceURL: url, state: eligible)
            PlozzLog.networking.info("IPTV_INDEX outcome=unchanged")
            return .indexed(eligible)
        }
        let state = LiveTVGuideIndexState(
            generation: UUID(), projection: projection, digest: digest,
            lowerBound: range.start.addingTimeInterval(-86_400),
            upperBound: range.start.addingTimeInterval(7 * 86_400), expiresAt: response.expiresAt
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
        hasher.update(data: try JSONEncoder().encode(["account-xmltv-stations-v1", language]))
        for channel in catalog.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            hasher.update(data: try JSONEncoder().encode(
                [channel.id, channel.name, channel.guideID, channel.guideName, channel.country]
            ))
        }
        return LiveTVIdentityDigest.hex(hasher.finalize())
    }
}
