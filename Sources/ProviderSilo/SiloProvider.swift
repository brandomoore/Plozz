import Foundation
import CoreModels
import CoreNetworking

public final class SiloProvider: MediaProvider, CapabilityReporting, MediaSortFieldProviding, Sendable {
    public let kind: ProviderKind = .silo
    public let session: UserSession
    public let accountID: String
    public let credentialRevision: CredentialRevision
    let client: SiloClient
    let playback: SiloPlaybackSessions
    let capabilitiesSnapshot: MediaCapabilities
    let artwork = SiloArtworkStore()

    public init(
        context: ProviderResolutionContext, credentials: any RotatingCredentialStoring,
        http: any HTTPClient = URLSessionHTTPClient(),
        capabilities: MediaCapabilities = .detected()
    ) throws {
        session = context.session
        accountID = context.accountID
        credentialRevision = context.credentialRevision
        client = try SiloClient(context: context, store: credentials, http: http)
        playback = SiloPlaybackSessions()
        capabilitiesSnapshot = capabilities
    }

    public var capabilities: ProviderCapability { [.video, .libraryCollections, .remoteSubtitles] }
    public var catalogIdentityRequiresEnrichment: Bool { true }

    public func libraries() async throws -> [MediaLibrary] {
        let response: SiloCollection<SiloLibrary> = try await client.request("/user/libraries")
        return response.items.compactMap {
            let kind: MediaItemKind
            switch $0.type.lowercased() {
            case "movie", "movies": kind = .movie
            case "series", "tv", "shows": kind = .series
            case "video", "videos": kind = .video
            default: return nil
            }
            return MediaLibrary(id: $0.id, title: $0.name, kind: kind,
                                imageURL: resourceURL($0.poster_url))
        }
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        guard page.startIndex >= 0, page.limit > 0 else { throw AppError.invalidResponse }
        return try await catalogPage(
            [URLQueryItem(name: "library_id", value: containerID),
             URLQueryItem(name: "type", value: kind.rawValue)],
            page: page, libraryID: containerID)
    }

    public func item(id: String) async throws -> MediaItem {
        if let collection = Self.collectionIdentity(id) {
            let page = try await collections(in: collection.libraryID, page: .init(limit: Int.max))
            guard let item = page.items.first(where: { $0.id == id }) else { throw AppError.notFound }
            return item
        }
        let dto: SiloItem = try await client.request("/catalog/items/\(try SiloAPI.pathComponent(id))")
        return map(dto)
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        if Self.collectionIdentity(itemID) != nil {
            var items: [MediaItem] = []
            while true {
                let page = try await collectionMembers(of: itemID, page: .init(startIndex: items.count, limit: 200))
                items += page.items
                if items.count >= page.totalCount { return items }
                guard !page.items.isEmpty else { throw AppError.invalidResponse }
            }
        }
        let parent = try await item(id: itemID)
        if parent.kind == .series {
            let page: SiloCollection<SiloItem> = try await client.request(
                "/catalog/series/\(try SiloAPI.pathComponent(itemID))/seasons")
            return page.items.map {
                var child = map($0, kind: .season)
                child.seriesID = itemID
                child.parentTitle = parent.title
                return child
            }
        }
        if parent.kind == .season {
            let page: SiloCollection<SiloItem> = try await client.request(
                "/catalog/items/\(try SiloAPI.pathComponent(itemID))/episodes")
            return page.items.map {
                var child = map($0, kind: .episode)
                child.seriesID = parent.seriesID
                child.seasonID = itemID
                child.parentTitle = parent.parentTitle
                return child
            }
        }
        throw AppError.notFound
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await latest(limit: limit, inLibraries: nil)
    }

    public func latest(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        let libraries = try await enabledLibraries(libraryIDs)
        var result: [(SiloItem, String)] = []
        for library in libraries {
            let items = try await catalogDTOs(
                [URLQueryItem(name: "library_id", value: library.id),
                 URLQueryItem(name: "type", value: library.kind.rawValue),
                 URLQueryItem(name: "sort", value: "-added_at")],
                limit: limit)
            result += items.map { ($0, library.id) }
        }
        result.sort { ($0.0.added_at ?? "") > ($1.0.added_at ?? "") }
        var seen = Set<String>()
        return result.filter { seen.insert($0.0.content_id).inserted }.prefix(limit).map { map($0.0, libraryID: $0.1) }
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await continueWatching(limit: limit, inLibraries: nil)
    }

    public func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        let scopes: [String?] = libraryIDs.map { $0.map(Optional.some) } ?? [nil]
        guard !scopes.isEmpty else { return [] }
        var result: [MediaItem] = []
        var seen = Set<String>()
        for scope in scopes {
            var cursor: String?
            var cursors = Set<String>()
            repeat {
                var query = [URLQueryItem(name: "status", value: "in_progress"),
                             URLQueryItem(name: "limit", value: "200")]
                if let scope { query.append(URLQueryItem(name: "library_id", value: scope)) }
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let page: SiloCollection<SiloProgressEntry> = try await client.request("/progress", query: query)
                for start in stride(from: 0, to: page.items.count, by: 4) {
                    let batch = Array(page.items[start..<min(start + 4, page.items.count)])
                    let items = try await withThrowingTaskGroup(of: MediaItem.self) { group in
                        for progress in batch {
                            group.addTask { [self] in
                                var item = try await item(id: progress.media_item_id)
                                item.resumePosition = progress.position_seconds
                                item.runtime = progress.duration_seconds > 0 ? progress.duration_seconds : item.runtime
                                item.lastPlayedAt = Self.date(progress.updated_at)
                                item.libraryID = scope
                                return item
                            }
                        }
                        var items: [MediaItem] = []
                        for try await item in group { items.append(item) }
                        return items
                    }
                    for item in items where seen.insert(item.id).inserted { result.append(item) }
                }
                cursor = try page.nextCursor()
                if let cursor, (page.items.isEmpty || !cursors.insert(cursor).inserted) { throw AppError.invalidResponse }
            } while cursor != nil && result.count < limit
        }
        let sections: SiloSections = try await client.request("/home/sections")
        for section in sections.sections where ["continue_watching", "next_up"].contains(section.section_type) {
            for dto in section.items where !seen.contains(dto.play_content_id ?? dto.content_id) {
                var candidate = map(dto)
                if let target = dto.play_content_id, target != dto.content_id { candidate = try await item(id: target) }
                if let libraryIDs {
                    var membership: String?
                    for libraryID in libraryIDs {
                        let matches = try await catalogItems([
                            URLQueryItem(name: "library_id", value: libraryID),
                            URLQueryItem(name: "q", value: candidate.title),
                            URLQueryItem(name: "type", value: candidate.kind.rawValue)
                        ], limit: Int.max, libraryID: libraryID)
                        if matches.contains(where: { $0.id == candidate.id }) { membership = libraryID; break }
                    }
                    guard let membership else { continue }
                    candidate.libraryID = membership
                }
                guard candidate.kind == .movie || candidate.kind == .episode else { continue }
                if seen.insert(candidate.id).inserted { result.append(candidate) }
            }
        }
        result.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        return Array(result.prefix(limit))
    }

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await search(query: query, limit: limit, excludingLibraries: [])
    }

    public func search(query: String, limit: Int, excludingLibraries disabled: [String]) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        var result: [MediaItem] = []
        var seen = Set<String>()
        for library in try await libraries() where !disabled.contains(library.id) {
            let matches = try await catalogItems(
                [URLQueryItem(name: "library_id", value: library.id),
                 URLQueryItem(name: "q", value: query)],
                limit: limit - result.count, libraryID: library.id)
            for item in matches where seen.insert(item.id).inserted { result.append(item) }
            if result.count >= limit { break }
        }
        return result
    }

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        artwork.url(itemID: itemID, kind: kind)
    }

    public func reauthenticatedImageURL(_ persistedURL: URL, maxWidth: Int?) -> URL? {
        artwork.refreshed(persistedURL)
    }

    public func ownsPersistedImageURL(_ persistedURL: URL) -> Bool {
        artwork.refreshed(persistedURL) != nil
    }

    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        kind == .collection ? [.name] : [.name, .dateAdded, .releaseDate, .communityRating, .runtime]
    }

    public func mediaSegments(for itemID: String) async throws -> [MediaSegment] {
        let dto: SiloItem = try await client.request("/catalog/items/\(try SiloAPI.pathComponent(itemID))")
        return [(MediaSegment.Kind.intro, dto.intro), (.credits, dto.credits),
                (.recap, dto.recap), (.preview, dto.preview)].compactMap { kind, marker in
            guard let marker, marker.start.isFinite, marker.end.isFinite,
                  marker.start >= 0, marker.end > marker.start else { return nil }
            return MediaSegment(id: "\(itemID):\(kind.rawValue)", kind: kind,
                                start: marker.start, end: marker.end)
        }
    }

    func enabledLibraries(_ ids: [String]?) async throws -> [MediaLibrary] {
        let available = try await libraries()
        guard let ids else { return available }
        return available.filter { ids.contains($0.id) }
    }

    func catalogPage(_ query: [URLQueryItem], page: PageRequest, libraryID: String?) async throws -> MediaPage {
        let field: String
        switch page.sort.field {
        case .name: field = "title"
        case .dateAdded: field = "added_at"
        case .releaseDate: field = "release_date"
        case .communityRating: field = "rating"
        case .runtime: field = "runtime"
        case .random: throw AppError.invalidResponse
        }
        let sort = (page.sort.direction == .descending ? "-" : "") + field
        let response: SiloCatalogPage = try await client.request("/catalog", query: query + [
            URLQueryItem(name: "seek", value: String(page.startIndex)),
            URLQueryItem(name: "limit", value: String(min(page.limit, 200))),
            URLQueryItem(name: "sort", value: sort)
        ])
        guard response.total >= 0 else { throw AppError.invalidResponse }
        return MediaPage(items: response.items.map { map($0, libraryID: libraryID) },
                         startIndex: page.startIndex, totalCount: response.total)
    }

    func catalogItems(_ query: [URLQueryItem], limit: Int, libraryID: String? = nil) async throws -> [MediaItem] {
        try await catalogDTOs(query, limit: limit).map { map($0, libraryID: libraryID) }
    }

    func catalogDTOs(_ query: [URLQueryItem], limit: Int) async throws -> [SiloItem] {
        guard limit > 0 else { return [] }
        var result: [SiloItem] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var parameters = query + [URLQueryItem(name: "limit", value: String(min(200, limit - result.count)))]
            if let cursor { parameters.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: SiloCatalogPage = try await client.request("/catalog", query: parameters)
            result += page.items
            guard page.page?.has_more == true, result.count < limit else { break }
            guard !page.items.isEmpty, let next = page.page?.next_cursor, !next.isEmpty,
                  seen.insert(next).inserted else { throw AppError.invalidResponse }
            cursor = next
        } while result.count < limit
        return Array(result.prefix(limit))
    }

    func resourceURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              let url = URL(string: value, relativeTo: session.server.baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func map(_ dto: SiloItem, kind: MediaItemKind? = nil, libraryID: String? = nil) -> MediaItem {
        artwork.record(resourceURL(dto.poster_url ?? dto.still_url), itemID: dto.content_id, kind: .primary)
        artwork.record(resourceURL(dto.backdrop_url), itemID: dto.content_id, kind: .backdrop)
        artwork.record(resourceURL(dto.logo_url), itemID: dto.content_id, kind: .logo)
        let versions = (dto.versions ?? []).enumerated().map { index, file in
            let info = metadata(file)
            return MediaVersion(id: file.file_id, fileName: file.file_name, edition: file.edition_raw,
                                width: info.video?.width, height: info.video?.height, bitrate: info.video?.bitrate,
                                sizeBytes: file.file_size, duration: file.duration, isDefault: index == 0,
                                videoCodec: file.codec_video, videoRange: info.video?.videoRangeType,
                                audioCodec: file.codec_audio, audioChannels: info.audio?.channels,
                                audioProfile: info.audio?.profile, container: file.container,
                                sourceMetadata: info)
        }
        var ids: [String: String] = [:]
        for (key, value) in [("Imdb", dto.imdb_id), ("Tmdb", dto.tmdb_id), ("Tvdb", dto.tvdb_id)] {
            if let value, !value.isEmpty { ids[key] = value }
        }
        let itemKind = kind ?? MediaItemKind(rawValue: dto.type ?? "") ?? .unknown
        let anchor = SiloCatalogIdentity.parse(dto.content_id, kind: itemKind)
        if let anchor, dto.series_id == nil || dto.series_id == anchor.seriesID {
            ids.merge(anchor.providerIDs) { declared, _ in declared }
        }
        return MediaItem(
            id: dto.content_id, title: dto.title, originalTitle: dto.original_title,
            kind: itemKind,
            overview: dto.overview, parentTitle: dto.series_title,
            seasonNumber: dto.season_number ?? anchor?.seasonNumber,
            episodeNumber: dto.episode_number ?? anchor?.episodeNumber,
            productionYear: dto.year, officialRating: dto.content_rating,
            genres: dto.genres ?? [], people: (dto.cast ?? []).map {
                MediaPerson(id: $0.person_id ?? $0.name, name: $0.name, role: $0.character,
                            imageURL: resourceURL($0.photo_url))
            }, studios: dto.studios ?? [], seriesID: dto.series_id ?? anchor?.seriesID,
            runtime: dto.duration_seconds ?? dto.user_data?.duration_seconds ?? dto.runtime.map { $0 * 60 },
            resumePosition: dto.position_seconds ?? dto.user_data?.position_seconds,
            isPlayed: dto.user_state?.played ?? dto.user_data?.played ?? false,
            posterURL: resourceURL(dto.poster_url ?? dto.still_url),
            backdropURL: resourceURL(dto.backdrop_url), logoURL: resourceURL(dto.logo_url),
            providerIDs: ids, mediaInfo: versions.first?.sourceMetadata, sourceAccountID: accountID,
            libraryID: libraryID, versions: versions,
            isFavorite: dto.user_state?.in_watchlist ?? false,
            lastPlayedAt: dto.progress_updated_at.flatMap(Self.date))
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func metadata(_ file: SiloFileVersion) -> MediaSourceMetadata {
        let video = file.video_tracks?.first
        let audio = file.audio_tracks?.first(where: { $0.default }) ?? file.audio_tracks?.first
        let range = (video?.dv_profile ?? 0) > 0 ? "DOVI"
            : video?.hdr10_plus == true ? "HDR10Plus" : video?.video_range_type
        let resolution = file.resolution.lowercased()
        let summaryHeight = (resolution.hasSuffix("p") || resolution.hasSuffix("i"))
            ? Int(resolution.dropLast()).flatMap { (100...16384).contains($0) ? $0 : nil } : nil
        let videoRange: String?
        if let detailedRange = video?.video_range {
            videoRange = detailedRange
        } else if let hdr = file.hdr {
            videoRange = hdr ? "HDR" : "SDR"
        } else {
            videoRange = nil
        }
        return MediaSourceMetadata(
            container: file.container, fileSizeBytes: file.file_size,
            video: .init(codec: video?.codec ?? file.codec_video, width: video?.width,
                         height: video?.height ?? summaryHeight,
                         bitrate: file.bitrate.multipliedReportingOverflow(by: 1000).overflow ? nil : file.bitrate * 1000,
                         videoRange: videoRange,
                         videoRangeType: range, dolbyVisionProfile: video?.dv_profile),
            audio: .init(codec: audio?.codec ?? file.codec_audio, profile: audio?.profile,
                         channels: audio?.channels, channelLayout: audio?.layout))
    }
}

extension SiloProvider: SeriesResumeProviding, SeriesIdentityProviding {
    public func resumeEpisode(inSeries seriesID: String) async throws -> MediaItem? {
        let dto: SiloItem = try await client.request("/catalog/items/\(try SiloAPI.pathComponent(seriesID))")
        guard let target = dto.play_content_id, target != seriesID else { return nil }
        let episode = try await item(id: target)
        guard episode.kind == .episode, episode.seriesID == seriesID else { throw AppError.invalidResponse }
        return episode
    }

    public func seriesProviderIDs(for seriesIDs: [String]) async throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for id in Set(seriesIDs) {
            let series = try await item(id: id)
            guard series.kind == .series else { throw AppError.invalidResponse }
            result[id] = series.providerIDs
        }
        return result
    }
}

extension SiloProvider: WatchStateProviding, ResumeStateWriting, WatchlistProviding {
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        try await client.send("/watched/\(try SiloAPI.pathComponent(itemID))", method: played ? .put : .delete)
    }

    public func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max / 1000) else { throw AppError.invalidResponse }
        struct Item: Encodable {
            let media_item_id: String
            let position_ms: Int64
            let duration_ms: Int64 = 0
            let updated_at: String
            let force_overwrite = true
        }
        struct Body: Encodable { let items: [Item] }
        let data = try JSONEncoder().encode(Body(items: [
            Item(media_item_id: itemID, position_ms: Int64(seconds * 1000),
                 updated_at: capturedAt.ISO8601Format(.init(includingFractionalSeconds: true)))
        ]))
        struct Receipt: Decodable, Sendable {
            struct Result: Decodable, Sendable { let media_item_id: String; let status: String; let index: Int }
            let items: [Result]
        }
        let receipt: Receipt = try await client.request("/sync/progress", method: .post, body: data)
        guard receipt.items.count == 1, receipt.items[0].media_item_id == itemID,
              receipt.items[0].index == 0, receipt.items[0].status == "success" else {
            throw AppError.invalidResponse
        }
    }

    public func setWatchlisted(_ on: Bool, item: MediaItem) async throws {
        try await client.send("/watchlist/\(try SiloAPI.pathComponent(item.id))", method: on ? .put : .delete)
    }

    public func watchlist() async throws -> [MediaItem] {
        try await catalogItems([URLQueryItem(name: "source", value: "watchlist")], limit: Int.max)
    }
}
