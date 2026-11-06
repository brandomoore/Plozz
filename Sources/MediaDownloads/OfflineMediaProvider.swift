import CoreModels
import Foundation

/// The ordinary browsing/playback contract backed exclusively by one profile's files.
public struct OfflineMediaProvider: MediaProvider, MediaSortFieldProviding {
    public let session: UserSession
    public var kind: ProviderKind { session.server.provider }
    public var connectionLocality: SourceLocality { .local }
    private let accountID: String
    private let sourceUserID: String?
    private let knownLibraries: [MediaLibrary]
    private let registry: DownloadedMediaRegistry
    private let storage: any DownloadStorageLocating
    private let resolver: RegistryOfflinePlaybackResolver
    private let authorize: @Sendable () async throws -> Void

    public init(
        account: Account, registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating, sourceUserID: String? = nil,
        libraries: [MediaLibrary] = [],
        authorize: @escaping @Sendable () async throws -> Void
    ) {
        session = account.session(token: "")
        accountID = account.id
        self.sourceUserID = sourceUserID
        self.knownLibraries = libraries
        self.registry = registry
        self.storage = storage
        self.resolver = RegistryOfflinePlaybackResolver(registry: registry, storage: storage)
        self.authorize = authorize
    }

    private struct Catalog {
        var records: [String: [DownloadedMediaRecord]] = [:]
        var items: [String: MediaItem] = [:]
        var children: [String: [String]] = [:]
        var roots: [String: [String]] = [:]
    }

    private func catalog() async throws -> Catalog {
        try await authorize()
        var catalog = Catalog()
        let records = await registry.all().sorted { $0.updatedAt > $1.updatedAt }
        for record in records {
            try Task.checkCancellation()
            let snapshot = record.snapshot
            if let sourceUserID, snapshot.sourceUserID != sourceUserID { continue }
            guard (snapshot.sourceAccountID ?? record.managedHTTPSource?.accountID
                    ?? record.directShareSource?.accountID) == accountID,
                  let id = snapshot.sourceItemID ?? record.managedHTTPSource?.itemID ?? legacyItemID(record),
                  record.status == .completed,
                  let file = resolver.localPlaybackURL(for: record), file.isFileURL,
                  snapshot.kind == .movie || snapshot.kind == .episode else { continue }
            let libraryID = snapshot.libraryID
                ?? (snapshot.kind == .movie ? "offline.movies" : "offline.series")
            var item = MediaItem(
                id: id, title: snapshot.title, kind: snapshot.kind,
                overview: snapshot.overview, parentTitle: snapshot.seriesTitle,
                seasonNumber: snapshot.seasonNumber, episodeNumber: snapshot.episodeNumber,
                productionYear: snapshot.year, officialRating: snapshot.officialRating,
                genres: snapshot.genres ?? [], seriesID: snapshot.seriesID,
                seasonID: snapshot.seasonID, runtime: snapshot.runtime,
                resumePosition: snapshot.resumePosition, isPlayed: snapshot.isPlayed ?? false,
                posterURL: artworkURL(for: record), providerIDs: snapshot.providerIDs,
                allowsTitleBasedMetadataMatching: false,
                sourceAccountID: accountID, libraryID: libraryID
            )
            if let versionID = record.versionID {
                item.versions = [MediaVersion(
                    id: versionID, name: record.versionLabel, sizeBytes: record.totalBytes,
                    duration: snapshot.runtime, sourceItemID: id, sourceAccountID: accountID,
                    providerMediaSourceID: versionID
                )]
            }
            catalog.records[id, default: []].append(record)
            if var existing = catalog.items[id] {
                existing.versions += item.versions
                catalog.items[id] = existing
                continue
            }
            if item.kind == .episode {
                let seriesID = snapshot.seriesID ?? "offline.series.\(record.groupID ?? id)"
                let seasonID = snapshot.seasonID ?? "\(seriesID).offline.season.\(snapshot.seasonNumber ?? 0)"
                item.seriesID = seriesID
                item.seasonID = seasonID
                if catalog.items[seriesID] == nil {
                    catalog.items[seriesID] = MediaItem(
                        id: seriesID, title: snapshot.seriesTitle ?? snapshot.title, kind: .series,
                        posterURL: artworkURL(for: record), allowsTitleBasedMetadataMatching: false,
                        sourceAccountID: accountID, libraryID: libraryID
                    )
                    catalog.roots[libraryID, default: []].append(seriesID)
                }
                if catalog.items[seasonID] == nil {
                    catalog.items[seasonID] = MediaItem(
                        id: seasonID, title: snapshot.seriesTitle ?? snapshot.title, kind: .season,
                        parentTitle: snapshot.seriesTitle, seasonNumber: snapshot.seasonNumber,
                        seriesID: seriesID, posterURL: artworkURL(for: record),
                        allowsTitleBasedMetadataMatching: false,
                        sourceAccountID: accountID, libraryID: libraryID
                    )
                    catalog.children[seriesID, default: []].append(seasonID)
                }
                catalog.children[seasonID, default: []].append(id)
            } else {
                catalog.roots[libraryID, default: []].append(id)
            }
            catalog.items[id] = item
        }
        try await authorize()
        return catalog
    }

    public func libraries() async throws -> [MediaLibrary] {
        let catalog = try await catalog()
        return catalog.roots.keys.sorted().map { id in
            if let library = knownLibraries.first(where: { $0.id == id }) { return library }
            let series = catalog.roots[id]?.first.flatMap { catalog.items[$0] }?.kind == .series
            return MediaLibrary(
                id: id, title: series ? "TV Shows" : "Movies", kind: series ? .series : .movie,
                synthesizedName: series ? .tvShows : .movies, sourceAccountID: accountID
            )
        }
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await latest(limit: limit, inLibraries: nil)
    }

    public func latest(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        let catalog = try await catalog()
        return catalog.records.keys.compactMap { catalog.items[$0] }
            .filter { item in libraryIDs.map { $0.contains(item.libraryID ?? "") } ?? true }
            .sorted {
                (catalog.records[$0.id]?.first?.updatedAt ?? .distantPast)
                    > (catalog.records[$1.id]?.first?.updatedAt ?? .distantPast)
            }.prefix(max(0, limit)).map { $0 }
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await continueWatching(limit: limit, inLibraries: nil)
    }

    public func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        try await latest(limit: .max, inLibraries: libraryIDs)
            .filter { !$0.isPlayed && ($0.resumePosition ?? 0) > 0 }
            .prefix(max(0, limit)).map { $0 }
    }

    public func item(id: String) async throws -> MediaItem {
        guard let item = try await catalog().items[id] else { throw AppError.notFound }
        return item
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        let catalog = try await catalog()
        return (catalog.children[itemID] ?? catalog.roots[itemID] ?? [])
            .compactMap { catalog.items[$0] }.sorted {
                if $0.seasonNumber != $1.seasonNumber { return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0) }
                if $0.episodeNumber != $1.episodeNumber { return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        guard page.startIndex >= 0, page.limit > 0 else { throw AppError.invalidResponse }
        let children: [MediaItem]
        if kind == .episode {
            let catalog = try await catalog()
            children = catalog.records.keys.compactMap { catalog.items[$0] }.filter {
                $0.libraryID == containerID || $0.seriesID == containerID || $0.seasonID == containerID
            }
        } else {
            children = try await self.children(of: containerID)
        }
        let items = children.filter {
            (kind == .unknown || $0.kind == kind) && LibraryQueryRecord($0).matches(page.filters)
        }.sorted {
            MediaItemSortOrder.isOrderedBefore($0, $1, sort: page.sort)
        }
        return MediaPage(
            items: Array(items.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: items.count
        )
    }

    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        [.name, .year, .runtime]
    }

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await search(query: query, limit: limit, excludingLibraries: [])
    }

    public func search(query: String, limit: Int, excludingLibraries disabledLibraryIDs: [String]) async throws -> [MediaItem] {
        try await catalog().items.values.filter {
            $0.kind != .season && !disabledLibraryIDs.contains($0.libraryID ?? "")
                && ($0.title.localizedStandardContains(query) || $0.parentTitle?.localizedStandardContains(query) == true)
        }.sorted { MediaItemSortOrder.isOrderedBefore($0, $1, sort: .default) }
            .prefix(max(0, limit)).map { $0 }
    }

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: false)
    }

    public func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool
    ) async throws -> PlaybackRequest {
        let catalog = try await catalog()
        guard !forceTranscode, var item = catalog.items[itemID],
              let record = catalog.records[itemID]?.first(where: {
                  mediaSourceID == nil || $0.versionID == mediaSourceID
              }), let url = resolver.localPlaybackURL(for: record) else { throw AppError.notFound }
        item.selectedVersionID = record.versionID
        try await authorize()
        return PlaybackRequest(
            item: item, streamURL: url, subtitleTracks: resolver.subtitleTracks(at: url),
            startPosition: item.resumePosition ?? 0, sourceMetadata: resolver.metadata(at: url),
            sourceProvider: kind, serverName: session.server.name
        )
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        try await authorize()
        try await registry.updatePlayback(
            accountID: accountID, itemID: progress.itemID,
            resumePosition: progress.positionSeconds, played: nil, clearResume: false, sourceUserID: sourceUserID
        )
    }

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    public func reauthenticatedImageURL(_ persistedURL: URL, maxWidth: Int?) -> URL? {
        persistedURL.isFileURL ? persistedURL : nil
    }

    private func artworkURL(for record: DownloadedMediaRecord) -> URL? {
        guard let name = record.snapshot.artworkFileName, !name.contains("/"), !name.contains("\\"),
              name != ".", name != "..",
              let folder = try? storage.pinnedFolderURL(forKey: record.identityKey) else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func legacyItemID(_ record: DownloadedMediaRecord) -> String? {
        guard case let .external(source, value) = record.identity,
              source.hasPrefix(DownloadMediaIdentity.accountSourcePrefix) else { return nil }
        return value
    }
}
