import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import os

actor IPTVClient: ApplicationStorageParticipant {
    private static let playlistCatalogScope = "playlist-v5"
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
                if needsGuideDiscovery || Date().timeIntervalSince(committedAt) >= 1_800, refresh == nil,
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
            HandoffDiagnostics.emit("IPTV catalogRefresh begin background=\(background)")
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

    func guideChannels() async throws -> [IPTVProvider.IPTVGuideChannel] {
        try await ensureCatalog("live")
        try catalog.execute("BEGIN")
        do {
            var result: [IPTVProvider.IPTVGuideChannel] = []
            while true {
                try Task.checkCancellation()
                let page = try catalog.records(where: "live = 1", values: [], start: result.count, limit: 1_000)
                guard result.count + page.count <= 100_000 else { throw LiveTVSourceImportError.guideTooLarge }
                result += page.map {
                    IPTVProvider.IPTVGuideChannel(
                        id: $0.item.id, name: $0.item.title, guideID: $0.guideID,
                        guideName: $0.guideName, country: $0.guideCountry
                    )
                }
                if page.count < 1_000 { break }
            }
            try catalog.execute("COMMIT")
            return result
        } catch {
            try catalog.execute("ROLLBACK")
            throw error
        }
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
        let supportsGuide = try credential.mode == .xtream || !credential.explicitGuideURLs.isEmpty
            || catalog.count(where: "kind = ?", values: [MediaItemKind.unknown.rawValue]) > 0
        return try ServerLiveTVCatalogSnapshot(channels: committedLiveChannels(), supportsGuide: supportsGuide)
    }

    private func committedLiveChannels() throws -> [ServerLiveTVChannel] {
        var result: [ServerLiveTVChannel] = []
        while true {
            try Task.checkCancellation()
            let page = try catalog.records(where: "live = 1", values: [], start: result.count, limit: 1_000)
            for record in page {
                result.append(ServerLiveTVChannel(
                    id: record.item.id, name: record.item.title,
                    number: record.channelNumber.map(String.init) ?? String(result.count + 1),
                    imageURL: record.item.posterURL, groups: record.item.tags
                ))
            }
            if page.count < 1_000 { return result }
            try Task.checkCancellation()
        }
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

    func guide(channelID: String, from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard credential.mode == .xtream else { return [] }
        let channel = try await record(channelID)
        guard let nativeID = channel.streamID else { throw AppError.notFound }
        let admission = try await acquireRefreshWork(.guide)
        defer { releaseRefreshWork(admission) }
        let data = try await object(url: endpoint(action: "get_simple_data_table", extra: [
            URLQueryItem(name: "stream_id", value: nativeID)
        ]))
        guard !isClosed else { throw CancellationError() }
        if data.object("user_info").integer("auth") == 0 || data.integer("auth") == 0 {
            throw IPTVError.authentication
        }
        guard case .array(let listings) = data["epg_listings"] else { throw IPTVError.malformed }
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
        try Task.checkCancellation()
        let refresh = currentGuideRefresh()
        if refresh?.missingURLs.contains(url) == true {
            IPTVGuideDiagnostics.request?.reuseGuideFailure()
            throw AppError.notFound
        }
        if let failure = refresh?.rejectedURLs[url] {
            IPTVGuideDiagnostics.request?.reuseGuideFailure()
            throw failure
        }
        do {
            var attempt = 0
            while true {
                let retryAfter = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
                do {
                    return try await downloadGuideData(from: url, retainsRawResponse: retainsRawResponse) { response in
                        let delay = HTTPDate.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                        retryAfter.withLock { $0 = delay }
                    }
                } catch {
                    try Task.checkCancellation()
                    guard let delay = Self.guideRetryDelay(
                        after: error, attempt: attempt, retryAfter: retryAfter.withLock({ $0 })
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
        from url: URL, retainsRawResponse: Bool,
        receivedResponse: @escaping @Sendable (HTTPURLResponse) -> Void
    ) async throws -> XMLTVDownloadedDocument {
        if retainsRawResponse, let cachedGuide, cachedGuide.url == url, cachedGuide.expires > Date() {
            IPTVGuideDiagnostics.request?.cacheHit(bytes: cachedGuide.data.count)
            return XMLTVDownloadedDocument(data: cachedGuide.data, expiresAt: cachedGuide.expires, permitsPersistence: true)
        }
        let admission = try await acquireRefreshWork(.guide)
        defer { releaseRefreshWork(admission) }
        // Another admitted reader may have populated the cache while this one waited.
        if retainsRawResponse, let cachedGuide, cachedGuide.url == url, cachedGuide.expires > Date() {
            IPTVGuideDiagnostics.request?.cacheHit(bytes: cachedGuide.data.count)
            return XMLTVDownloadedDocument(data: cachedGuide.data, expiresAt: cachedGuide.expires, permitsPersistence: true)
        }
        let (bytes, response) = try await http.bytes(
            url: url, headers: credential.guideHeaders(for: url), guideRequest: true,
            receivedResponse: receivedResponse
        )
        defer { bytes.task.cancel() }
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
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let maxAge = directives.first { $0.hasPrefix("max-age=") }
            .flatMap { Double($0.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        let duration = min(60, maxAge.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 60)
        clearGuideCache()
        if retainsRawResponse, duration > 0, !directives.contains("no-store"), !directives.contains("no-cache") {
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
        return XMLTVDownloadedDocument(
            data: data, expiresAt: Date().addingTimeInterval(directives.contains("no-cache") ? 0 : duration),
            permitsPersistence: !directives.contains("no-store")
        )
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
