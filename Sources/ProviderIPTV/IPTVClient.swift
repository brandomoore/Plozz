import CoreModels
import CoreNetworking
import CryptoKit
import Foundation

actor IPTVClient {
    let credential: IPTVCredential
    private let http: IPTVHTTP
    private let artworkSecrets: [String]
    let catalog: IPTVCatalog
    private var refresh: Task<Void, Error>?
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var authenticatedAt: Date?
    private var liveExtension = "ts"
    private var cachedGuide: (url: URL, data: Data, expires: Date)?
    private let progress: @Sendable (IPTVImportProgress) -> Void
    var pendingCatalogRequestCount: Int { refreshWaiters.count }

    init(
        credential: IPTVCredential, directory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        progress: @escaping @Sendable (IPTVImportProgress) -> Void = { _ in }
    ) throws {
        self.credential = credential
        artworkSecrets = IPTVRedirectPolicy.protectedValues(url: credential.address, headers: credential.headers)
            + [credential.password].filter { !$0.isEmpty }
        self.progress = progress
        http = IPTVHTTP(configuration: configuration, sensitiveValues: [credential.password])
        let directory = directory ?? FileManager.default.urls(
            for: credential.mode == .file ? .applicationSupportDirectory : .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("IPTVCatalogs", isDirectory: true)
        catalog = try IPTVCatalog(
            url: directory.appendingPathComponent(credential.identity.uuidString + ".sqlite"),
            key: credential.catalogKey
        )
    }

    func authenticate() async throws {
        if credential.mode == .file {
            guard try catalog.state("playlist") != nil else { throw IPTVError.fileUnavailable }
            return
        }
        if credential.mode == .playlist {
            let (bytes, response) = try await http.bytes(url: credential.address, headers: credential.headers)
            defer { bytes.task.cancel() }
            var parser = M3UPlaylistParser(
                baseURL: response.url ?? credential.address, permitsAuthenticationHeaders: true
            ).makeCatalogStream()
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
            _ = try parser.finish()
            guard !parser.takeCatalogEntries().isEmpty else { throw IPTVError.empty }
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
        if credential.mode == .file {
            try await authenticate()
            return
        }
        while refresh != nil {
            try await waitForRefresh()
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let scope = credential.mode == .playlist ? "playlist" : library
        if !force, let raw = try catalog.state(scope),
           let time = TimeInterval(raw), Date().timeIntervalSince1970 - time < 1_800 { return }
        refresh = Task {
            let result: Result<Void, Error>
            do { try await self.importCatalog(library); result = .success(()) }
            catch { result = .failure(error) }
            self.refresh = nil
            let waiters = self.refreshWaiters.values
            self.refreshWaiters.removeAll()
            for waiter in waiters { waiter.resume(with: result) }
            try result.get()
        }
        try await waitForRefresh()
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
        if refreshWaiters.isEmpty { refresh?.cancel() }
    }

    private func importCatalog(_ library: String) async throws {
        if credential.mode == .xtream,
           authenticatedAt.map({ Date().timeIntervalSince($0) > 300 }) != false {
            try await authenticate()
        }
        try catalog.beginImport()
        defer { catalog.discardImport() }
        if credential.mode == .playlist {
            try await importPlaylist()
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
            var parser = IPTVJSONArrayStream()
            try await read(url: endpoint(action: action)) { data in
                try parser.append(data) { bytes in
                    let value = try JSONDecoder().decode(IPTVObject.self, from: bytes)
                    try store(IPTVMapping.listEntry(value, library: library, categories: categories), into: .incoming)
                    count += 1
                    if count.isMultiple(of: 1_000) { progress(IPTVImportProgress(stage: stage, entries: count)) }
                }
            }
            try parser.finish()
            progress(IPTVImportProgress(stage: stage, entries: count))
        }
        try Task.checkCancellation()
        try catalog.commitImport(
            library: credential.mode == .playlist ? nil : library,
            scope: credential.mode == .playlist ? "playlist" : library
        )
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
        try catalog.beginImport()
        defer { catalog.discardImport() }
        try await importPlaylist(fileURL: url)
        try Task.checkCancellation()
        try catalog.commitImport(library: nil, scope: "playlist")
    }

    private func importPlaylist(fileURL: URL? = nil) async throws {
        let origin: URL
        let bytes: URLSession.AsyncBytes?
        if fileURL != nil {
            origin = credential.address
            bytes = nil
        } else {
            let response = try await http.bytes(url: credential.address, headers: credential.headers)
            bytes = response.0
            origin = response.1.url ?? credential.address
        }
        defer { bytes?.task.cancel() }
        var parser = M3UPlaylistParser(
            baseURL: fileURL == nil ? origin : nil, permitsAuthenticationHeaders: true
        ).makeCatalogStream()
        var chunk = Data()
        var count = 0
        progress(IPTVImportProgress(stage: .playlist, entries: 0))
        func persist(_ entries: [M3UPlaylistParser.CatalogEntry]) throws {
            for entry in entries {
                for record in IPTVMapping.playlistEntry(entry) {
                    try store(record, overwrite: record.item.kind != .series && record.item.kind != .season, into: .incoming)
                }
                count += 1
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
                }
            }
        }
        try parser.append(chunk)
        do {
            let result = try parser.finish()
            try persist(parser.takeCatalogEntries())
            progress(IPTVImportProgress(stage: .playlist, entries: count))
            // Addresses are kept in a sealed catalogue record, never plaintext state.
            let guides = credential.explicitGuideURLs.isEmpty
                ? (credential.automaticallyDiscoversGuides ? result.declaredGuideURLs : []) : credential.explicitGuideURLs
            for (index, guide) in guides.prefix(32).enumerated() {
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: String(format: "guide:%02d", index), title: "", kind: .unknown),
                    streamURL: guide
                ), into: .incoming)
            }
            if guides.count > 32 { PlozzLog.networking.error("IPTV playlist declared more than 32 guides") }
            guard try catalog.count(where: "kind != ?", values: [MediaItemKind.unknown.rawValue], in: .incoming) > 0 else {
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
        var result: [ServerLiveTVChannel] = []
        while true {
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

    func delivery(_ id: String) async throws -> (URL, [String: String]) {
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
            components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 }
                + "/" + encoded.joined(separator: "/")
            guard let result = components.url else { throw IPTVError.malformed }
            url = result
        } else { throw AppError.notFound }
        var headers = credential.headers(for: url)
        for (key, value) in record.headers {
            headers = headers.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
            headers[key] = value
        }
        try IPTVCredential.validate(headers: headers)
        return (url, headers)
    }

    func guideURLs() async throws -> [URL] {
        if !credential.explicitGuideURLs.isEmpty { return credential.explicitGuideURLs }
        if credential.mode == .xtream { return [try endpoint(file: "xmltv.php")] }
        try await ensureCatalog("live")
        let guides = try catalog.records(where: "kind = ?", values: [MediaItemKind.unknown.rawValue], order: "id", limit: 32)
            .compactMap(\.streamURL)
        guard credential.mode == .file || guides.allSatisfy({ IPTVCredential.sameOrigin(credential.address, $0) }) else {
            throw LiveTVSourceImportError.unsafeGuideOrigin
        }
        return guides
    }

    func guide(channelID: String, from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard credential.mode == .xtream else { return [] }
        let channel = try await record(channelID)
        guard let nativeID = channel.streamID else { throw AppError.notFound }
        let data = try await object(url: endpoint(action: "get_simple_data_table", extra: [
            URLQueryItem(name: "stream_id", value: nativeID)
        ]))
        guard data["epg_listings"] != nil else { throw IPTVError.malformed }
        return data.array("epg_listings").compactMap {
            IPTVMapping.programme($0.object, channelID: channelID, from: from, to: to)
        }
    }

    func guideData(from url: URL) async throws -> Data {
        if let cachedGuide, cachedGuide.url == url, cachedGuide.expires > Date() { return cachedGuide.data }
        let (bytes, response) = try await http.bytes(url: url, headers: credential.guideHeaders(for: url))
        defer { bytes.task.cancel() }
        let limit = 256 * 1_024 * 1_024
        guard response.expectedContentLength <= limit else { throw LiveTVSourceImportError.guideTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw LiveTVSourceImportError.guideTooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 65_536) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let maxAge = directives.first { $0.hasPrefix("max-age=") }
            .flatMap { Double($0.dropFirst(8).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        let duration = min(60, maxAge.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 60)
        if data.count <= 16 * 1_024 * 1_024, !directives.contains("no-store"), !directives.contains("no-cache") {
            cachedGuide = (url, data, Date().addingTimeInterval(duration))
        } else { cachedGuide = nil }
        return data
    }

    func cancel() {
        refresh?.cancel()
        cachedGuide = nil
        http.cancel()
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
        guard let result = parts.url else { throw IPTVError.invalidAddress }
        return result
    }

    private func object(url: URL) async throws -> IPTVObject {
        var data = Data()
        try await read(url: url) { bytes in
            guard data.count + bytes.count <= 16 * 1_024 * 1_024 else { throw IPTVError.oversizedRecord }
            data.append(bytes)
        }
        do { return try JSONDecoder().decode(IPTVObject.self, from: data) }
        catch { throw IPTVError.malformed }
    }

    private func read(url: URL, consume: (Data) throws -> Void) async throws {
        let (bytes, _) = try await http.bytes(url: url, headers: credential.headers(for: url))
        defer { bytes.task.cancel() }
        var chunk = Data()
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65_536 {
                try Task.checkCancellation()
                try consume(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty { try consume(chunk) }
    }
}
