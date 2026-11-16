import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import os

actor IPTVClient: ApplicationStorageParticipant {
    private static let playlistCatalogScope = "playlist-v5"
    private var cachedLineup: (revision: String?, dataVersion: Int64, entries: [IPTVLineupEntry])?
    private var cachedGuideLineup: (revision: String?, dataVersion: Int64, lineup: SavedGuideLineup)?
    let credential: IPTVCredential
    private let http: IPTVHTTP
    private let artworkSecrets: [String]
    let catalog: IPTVCatalog
    private var refresh: Task<Void, Never>?
    private var refreshScope: String?
    private var refreshHasBackgroundOwner = false
    private var refreshRetryAfter: [String: Date] = [:]
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var awaitsLegacyGuideDiscovery: Bool?
    private let storageLifecycle: ApplicationStorageLifecycle
    private var guideDiscoveryResult: Result<Void, Error>?
    private var authenticatedAt: Date?
    private var liveExtension = "ts"
    private var cachedGuide: (url: URL, data: Data, expires: Date)?
    private var guideCacheExpiry: Task<Void, Never>?
    private var guideCacheGeneration = UUID()
    static let maximumSavedLiveLineupAge: TimeInterval = 86_400
    static let emptyGuideAnswerLifetime: TimeInterval = 6 * 3_600
    static let maximumEmptyGuideAnswers = 100_000
    private var batchGuideUnavailable = false
    private var emptyGuideAnswers: [String: Date] = [:]
    /// Set while the provider is answering guide requests with an overload status.
    private var guideBackoff: (until: Date, failures: Int, error: any Error)?
    private var didReadGuideBackoff = false
    static let guideBackoffStateKey = "guide-backoff-v1"
    private struct SavedGuideBackoff: Codable {
        let deadline: TimeInterval
        let failures: Int
        let status: Int
        let grantedDelay: TimeInterval
    }
    static let firstGuideBackoff: TimeInterval = 300
    static let maximumGuideBackoff: TimeInterval = 3_600
    var cachedGuideByteCount: Int { cachedGuide?.data.count ?? 0 }
    private final class GuideRefreshState {
        weak var scope: ServerLiveTVGuideRefreshScope?
        var missingURLs = Set<URL>()
        var rejectedURLs: [URL: LiveTVSourceImportError] = [:]

        init(scope: ServerLiveTVGuideRefreshScope) { self.scope = scope }
    }
    private var guideRefreshes: [ObjectIdentifier: GuideRefreshState] = [:]
    private let progress: @Sendable (IPTVImportProgress) -> Void
    var pendingCatalogRequestCount: Int { refreshWaiters.count }
    private var didReclaimJournal = false
    private enum RefreshWork: String { case catalog, guide }
    private struct RefreshAdmission {
        let id: UUID
        let kind: RefreshWork
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var activeRefreshWork: UUID?
    private var refreshAdmissions: [RefreshAdmission] = []
    private var isClosed = false
    var pendingRefreshAdmissionCount: Int { refreshAdmissions.count }

    private func reclaimJournalOnce() throws {
        try storageLifecycle.checkAccess()
        if awaitsLegacyGuideDiscovery == nil {
            awaitsLegacyGuideDiscovery = try credential.mode == .playlist
                && !credential.automaticallyDiscoversGuides && credential.explicitGuideURLs.isEmpty
                && catalog.state(Self.playlistCatalogScope) == nil
        }
        guard !didReclaimJournal else { return }
        didReclaimJournal = catalog.reclaimJournal()
    }

    init(
        credential: IPTVCredential, directory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        storageLifecycle: ApplicationStorageLifecycle = .shared,
        progress: @escaping @Sendable (IPTVImportProgress) -> Void = { _ in }
    ) throws {
        self.credential = credential
        self.storageLifecycle = storageLifecycle
        artworkSecrets = IPTVRedirectPolicy.protectedValues(url: credential.address, headers: credential.headers)
            + [credential.password].filter { !$0.isEmpty }
        self.progress = progress
        http = IPTVHTTP(configuration: configuration, sensitiveValues: [credential.password])
        let directory = directory ?? (credential.mode == .file
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("IPTVCatalogs", isDirectory: true)
            : IPTVCatalogStorage.cacheDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalog = try IPTVCatalog(
            url: directory.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
            key: credential.catalogKey, storageLifecycle: storageLifecycle
        )
        storageLifecycle.register(self)
    }

    func prepareForSuspension() {
        guard !storageLifecycle.isActive else { return }
        refresh?.cancel()
        cancelRefreshAdmissions()
        didReclaimJournal = false
        do { try catalog.closeForSuspension() }
        catch { PlozzLog.networking.error("IPTV catalogue suspension close failed") }
    }

    func authenticate() async throws {
        try reclaimJournalOnce()
        let diagnostic = IPTVSetupDiagnostics.current
        diagnostic?.advance(to: .authentication)
        if credential.mode == .file {
            guard try catalog.state("playlist") != nil else { throw IPTVError.fileUnavailable }
            return
        }
        if credential.mode == .playlist {
            let url = GoogleDrivePlaylistURL.downloadURL(for: credential.address)
            let (bytes, response) = try await http.bytes(url: url, headers: credential.headers(for: url))
            defer { bytes.task.cancel() }
            var parser = M3UPlaylistParser(
                baseURL: response.url ?? credential.address, permitsAuthenticationHeaders: true
            ).makeCatalogStream()
            defer { diagnostic?.record(playlistBytes: parser.byteCount) }
            var chunk = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 16_384 {
                    try parser.append(chunk)
                    if !parser.takeCatalogEntries().isEmpty || parser.hasPlayableHLSTag { return }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try parser.append(chunk)
            if parser.hasPlayableHLSTag { return }
            let result = try parser.finish()
            guard result.entryCount == 0 || !parser.takeCatalogEntries().isEmpty else {
                diagnostic?.record(entries: 0, skippedEntries: result.skippedEntryCount)
                throw IPTVError.empty
            }
            return
        }
        let response = try await object(url: endpoint())
        let user = response.object("user_info")
        guard user.integer("auth") == 1 else { throw IPTVError.authentication }
        if let status = user.text("status"), status.lowercased() != "active" { throw IPTVError.expired }
        if let expiry = user.number("exp_date"), expiry > 0, expiry <= Date().timeIntervalSince1970 {
            throw IPTVError.expired
        }
        let formats = user.array("allowed_output_formats").compactMap(\.text)
        liveExtension = formats.contains("m3u8") ? "m3u8" : "ts"
        authenticatedAt = Date()
    }

    func ensureCatalog(_ library: String, force: Bool = false) async throws {
        try reclaimJournalOnce()
        if credential.mode == .file {
            try await authenticate()
            return
        }
        let scope = credential.mode == .playlist ? Self.playlistCatalogScope : library
        while true {
            try Task.checkCancellation()
            // Freshness controls revalidation, not availability of committed data.
            // Missing or old-schema catalogues must still finish their first import.
            if !force, let committedAt = try catalogCommittedAt(scope) {
                let needsGuideDiscovery = try credential.mode == .playlist
                    && !credential.automaticallyDiscoversGuides && credential.explicitGuideURLs.isEmpty
                    && catalog.state(Self.playlistCatalogScope) == nil
                let ceiling: TimeInterval = credential.mode == .xtream && scope == "live" ? Self.maximumSavedLiveLineupAge : 1_800
                let refreshesWhenRead = Date().timeIntervalSince(committedAt) >= ceiling
                if needsGuideDiscovery || refreshesWhenRead, refresh == nil,
                   refreshRetryAfter[scope].map({ $0 <= Date() }) != false {
                    startRefresh(library, scope: scope, background: true)
                }
                return
            }
            if refresh != nil {
                let sameScope = refreshScope == scope
                try await waitForRefresh()
                if sameScope { return }
            } else {
                startRefresh(library, scope: scope, background: false)
                try await waitForRefresh()
                return
            }
        }
    }

    /// Downloads the account's live lineup again once the saved one is older than
    /// `interval`. Returns when it next falls due; nil when no lineup has been saved, which
    /// is never downloaded here for the first time.
    func refreshSavedLiveLineup(olderThan interval: TimeInterval) async throws -> Date? {
        guard credential.mode == .xtream, let committedAt = try catalogCommittedAt("live") else { return nil }
        guard Date().timeIntervalSince(committedAt) >= interval else {
            return committedAt.addingTimeInterval(interval)
        }
        while refresh != nil {
            let isLive = refreshScope == "live"
            do { try await waitForRefresh() }
            catch {
                try Task.checkCancellation()
                if isLive { throw error }
            }
            if isLive { return (try catalogCommittedAt("live") ?? Date()).addingTimeInterval(interval) }
        }
        try Task.checkCancellation()
        if let retry = refreshRetryAfter["live"], retry > Date() { return retry }
        startRefresh("live", scope: "live", background: true)
        try await waitForRefresh()
        return (try catalogCommittedAt("live") ?? Date()).addingTimeInterval(interval)
    }

    private func startRefresh(_ library: String, scope: String, background: Bool) {
        refreshScope = scope
        refreshHasBackgroundOwner = background
        refresh = Task {
            let started = ContinuousClock.now
            let diagnosticIDs: [LiveTVSourceDiagnostics.Identity: String] = [
                .catalog: credential.identity.uuidString, .request: UUID().uuidString
            ]
            LiveTVSourceDiagnostics.shared.record(
                .catalogRefreshStarted, identities: diagnosticIDs, flags: [.background: background]
            )
            let performance = PerformanceDiagnostics.shared.begin(.playlistImport, provider: .iptv)
            let metrics = IPTVPerformanceMetrics()
            HandoffDiagnostics.emit("IPTV catalogRefresh begin background=\(background) library=\(scope == Self.playlistCatalogScope ? "playlist" : library)")
            let result: Result<Void, Error>
            do {
                try await IPTVHTTP.$performanceMetrics.withValue(metrics) {
                    try await self.importCatalog(library)
                }
                self.refreshRetryAfter[scope] = nil
                result = .success(())
                performance?.finish(.succeeded, metrics: metrics.snapshot)
                recordCatalogRefresh(diagnosticIDs, metrics: metrics, started: started, error: nil)
                HandoffDiagnostics.emit("IPTV catalogRefresh complete elapsed=\(started.duration(to: .now))")
            } catch {
                self.refreshRetryAfter[scope] = error is CancellationError ? nil : Date().addingTimeInterval(60)
                performance?.finish(
                    IPTVPerformanceMetrics.outcome(for: error), metrics: metrics.snapshot
                )
                let reason = IPTVSetupDiagnostic.Failure.sanitized(error).reason.rawValue
                recordCatalogRefresh(diagnosticIDs, metrics: metrics, started: started, error: error)
                PlozzLog.networking.error("IPTV catalogue refresh failed reason=\(reason)")
                HandoffDiagnostics.emit("IPTV catalogRefresh failed reason=\(reason) elapsed=\(started.duration(to: .now))")
                result = .failure(error)
            }
            if awaitsLegacyGuideDiscovery == true, scope == Self.playlistCatalogScope {
                guideDiscoveryResult = result
            }
            self.refresh = nil
            self.refreshScope = nil
            self.refreshHasBackgroundOwner = false
            let waiters = self.refreshWaiters.values
            self.refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume(with: result) }
        }
    }

    private func recordCatalogRefresh(
        _ identities: [LiveTVSourceDiagnostics.Identity: String], metrics: IPTVPerformanceMetrics,
        started: ContinuousClock.Instant, error: (any Error)?
    ) {
        let snapshot = metrics.snapshot
        let elapsed = started.duration(to: .now).components
        LiveTVSourceDiagnostics.shared.record(
            .catalogRefreshFinished, identities: identities,
            counts: [
                .entries: snapshot.items ?? 0, .bytes: snapshot.bytes ?? 0, .requests: snapshot.requests ?? 0,
                .elapsedMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                .waiters: refreshWaiters.count
            ],
            flags: [.failed: error != nil, .cancelled: Task.isCancelled], error: error
        )
    }

    private func catalogCommittedAt(_ scope: String) throws -> Date? {
        // v4 channels remain usable while the retired guide opt-out is refreshed in the background.
        var raw = try catalog.state(scope)
        if raw == nil, scope == Self.playlistCatalogScope { raw = try catalog.state("playlist-v4") }
        guard let raw, let time = TimeInterval(raw), time.isFinite else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    private func waitForRefresh() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                refreshWaiters[id] = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelRefreshWaiter(id) }
        }
    }

    private func cancelRefreshWaiter(_ id: UUID) {
        refreshWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if refreshWaiters.isEmpty, !refreshHasBackgroundOwner { refresh?.cancel() }
    }

    private func importCatalog(_ library: String) async throws {
        let admission = try await acquireRefreshWork(.catalog)
        defer { releaseRefreshWork(admission) }
        let diagnostic = IPTVSetupDiagnostics.current
        if credential.mode == .xtream,
           authenticatedAt.map({ Date().timeIntervalSince($0) > 300 }) != false {
            try await authenticate()
        }
        diagnostic?.advance(to: credential.mode == .playlist ? .playlist
            : library == "movies" ? .movies : library == "series" ? .series : .channels)
        let importID = try catalog.beginImport()
        defer {
            catalog.discardImport(importID)
            didReclaimJournal = false
        }
        if credential.mode == .playlist {
            try await importPlaylist(importID: importID)
        } else {
            let action: String
            switch library {
            case "movies": action = "get_vod_streams"
            case "series": action = "get_series"
            case "live": action = "get_live_streams"
            default: throw IPTVError.unsupported
            }
            let stage: IPTVImportProgress.Stage = library == "movies" ? .movies : library == "series" ? .series : .channels
            progress(IPTVImportProgress(stage: stage, entries: 0))
            let categories = try await categories(library: library)
            var count = 0
            var unnamedCount = 0
            defer {
                diagnostic?.record(entries: count)
                IPTVHTTP.performanceMetrics?.record(items: count)
            }
            var parser = IPTVJSONArrayStream()
            try await read(url: endpoint(action: action)) { data in
                try catalog.checkImport(importID)
                try parser.append(data) { bytes in
                    let value = try JSONDecoder().decode(IPTVObject.self, from: bytes)
                    try store(IPTVMapping.listEntry(value, library: library, categories: categories), into: .incoming)
                    if value.text("name") == nil { unnamedCount += 1 }
                    count += 1
                    if count.isMultiple(of: 1_000) { progress(IPTVImportProgress(stage: stage, entries: count)) }
                }
            }
            try parser.finish()
            if unnamedCount > 0 {
                PlozzLog.networking.info("IPTV catalogue contains \(unnamedCount) unnamed entries; using source IDs for display")
            }
            progress(IPTVImportProgress(stage: stage, entries: count))
        }
        try catalog.checkImport(importID)
        diagnostic?.advance(to: .catalogCommit)
        try catalog.commitImport(
            library: credential.mode == .playlist ? nil : library,
            scope: credential.mode == .playlist ? Self.playlistCatalogScope : library
        ) { progress(IPTVImportProgress(stage: .catalogCommit, entries: $0)) }
        if credential.mode == .playlist || library == "live" { prepareLiveLineup() }
    }

    private func categories(library: String) async throws -> [String: String] {
        let action = library == "movies" ? "get_vod_categories"
            : library == "series" ? "get_series_categories" : "get_live_categories"
        var result: [String: String] = [:]
        var parser = IPTVJSONArrayStream()
        do {
            try await read(url: endpoint(action: action)) { data in
                try parser.append(data) { bytes in
                    let value = try JSONDecoder().decode(IPTVObject.self, from: bytes)
                    guard let id = value.text("category_id"), let name = value.text("category_name") else {
                        throw IPTVError.malformed
                    }
                    result[id] = name
                }
            }
            try parser.finish()
        } catch AppError.notFound {
            PlozzLog.networking.info("IPTV provider does not expose category names")
        }
        return result
    }

    func importFile(_ url: URL) async throws {
        guard credential.mode == .file, url.isFileURL else { throw IPTVError.invalidAddress }
        let performance = PerformanceDiagnostics.shared.begin(.playlistImport, provider: .iptv)
        let metrics = performance == nil ? nil : IPTVPerformanceMetrics()
        do {
            try await IPTVHTTP.$performanceMetrics.withValue(metrics) {
                try await importFileContents(url)
            }
            performance?.finish(.succeeded, metrics: metrics?.snapshot ?? .init())
        } catch {
            performance?.finish(IPTVPerformanceMetrics.outcome(for: error), metrics: metrics?.snapshot ?? .init())
            throw error
        }
    }

    private func importFileContents(_ url: URL) async throws {
        IPTVSetupDiagnostics.current?.advance(to: .playlist)
        let importID = try catalog.beginImport()
        defer { catalog.discardImport(importID) }
        try await importPlaylist(fileURL: url, importID: importID)
        try catalog.checkImport(importID)
        IPTVSetupDiagnostics.current?.advance(to: .catalogCommit)
        try catalog.commitImport(library: nil, scope: "playlist") {
            progress(IPTVImportProgress(stage: .catalogCommit, entries: $0))
        }
        prepareLiveLineup()
    }

    private func importPlaylist(fileURL: URL? = nil, importID: UUID) async throws {
        let diagnostic = IPTVSetupDiagnostics.current
        let origin: URL
        let bytes: URLSession.AsyncBytes?
        if fileURL != nil {
            origin = credential.address
            bytes = nil
        } else {
            let url = GoogleDrivePlaylistURL.downloadURL(for: credential.address)
            let response = try await http.bytes(url: url, headers: credential.headers(for: url))
            bytes = response.0
            origin = response.1.url ?? credential.address
        }
        defer { bytes?.task.cancel() }
        var parser = M3UPlaylistParser(
            baseURL: fileURL == nil ? origin : nil, permitsAuthenticationHeaders: true
        ).makeCatalogStream()
        var chunk = Data()
        var count = 0
        defer {
            diagnostic?.record(entries: count, playlistBytes: parser.byteCount)
            IPTVHTTP.performanceMetrics?.record(items: count, bytes: parser.byteCount)
        }
        progress(IPTVImportProgress(stage: .playlist, entries: 0))
        func persist(_ entries: [M3UPlaylistParser.CatalogEntry]) throws {
            try catalog.checkImport(importID)
            for entry in entries {
                for record in IPTVMapping.playlistEntry(entry) {
                    try store(record, overwrite: record.item.kind != .series && record.item.kind != .season, into: .incoming)
                }
                count += 1
                if count.isMultiple(of: 10_000) {
                    LiveTVSourceDiagnostics.shared.record(
                        .catalogProgress, identities: [.catalog: credential.identity.uuidString],
                        counts: [.entries: count, .bytes: parser.byteCount]
                    )
                }
                if count.isMultiple(of: 1_000) { progress(IPTVImportProgress(stage: .playlist, entries: count)) }
            }
        }
        if let fileURL {
            let file = try FileHandle(forReadingFrom: fileURL)
            defer {
                do { try file.close() }
                catch { PlozzLog.networking.error("IPTV playlist file could not be closed") }
            }
            while let data = try file.read(upToCount: 65_536), !data.isEmpty {
                try Task.checkCancellation()
                try parser.append(data)
                try persist(parser.takeCatalogEntries())
                await Task.yield()
            }
        } else if let bytes {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 65_536 {
                    try Task.checkCancellation()
                    try parser.append(chunk)
                    try persist(parser.takeCatalogEntries())
                    chunk.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }
        }
        try parser.append(chunk)
        do {
            let result = try parser.finish()
            diagnostic?.record(skippedEntries: result.skippedEntryCount)
            try persist(parser.takeCatalogEntries())
            progress(IPTVImportProgress(stage: .playlist, entries: count))
            // Addresses are kept in a sealed catalogue record, never plaintext state.
            let guides = credential.explicitGuideURLs.isEmpty
                ? result.declaredGuideURLs : credential.explicitGuideURLs
            for (index, guide) in guides.prefix(32).enumerated() {
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: String(format: "guide:%02d", index), title: "", kind: .unknown),
                    streamURL: guide
                ), into: .incoming)
            }
            if guides.count > 32 { PlozzLog.networking.error("IPTV playlist declared more than 32 guides") }
            if result.entryCount > 0,
               try catalog.count(where: "kind != ?", values: [MediaItemKind.unknown.rawValue], in: .incoming) == 0 {
                throw IPTVError.empty
            }
        } catch LiveTVSourceImportError.streamManifest {
            guard fileURL == nil, parser.hasPlayableHLSTag else { throw IPTVError.unsupported }
            try catalog.execute("DELETE FROM incoming")
            try catalog.insert(IPTVRecord(
                item: MediaItem(id: "live:direct", title: origin.host ?? "IPTV", kind: .video, libraryID: "live"),
                streamURL: origin, isLive: true
            ), into: .incoming)
        }
    }

    func page(library: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await ensureCatalog(library)
        guard page.filters.isEmpty else { throw IPTVError.unsupported }
        let field: String
        switch page.sort.field {
        case .name: field = "title COLLATE NOCASE"
        case .dateAdded: field = "added"
        case .year: field = "year"
        default: throw IPTVError.unsupported
        }
        let values = [library, kind.rawValue]
        let predicate = "library = ? AND kind = ?"
        let order = field + (page.sort.direction == .descending ? " DESC" : " ASC") + ", id"
        let records = try catalog.records(where: predicate, values: values, order: order,
                                          start: page.startIndex, limit: page.limit)
        return MediaPage(items: records.map(\.item), startIndex: page.startIndex,
                         totalCount: try catalog.count(where: predicate, values: values))
    }

    func record(_ id: String, details: Bool = false) async throws -> IPTVRecord {
        let library = id.hasPrefix("movie:") ? "movies"
            : (id.hasPrefix("series:") || id.hasPrefix("season:") || id.hasPrefix("episode:")) ? "series" : "live"
        try await ensureCatalog(library)
        var record: IPTVRecord
        do { record = try catalog.record(id) }
        catch AppError.notFound {
            let parts = id.split(separator: ":")
            guard credential.mode == .xtream, parts.count == 3,
                  parts[0] == "episode" || parts[0] == "season" else { throw AppError.notFound }
            try await loadSeries(catalog.record("series:" + parts[1]))
            record = try catalog.record(id)
        }
        if details, credential.mode == .xtream, let nativeID = record.streamID {
            if record.item.kind == .movie {
                let data = try await object(url: endpoint(action: "get_vod_info", extra: [
                    URLQueryItem(name: "vod_id", value: nativeID)
                ]))
                record = IPTVMapping.enrich(record, with: data.object("info"))
                if let container = data.object("movie_data").text("container_extension") { record.container = container }
                if let refresh { try await refresh.value }
                record = sanitizedArtwork(record)
                try store(record)
            } else if record.item.kind == .series {
                try await loadSeries(record)
                record = try catalog.record(id)
            }
        }
        return record
    }

    private func loadSeries(_ series: IPTVRecord) async throws {
        guard let nativeID = series.streamID else { throw AppError.notFound }
        let data = try await object(url: endpoint(action: "get_series_info", extra: [
            URLQueryItem(name: "series_id", value: nativeID)
        ]))
        let episodes: IPTVObject
        switch data["episodes"] {
        case .object(let values): episodes = values
        case .array(let values) where values.isEmpty: episodes = [:]
        default: throw IPTVError.malformed
        }
        if let refresh { try await refresh.value }
        try catalog.execute("BEGIN IMMEDIATE")
        do {
            let enriched = IPTVMapping.enrich(series, with: data.object("info"))
            try store(enriched)
            for (seasonKey, values) in episodes {
                guard let seasonNumber = Int(seasonKey), seasonNumber >= 0,
                      seasonNumber <= 10_000, case .array(let entries) = values else { throw IPTVError.malformed }
                let season = IPTVMapping.season(enriched, number: seasonNumber)
                try store(season)
                for entry in entries {
                    try Task.checkCancellation()
                    try store(IPTVMapping.episode(entry.object, series: enriched, season: season))
                }
            }
            try catalog.execute("COMMIT")
        } catch {
            do { try catalog.execute("ROLLBACK") }
            catch { PlozzLog.networking.error("IPTV series rollback failed") }
            throw error
        }
    }

    func children(_ id: String) async throws -> [MediaItem] {
        var parent = try await record(id)
        if credential.mode == .xtream {
            if parent.item.kind == .season, let seriesID = parent.item.seriesID { parent = try await record(seriesID) }
            if parent.item.kind == .series { try await loadSeries(parent) }
        }
        var result: [MediaItem] = []
        while true {
            let page = try catalog.records(where: "parent = ?", values: [id],
                                           order: "ordinal, id", start: result.count, limit: 200)
            result += page.map(\.item)
            if page.count < 200 { return result }
            try Task.checkCancellation()
        }
    }

    func search(_ query: String, libraries: [String], limit: Int) async throws -> [MediaItem] {
        var result: [MediaItem] = []
        guard limit > 0 else { return result }
        for library in libraries {
            try await ensureCatalog(library)
            result += try catalog.records(where: "library = ? AND instr(lower(title), lower(?)) > 0 AND kind IN ('movie','series')",
                                          values: [library, query], limit: limit - result.count).map(\.item)
            if result.count >= limit { break }
        }
        return result
    }

    func liveChannelCount() async throws -> Int {
        try await ensureCatalog("live")
        return try catalog.count(where: "live = 1")
    }

    func hasItems(in library: String, kind: MediaItemKind) async throws -> Bool {
        try await ensureCatalog(library)
        return try catalog.count(where: "library = ? AND kind = ?", values: [library, kind.rawValue]) > 0
    }

    func liveChannels() async throws -> [ServerLiveTVChannel] {
        try await ensureCatalog("live")
        return try committedLiveChannels()
    }

    func guideCatalogRevision() throws -> String? {
        if let revision = try catalog.state("live-revision") { return revision }
        return try catalog.state("live").map { "legacy:\($0)" }
    }

    func guideChannels() async throws -> [IPTVProvider.IPTVGuideChannel] {
        try await ensureCatalog("live")
        return try committedGuideChannels()
    }

    /// The committed lineup as guide channels, without starting a catalogue refresh. Nil
    /// until a lineup has been committed.
    func savedGuideChannels() throws -> [IPTVProvider.IPTVGuideChannel]? {
        let scope = credential.mode == .xtream ? "live" : Self.playlistCatalogScope
        let committed = credential.mode == .file
            ? try catalog.state("playlist") != nil : try catalogCommittedAt(scope) != nil
        return committed ? try committedGuideChannels() : nil
    }

    /// The part of the committed lineup that guide lookups need, prepared once per lineup.
    struct SavedGuideLineup: Sendable {
        /// Changes whenever the lineup does.
        let revision: String
        /// Only channels with a guide ID; the others cannot have listings.
        let guided: [String: IPTVProvider.IPTVGuideChannel]
    }

    /// Nil until a lineup has been committed. Never starts a catalogue refresh.
    func savedGuideLineup() throws -> SavedGuideLineup? {
        let dataVersion = try catalog.dataVersion()
        let revision = try guideCatalogRevision()
        if let cachedGuideLineup, cachedGuideLineup.revision == revision,
           cachedGuideLineup.dataVersion == dataVersion { return cachedGuideLineup.lineup }
        guard let channels = try savedGuideChannels() else { return nil }
        var guided: [String: IPTVProvider.IPTVGuideChannel] = [:]
        for channel in channels
        where channel.guideID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            guided[channel.id] = guided[channel.id] ?? channel
        }
        let lineup = SavedGuideLineup(
            revision: revision ?? "legacy", guided: guided
        )
        cachedGuideLineup = (revision, try catalog.dataVersion(), lineup)
        return lineup
    }

    private func committedGuideChannels() throws -> [IPTVProvider.IPTVGuideChannel] {
        let entries = try liveLineup()
        guard entries.count <= 100_000 else { throw LiveTVSourceImportError.guideTooLarge }
        return entries.map {
            IPTVProvider.IPTVGuideChannel(
                id: $0.id, name: $0.title, guideID: $0.guideID, guideName: $0.guideName, country: $0.guideCountry
            )
        }
    }

    /// Guide addresses known without contacting the provider or refreshing the catalogue.
    func savedGuideURLs() throws -> [URL] {
        if !credential.explicitGuideURLs.isEmpty { return credential.explicitGuideURLs }
        return try xtreamGuideURL().map { [$0] } ?? []
    }

    /// Channels whose own listing table came back empty are not asked again for a while:
    /// the answer rarely changes, and asking costs the subscriber one request per channel.
    func hasEmptyGuideAnswer(_ channelID: String) -> Bool {
        guard let expires = emptyGuideAnswers[channelID] else { return false }
        if expires > Date() { return true }
        emptyGuideAnswers[channelID] = nil
        return false
    }

    func rememberEmptyGuideAnswer(_ channelID: String) {
        let now = Date()
        if emptyGuideAnswers.count >= Self.maximumEmptyGuideAnswers {
            emptyGuideAnswers = emptyGuideAnswers.filter { $0.value > now }
            if emptyGuideAnswers.count >= Self.maximumEmptyGuideAnswers { emptyGuideAnswers.removeAll() }
        }
        emptyGuideAnswers[channelID] = now.addingTimeInterval(Self.emptyGuideAnswerLifetime)
    }

    /// How long guide requests should stay away after `error`; nil when it is not the
    /// provider asking for fewer requests. `failures` counts consecutive refusals.
    static func guideBackoffDelay(after error: any Error, failures: Int) -> TimeInterval? {
        let stated: TimeInterval?
        switch error {
        case AppError.rateLimited(let retryAfter): stated = retryAfter
        case IPTVError.httpStatus(let status) where [502, 503, 504].contains(status): stated = nil
        default: return nil
        }
        let own = min(maximumGuideBackoff, firstGuideBackoff * pow(2, Double(min(max(failures, 1), 8) - 1)))
        guard let stated, stated.isFinite, stated > 0 else { return own }
        return max(own, min(stated, 86_400))
    }

    // Read one indexed state row, never the lineup. Storage failures cannot deny a request.
    private func restoreGuideBackoffOnce() {
        guard !didReadGuideBackoff else { return }
        didReadGuideBackoff = true
        do {
            guard let raw = try catalog.state(Self.guideBackoffStateKey) else { return }
            let saved = try JSONDecoder().decode(SavedGuideBackoff.self, from: Data(raw.utf8))
            guard saved.deadline.isFinite, saved.failures > 0, saved.failures < Int.max,
                  saved.grantedDelay.isFinite, saved.grantedDelay > 0, saved.grantedDelay <= 86_400,
                  saved.deadline - Date().timeIntervalSince1970 <= saved.grantedDelay,
                  [429, 502, 503, 504].contains(saved.status) else {
                try? catalog.removeState(Self.guideBackoffStateKey)
                return
            }
            let error: any Error = saved.status == 429
                ? AppError.rateLimited(retryAfter: nil) : IPTVError.httpStatus(saved.status)
            guideBackoff = (Date(timeIntervalSince1970: saved.deadline), saved.failures, error)
        } catch {
            try? catalog.removeState(Self.guideBackoffStateKey)
        }
    }

    private func saveGuideBackoff(grantedDelay: TimeInterval) {
        guard let backoff = guideBackoff else { return }
        let status: Int
        switch backoff.error {
        case AppError.rateLimited: status = 429
        case IPTVError.httpStatus(let code): status = code
        default: return
        }
        let saved = SavedGuideBackoff(
            deadline: backoff.until.timeIntervalSince1970, failures: backoff.failures,
            status: status, grantedDelay: grantedDelay
        )
        if let data = try? JSONEncoder().encode(saved), let raw = String(data: data, encoding: .utf8) {
            try? catalog.setState(Self.guideBackoffStateKey, raw)
        }
    }

    /// Fails without a request while the provider's last overload answer still applies.
    private func checkGuideBackoff() throws {
        restoreGuideBackoffOnce()
        guard let backoff = guideBackoff else { return }
        guard backoff.until > Date() else { return }
        IPTVGuideDiagnostics.request?.reuseGuideFailure()
        throw backoff.error
    }

    private func noteGuideOutcome(_ error: (any Error)?) {
        guard let error else {
            // Only a back-off that was set has saved state to remove.
            if guideBackoff != nil { try? catalog.removeState(Self.guideBackoffStateKey) }
            guideBackoff = nil
            return
        }
        let failures = min(guideBackoff?.failures ?? 0, Int.max - 2) + 1
        guard let delay = Self.guideBackoffDelay(after: error, failures: failures) else { return }
        guideBackoff = (Date().addingTimeInterval(delay), failures, error)
        saveGuideBackoff(grantedDelay: delay)
        PlozzLog.networking.info("IPTV_GUIDE event=backoff failures=\(failures) seconds=\(Int(delay))")
    }

    func cachedLiveTVCatalog() throws -> ServerLiveTVCatalogSnapshot? {
        let scope = credential.mode == .xtream ? "live" : Self.playlistCatalogScope
        let committed = credential.mode == .file
            ? try catalog.state("playlist") != nil : try catalogCommittedAt(scope) != nil
        LiveTVSourceDiagnostics.shared.record(
            .catalogRead, identities: [.catalog: credential.identity.uuidString],
            flags: [.committed: committed], deduplicate: true
        )
        guard committed else { return nil }
        if credential.mode == .xtream, let savedAt = try catalogCommittedAt("live"),
           Date().timeIntervalSince(savedAt) >= Self.maximumSavedLiveLineupAge, refresh == nil,
           refreshRetryAfter["live"].map({ $0 <= Date() }) != false {
            startRefresh("live", scope: "live", background: true)
        }
        let supportsGuide = try credential.mode == .xtream || !credential.explicitGuideURLs.isEmpty
            || catalog.count(where: "kind = ?", values: [MediaItemKind.unknown.rawValue]) > 0
        return try ServerLiveTVCatalogSnapshot(channels: committedLiveChannels(), supportsGuide: supportsGuide)
    }

    private func committedLiveChannels() throws -> [ServerLiveTVChannel] {
        try liveLineup().enumerated().map { index, entry in
            ServerLiveTVChannel(
                id: entry.id, name: entry.title,
                number: entry.channelNumber.map(String.init) ?? String(index + 1),
                imageURL: entry.posterURL, groups: entry.tags
            )
        }
    }

    /// The live lineup in catalogue order. Opening every sealed record costs seconds on a
    /// large lineup, so it is done once per catalogue state and then served from the saved copy.
    private func liveLineup() throws -> [IPTVLineupEntry] {
        let dataVersion = try catalog.dataVersion()
        if let cachedLineup, cachedLineup.revision == (try catalog.state("live-revision")),
           cachedLineup.dataVersion == dataVersion { return cachedLineup.entries }
        let token = try liveLineupToken()
        var entries: [IPTVLineupEntry]
        if let saved = try catalog.lineup(token: token) { entries = saved }
        else {
            entries = []
            try catalog.execute("BEGIN")
            do {
                while true {
                    try Task.checkCancellation()
                    let page = try catalog.records(where: "live = 1", values: [], start: entries.count, limit: 1_000)
                    entries += page.map(IPTVLineupEntry.init)
                    if page.count < 1_000 { break }
                }
                try catalog.execute("COMMIT")
            } catch {
                try catalog.execute("ROLLBACK")
                throw error
            }
            // The saved copy is an optimisation; the sealed records stay authoritative.
            do { try catalog.saveLineup(entries, token: token) }
            catch { PlozzLog.networking.error("IPTV lineup copy could not be saved") }
        }
        cachedLineup = ((try catalog.state("live-revision")), dataVersion, entries)
        return entries
    }

    /// Identifies the committed catalogue a saved lineup was read from, so a copy left by
    /// a build that does not maintain it is never mistaken for the current lineup.
    private func liveLineupToken() throws -> String {
        let scopes = ["live", Self.playlistCatalogScope, "playlist", "playlist-v4"]
        let committed = try scopes.map { try catalog.state($0) ?? "" }
        return (committed + [String(try catalog.count(where: "live = 1"))]).joined(separator: "|")
    }

    /// Reads the lineup once after an import so the next Live TV open does not pay for it.
    private func prepareLiveLineup() {
        do { _ = try liveLineup() }
        catch { PlozzLog.networking.info("IPTV lineup copy was not prepared") }
    }

    func delivery(_ id: String) async throws -> (url: URL, headers: [String: String], formatHint: MediaFormatHint) {
        let record = try await record(id)
        let url: URL
        if let address = record.streamURL { url = address }
        else if let nativeID = record.streamID {
            if authenticatedAt.map({ Date().timeIntervalSince($0) > 300 }) != false { try await authenticate() }
            let group = record.isLive ? "live" : record.item.kind == .episode ? "series" : "movie"
            let fileExtension = record.isLive ? liveExtension : record.container ?? "mp4"
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let parts = [group, credential.username, credential.password, nativeID + "." + fileExtension]
            let encoded = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
            guard encoded.count == parts.count,
                  var components = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false) else {
                throw IPTVError.malformed
            }
            let basePath = components.percentEncodedPath.split(separator: "/").joined(separator: "/")
            let streamPath = encoded.joined(separator: "/")
            components.percentEncodedPath = basePath.isEmpty ? "/\(streamPath)" : "/\(basePath)/\(streamPath)"
            guard let result = components.url else { throw IPTVError.malformed }
            url = result
        } else { throw AppError.notFound }
        var headers = credential.headers(for: url)
        for (key, value) in record.headers {
            headers = headers.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
            headers[key] = value
        }
        try IPTVCredential.validate(headers: headers)
        var container: String?
        if record.isLive, credential.mode == .playlist, url.pathExtension.isEmpty {
            let outputs = URLComponents(url: credential.address, resolvingAgainstBaseURL: false)?
                .queryItems?.filter { $0.name.lowercased() == "output" } ?? []
            if outputs.count == 1, let output = outputs.first?.value?.lowercased(),
               ["ts", "m3u8"].contains(output) {
                container = output
            }
        }
        return (url, headers, MediaFormatHint(container: container))
    }

    func guideURLs() async throws -> [URL] {
        if !credential.explicitGuideURLs.isEmpty { return credential.explicitGuideURLs }
        if let url = try xtreamGuideURL() { return [url] }
        try await ensureCatalog("live")
        let guides = try catalog.records(where: "kind = ?", values: [MediaItemKind.unknown.rawValue], order: "id", limit: 32)
            .compactMap(\.streamURL)
        guard guides.allSatisfy(LiveTVPlaylistSource.isSupportedURL) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        return guides
    }

    func xtreamGuideURL() throws -> URL? {
        credential.mode == .xtream ? try endpoint(file: "xmltv.php") : nil
    }

    func hasGuideSource() async throws -> Bool {
        if credential.mode == .xtream || !credential.explicitGuideURLs.isEmpty { return true }
        try await ensureCatalog("live")
        return try catalog.count(where: "kind = ?", values: [MediaItemKind.unknown.rawValue]) > 0
    }

    func completeGuideDiscovery() async throws -> Bool? {
        try reclaimJournalOnce()
        guard awaitsLegacyGuideDiscovery == true else { return nil }
        if refresh != nil, refreshScope == Self.playlistCatalogScope {
            try await waitForRefresh()
        } else {
            guard let guideDiscoveryResult else { return nil }
            try guideDiscoveryResult.get()
        }
        try Task.checkCancellation()
        return try catalog.count(where: "kind = ?", values: [MediaItemKind.unknown.rawValue]) > 0
    }

    /// The ID the provider files this channel's listings under; nil when it has none.
    func guideID(for channelID: String) async throws -> String? {
        let id = try await record(channelID).guideID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return id?.isEmpty == false ? id : nil
    }

    func guide(channelID: String, from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard credential.mode == .xtream else { return [] }
        let channel = try await record(channelID)
        guard let nativeID = channel.streamID else { throw AppError.notFound }
        try checkGuideBackoff()
        let admission = try await acquireRefreshWork(.guide)
        defer { releaseRefreshWork(admission) }
        let data: IPTVObject
        do {
            data = try await object(url: endpoint(action: "get_simple_data_table", extra: [
                URLQueryItem(name: "stream_id", value: nativeID)
            ]))
        } catch {
            if !Task.isCancelled { noteGuideOutcome(error) }
            throw error
        }
        guard !isClosed else { throw CancellationError() }
        if data.object("user_info").integer("auth") == 0 || data.integer("auth") == 0 {
            throw IPTVError.authentication
        }
        guard case .array(let listings) = data["epg_listings"] else { throw IPTVError.malformed }
        noteGuideOutcome(nil)
        if listings.isEmpty { rememberEmptyGuideAnswer(channelID) }
        return listings.compactMap {
            IPTVMapping.programme($0.object, channelID: channelID, from: from, to: to)
        }
    }

    private func currentGuideRefresh() -> GuideRefreshState? {
        guideRefreshes = guideRefreshes.filter { $0.value.scope != nil }
        guard let scope = ServerLiveTVGuideRefreshScope.current else { return nil }
        let key = ObjectIdentifier(scope)
        let state = guideRefreshes[key] ?? GuideRefreshState(scope: scope)
        guideRefreshes[key] = state
        return state
    }

    func guideData(from url: URL) async throws -> Data {
        try await guideDocument(from: url, retainsRawResponse: true).data
    }

    func guideDocument(from url: URL, retainsRawResponse: Bool = false) async throws -> XMLTVDownloadedDocument {
        let response = try await guideResponse(from: url, retainsRawResponse: retainsRawResponse)
        guard case .document(let document) = response else { throw IPTVError.malformed }
        return document
    }

    func guideResponse(
        from url: URL, previous: XMLTVGuideCacheMetadata? = nil, retainsRawResponse: Bool = false
    ) async throws -> XMLTVGuideResponse {
        try Task.checkCancellation()
        try storageLifecycle.checkAccess()
        guard !isClosed else { throw CancellationError() }
        let refresh = currentGuideRefresh()
        if refresh?.missingURLs.contains(url) == true {
            IPTVGuideDiagnostics.request?.reuseGuideFailure()
            throw AppError.notFound
        }
        if let failure = refresh?.rejectedURLs[url] {
            IPTVGuideDiagnostics.request?.reuseGuideFailure()
            throw failure
        }
        try checkGuideBackoff()
        do {
            let response = try await retriedGuideResponse(
                from: url, previous: previous, retainsRawResponse: retainsRawResponse, refresh: refresh
            )
            noteGuideOutcome(nil)
            return response
        } catch {
            switch error {
            case AppError.notFound, IPTVError.unsupported:
                if credential.mode == .xtream, credential.explicitGuideURLs.isEmpty,
                   url == (try? xtreamGuideURL()) { batchGuideUnavailable = true }
            default: break
            }
            if !Task.isCancelled { noteGuideOutcome(error) }
            throw error
        }
    }

    private func retriedGuideResponse(
        from url: URL, previous: XMLTVGuideCacheMetadata?, retainsRawResponse: Bool, refresh: GuideRefreshState?
    ) async throws -> XMLTVGuideResponse {
        do {
            var attempt = 0
            var validators = previous
            var usedOrdinaryFallback = false
            while true {
                let attemptValidators = validators
                let responsePolicy = OSAllocatedUnfairLock<(retryAfter: TimeInterval?, fallbackStatus: Int?)>(
                    initialState: (nil, nil)
                )
                do {
                    return try await downloadGuideData(
                        from: url, previous: attemptValidators, retainsRawResponse: retainsRawResponse
                    ) { response in
                        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                        let canFallBack = attemptValidators?.hasValidator == true
                            && attemptValidators?.permitsPersistence == true
                            && attemptValidators?.responseURL == response.url
                            && retryAfter == nil && [400, 405, 412, 431, 501].contains(response.statusCode)
                        responsePolicy.withLock {
                            $0 = (HTTPDate.retryAfter(retryAfter), canFallBack ? response.statusCode : nil)
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    let policy = responsePolicy.withLock { $0 }
                    if !usedOrdinaryFallback, let status = policy.fallbackStatus {
                        validators = nil
                        usedOrdinaryFallback = true
                        PlozzLog.networking.info("IPTV_GUIDE event=conditionalFallback status=\(status)")
                        continue
                    }
                    guard !usedOrdinaryFallback else { throw error }
                    guard let delay = Self.guideRetryDelay(
                        after: error, attempt: attempt, retryAfter: policy.retryAfter
                    ) else { throw error }
                    attempt += 1
                    PlozzLog.networking.info("IPTV_GUIDE event=retry attempt=\(attempt) delaySeconds=\(delay)")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        } catch AppError.notFound {
            try Task.checkCancellation()
            refresh?.missingURLs.insert(url)
            throw AppError.notFound
        } catch LiveTVSourceImportError.guideTooLarge {
            try Task.checkCancellation()
            refresh?.rejectedURLs[url] = .guideTooLarge
            throw LiveTVSourceImportError.guideTooLarge
        }
    }

    static func guideRetryDelay(after error: any Error, attempt: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        guard (0..<2).contains(attempt) else { return nil }
        let transient: Bool
        switch error {
        case AppError.rateLimited: transient = true
        case IPTVError.httpStatus(let status): transient = [408, 500, 502, 503, 504].contains(status)
        default:
            let error = error as NSError
            transient = error.domain == NSURLErrorDomain
                && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(error.code)
        }
        guard transient else { return nil }
        if let retryAfter {
            guard retryAfter.isFinite, retryAfter <= 10 else { return nil }
            return max(1, retryAfter)
        }
        return Double(1 << attempt)
    }

    func discardInvalidGuideData(from url: URL, failure: LiveTVSourceImportError) {
        guard failure == .invalidGuide || failure == .guideTooLarge else { return }
        // Parser size failures can depend on the selected channels/window's
        // retained rows. They must not reject another batch using the same URL.
        if failure == .invalidGuide { currentGuideRefresh()?.rejectedURLs[url] = failure }
        guard cachedGuide?.url == url else { return }
        clearGuideCache()
    }

    private func downloadGuideData(
        from url: URL, previous: XMLTVGuideCacheMetadata?, retainsRawResponse: Bool,
        receivedResponse: @escaping @Sendable (HTTPURLResponse) -> Void
    ) async throws -> XMLTVGuideResponse {
        if retainsRawResponse, let cachedGuide, cachedGuide.url == url, cachedGuide.expires > Date() {
            IPTVGuideDiagnostics.request?.cacheHit(bytes: cachedGuide.data.count)
            return .document(XMLTVDownloadedDocument(data: cachedGuide.data, expiresAt: cachedGuide.expires, permitsPersistence: true))
        }
        let admission = try await acquireRefreshWork(.guide)
        defer { releaseRefreshWork(admission) }
        // Another admitted reader may have populated the cache while this one waited.
        if retainsRawResponse, let cachedGuide, cachedGuide.url == url, cachedGuide.expires > Date() {
            IPTVGuideDiagnostics.request?.cacheHit(bytes: cachedGuide.data.count)
            return .document(XMLTVDownloadedDocument(data: cachedGuide.data, expiresAt: cachedGuide.expires, permitsPersistence: true))
        }
        let (bytes, response) = try await http.bytes(
            url: url, headers: credential.guideHeaders(for: url), guideRequest: true,
            guideCache: previous,
            receivedResponse: receivedResponse
        )
        defer { bytes.task.cancel() }
        let metadata = try XMLTVGuideCacheMetadata(response: response, previous: previous)
        if response.statusCode == 304 {
            if cachedGuide?.url == url { clearGuideCache() }
            try Task.checkCancellation()
            try storageLifecycle.checkAccess()
            guard !isClosed else { throw CancellationError() }
            return .notModified(metadata)
        }
        let progress = ServerLiveTVGuideProgress.report
        // URLSession may decode Content-Encoding before yielding bytes.
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let total = (encoding == nil || encoding == "identity") && response.expectedContentLength > 0
            ? Int(exactly: response.expectedContentLength) : nil
        progress?(.init(stage: .downloading, total: total))
        var lastProgress = ContinuousClock.now
        let limit = XMLTVResourceLimits.expandedBytes
        guard response.expectedContentLength <= limit else { throw LiveTVSourceImportError.guideTooLarge }
        let writer = try TemporaryMappedData.Writer(maximumBytes: limit)
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var received = 0
        var payloadLimit = limit
        defer {
            IPTVHTTP.performanceMetrics?.record(bytes: received)
            IPTVGuideDiagnostics.request?.consumed(received)
        }
        for try await byte in bytes {
            guard received < payloadLimit else { throw LiveTVSourceImportError.guideTooLarge }
            buffer.append(byte)
            received += 1
            if received == 2, buffer.starts(with: [0x1f, 0x8b]) {
                payloadLimit = XMLTVResourceLimits.compressedBytes
                guard response.expectedContentLength <= payloadLimit else {
                    throw LiveTVSourceImportError.guideTooLarge
                }
            }
            if buffer.count == 65_536 {
                try writer.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                if ContinuousClock.now - lastProgress >= .milliseconds(250) {
                    progress?(.init(stage: .downloading, completed: received, total: total))
                    lastProgress = .now
                }
            }
        }
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        try storageLifecycle.checkAccess()
        try writer.append(buffer)
        let data = try writer.finish()
        progress?(.init(stage: .downloading, completed: received, total: total))
        let duration = min(60, max(0, metadata.expiresAt.timeIntervalSinceNow))
        clearGuideCache()
        if retainsRawResponse, duration > 0, metadata.permitsPersistence {
            cachedGuide = (url, data, Date().addingTimeInterval(duration))
            let generation = guideCacheGeneration
            guideCacheExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) }
                catch is CancellationError { return }
                catch {
                    PlozzLog.networking.error("IPTV guide cache expiry wait failed")
                }
                await self?.expireGuideCache(generation: generation)
            }
        }
        try Task.checkCancellation()
        return .document(XMLTVDownloadedDocument(
            data: data, expiresAt: metadata.expiresAt,
            permitsPersistence: metadata.permitsPersistence, cacheMetadata: metadata
        ))
    }

    private func expireGuideCache(generation: UUID) {
        guard generation == guideCacheGeneration else { return }
        clearGuideCache()
    }

    private func clearGuideCache() {
        guideCacheExpiry?.cancel()
        guideCacheExpiry = nil
        guideCacheGeneration = UUID()
        cachedGuide = nil
    }

    func invalidateGuideCache() {
        clearGuideCache()
        guideRefreshes.removeAll()
        emptyGuideAnswers.removeAll()
        batchGuideUnavailable = false
        restoreGuideBackoffOnce()
        if let backoff = guideBackoff {
            guideBackoff = (.distantPast, backoff.failures, backoff.error)
            saveGuideBackoff(grantedDelay: Self.firstGuideBackoff)
        }
    }

    /// Native listings are allowed only when this account has no batch guide.
    func mayAskPerChannel() throws -> Bool {
        if batchGuideUnavailable { return true }
        return try xtreamGuideURL() == nil
    }

    func cancel() {
        isClosed = true
        refresh?.cancel()
        cancelRefreshAdmissions()
        clearGuideCache()
        guideRefreshes.removeAll()
        http.cancel()
    }

    /// Catalogue and guide transfers share one provider account. Keep a started
    /// transfer intact; admit queued catalogues before the next guide transfer.
    private func acquireRefreshWork(_ kind: RefreshWork) async throws -> UUID {
        try Task.checkCancellation()
        try storageLifecycle.checkAccess()
        guard !isClosed else { throw CancellationError() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeRefreshWork == nil {
                    activeRefreshWork = id
                    continuation.resume()
                } else {
                    refreshAdmissions.append(.init(id: id, kind: kind, continuation: continuation))
                    PlozzLog.networking.info("IPTV_REFRESH event=queued kind=\(kind.rawValue)")
                }
            }
        } onCancel: {
            Task { await self.cancelRefreshAdmission(id) }
        }
        do {
            try Task.checkCancellation()
            try storageLifecycle.checkAccess()
            guard !isClosed else { throw CancellationError() }
            return id
        } catch {
            releaseRefreshWork(id)
            throw error
        }
    }

    private func releaseRefreshWork(_ id: UUID) {
        precondition(activeRefreshWork == id)
        activeRefreshWork = nil
        guard !refreshAdmissions.isEmpty else { return }
        let index = refreshAdmissions.firstIndex { $0.kind == .catalog } ?? 0
        let next = refreshAdmissions.remove(at: index)
        activeRefreshWork = next.id
        next.continuation.resume()
    }

    private func cancelRefreshAdmission(_ id: UUID) {
        guard let index = refreshAdmissions.firstIndex(where: { $0.id == id }) else { return }
        refreshAdmissions.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelRefreshAdmissions() {
        let waiting = refreshAdmissions
        refreshAdmissions.removeAll()
        for entry in waiting { entry.continuation.resume(throwing: CancellationError()) }
    }

    private func store(_ record: IPTVRecord, overwrite: Bool = true, into table: IPTVCatalog.Table = .entries) throws {
        try catalog.insert(sanitizedArtwork(record), overwrite: overwrite, into: table)
    }

    private func sanitizedArtwork(_ record: IPTVRecord) -> IPTVRecord {
        guard record.item.posterURL != nil || record.item.seriesPosterURL != nil || record.item.backdropURL != nil else {
            return record
        }
        let secrets = artworkSecrets + IPTVRedirectPolicy.protectedValues(
            url: record.streamURL ?? credential.address, headers: record.headers
        )
        func publicURL(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            return secrets.contains(where: { text.contains($0) }) ? nil : url
        }
        var result = record
        result.item.posterURL = publicURL(result.item.posterURL)
        result.item.seriesPosterURL = publicURL(result.item.seriesPosterURL)
        result.item.backdropURL = publicURL(result.item.backdropURL)
        return result
    }

    private func baseURL() throws -> URL {
        var url = credential.address
        if url.pathExtension.lowercased() == "php" { url.deleteLastPathComponent() }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw IPTVError.invalidAddress }
        parts.query = nil
        parts.fragment = nil
        guard let clean = parts.url else { throw IPTVError.invalidAddress }
        return clean
    }

    private func endpoint(file: String = "player_api.php", action: String? = nil,
                          extra: [URLQueryItem] = []) throws -> URL {
        let url = try baseURL().appendingPathComponent(file)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw IPTVError.invalidAddress }
        parts.queryItems = [
            URLQueryItem(name: "username", value: credential.username),
            URLQueryItem(name: "password", value: credential.password)
        ] + (action.map { [URLQueryItem(name: "action", value: $0)] } ?? []) + extra
        // Xtream's PHP query decoder treats a literal plus as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = parts.url else { throw IPTVError.invalidAddress }
        return result
    }

    private func object(url: URL) async throws -> IPTVObject {
        var data = Data()
        try await read(url: url) { bytes in
            guard data.count + bytes.count <= 16 * 1_024 * 1_024 else { throw IPTVError.oversizedRecord }
            data.append(bytes)
        }
        IPTVGuideDiagnostics.request?.parsing()
        do { return try JSONDecoder().decode(IPTVObject.self, from: data) }
        catch { throw IPTVError.malformed }
    }

    private func read(url: URL, consume: (Data) throws -> Void) async throws {
        let (bytes, _) = try await http.bytes(url: url, headers: credential.headers(for: url))
        defer { bytes.task.cancel() }
        var chunk = Data()
        var consumedBytes = 0
        defer {
            IPTVHTTP.performanceMetrics?.record(bytes: consumedBytes + chunk.count)
            IPTVGuideDiagnostics.request?.consumed(consumedBytes + chunk.count)
        }
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65_536 {
                try Task.checkCancellation()
                try consume(chunk)
                consumedBytes += chunk.count
                chunk.removeAll(keepingCapacity: true)
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty { try consume(chunk) }
    }
}
