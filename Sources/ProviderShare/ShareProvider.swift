import Foundation
import CoreModels
import CoreNetworking
import MediaTransportCore
import os

/// Transport-neutral local media-share provider. Conforms to `MediaProvider`
/// so Home / browse / search / playback treat a share like any other backend —
/// but everything a real server would compute (libraries, detail, search) is
/// synthesised from a local scan (`ShareLibraryStore`) instead of network calls.
///
/// Connection metadata remains in the ordinary `UserSession`; credentials are
/// resolved only by the transport adapter. Playback returns a credential-free
/// `NetworkFileLocator` that EnginePlozzigen opens through the shared resolver.
///
/// This type is a thin facade: catalog reads go through the injected
/// `any ShareCatalogReading` capability (never the concrete `ShareCatalogStore`),
/// watch-state stamping/writes through `ShareWatchStateService`, and playback
/// file access (locator, sidecar subtitles, stream probe) through
/// `SharePlaybackSourceService`. It keeps only browse/playback orchestration.
public struct ShareProvider: MediaProvider, MediaFileBrowsing, MediaSortFieldProviding {
    public let kind: ProviderKind = .mediaShare
    public let session: UserSession
    public let localMediaContext: LocalMediaContext

    private let store: ShareLibraryStore
    private let catalogCoordinator: any ShareCatalogCoordinating
    /// Resolves the read-only catalog capability for this share on demand (the
    /// injected coordinator outlives transient provider values). A test override
    /// short-circuits to a supplied reader.
    private let catalogAccessor: @Sendable () async -> any ShareCatalogReading
    private let watchState: ShareWatchStateService
    private let playbackSource: SharePlaybackSourceService
    /// Injected engine-side network-file header prober. It uses the same typed
    /// locator and transport resolver as playback.
    private let streamProber: NetworkFileStreamProbing?
    private let streamProbeCache = ShareStreamProbeCache()

    private var libraryConfiguration: MediaShareLibraryConfiguration? {
        session.server.mediaShareLibraryConfiguration
    }

    /// The main share browser stays media-aware. Only title-scoped file-browser
    /// routes bypass catalog projection.
    public var fileBrowserLibrary: MediaLibrary {
        ShareLibraryStore.rootLibrary(
            serverName: session.server.name,
            configuration: libraryConfiguration
        )
    }

    public func supportedSortFields(
        in containerID: String,
        kind: MediaItemKind
    ) -> [SortField] {
        if ShareCatalogID.catalogLibrary(forID: containerID) != nil {
            return SortField.allCases
        }
        if ShareCatalogID.isSeries(containerID) || ShareCatalogID.isSeason(containerID) {
            return [.name, .releaseDate, .communityRating, .runtime, .random]
        }
        if libraryConfiguration?.contentType == .personalVideos
            || ShareCatalogID.containerID(forFileBrowserID: containerID) != nil {
            // Raw personal files have filesystem dates, but intentionally carry
            // no fabricated runtime, release, or ratings metadata.
            return [.name, .dateAdded, .random]
        }
        return SortField.allCases
    }

    public init(
        session: UserSession,
        localMediaContext: LocalMediaContext,
        credentialRevision: CredentialRevision,
        sessionFactory: @escaping ShareTransportSessionFactory,
        catalogCoordinator: any ShareCatalogCoordinating,
        durableLocalStateStore: DurableLocalStateStore? = nil,
        streamProber: NetworkFileStreamProbing? = nil
    ) {
        self.init(
            session: session,
            localMediaContext: localMediaContext,
            durableLocalStateStore: durableLocalStateStore,
            credentialRevision: credentialRevision,
            sessionFactory: sessionFactory,
            catalogCoordinator: catalogCoordinator,
            streamProber: streamProber
        )
    }

    /// Test seam with an injectable durable store and catalog reader.
    init(
        session: UserSession,
        localMediaContext: LocalMediaContext? = nil,
        durableLocalStateStore: DurableLocalStateStore? = nil,
        credentialRevision: CredentialRevision = CredentialRevision(
            rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        ),
        sessionFactory: @escaping ShareTransportSessionFactory = { _ in
            throw MediaTransportError.unsupportedCapability("test transport")
        },
        catalogCoordinator: any ShareCatalogCoordinating = ShareCatalogCoordinator(),
        streamProber: NetworkFileStreamProbing? = nil,
        catalogStore: (any ShareCatalogReading)? = nil
    ) {
        self.session = session
        let resolvedContext = localMediaContext ?? LocalMediaContext(
            accountID: session.server.id,
            profileID: ProfileStore.defaultProfileID,
            profileNamespace: nil
        )
        self.localMediaContext = resolvedContext
        self.catalogCoordinator = catalogCoordinator
        let browser = ShareTransportBrowser(
            role: .metadata,
            sessionFactory: sessionFactory
        )
        let configuration = session.server.mediaShareLibraryConfiguration
        let libraryStore = ShareLibraryStore(
            browser: browser,
            serverName: session.server.name,
            configuration: configuration
        )
        self.store = libraryStore
        // Watch state is device-local (a file share has no server), scoped by the
        // share's stable account id so two shares keep separate progress.
        let watchStore = ShareWatchStore(
            localMediaContext: resolvedContext,
            durableStore: durableLocalStateStore
        )
        let accountID = resolvedContext.accountID
        let displayName = session.server.name
        // Capture the coordinator + fixed context (not `self`, which is still being
        // initialised) so the accessor can resolve the read capability lazily.
        let accessor: @Sendable () async -> any ShareCatalogReading = {
            if let catalogStore { return catalogStore }
            return await catalogCoordinator.catalogReader(
                accountKey: accountID,
                displayName: displayName,
                credentialRevision: credentialRevision,
                libraryConfiguration: configuration,
                sessionFactory: sessionFactory
            )
        }
        self.catalogAccessor = accessor
        self.watchState = ShareWatchStateService(
            watchStore: watchStore,
            accountID: accountID,
            usesCatalogClassification: configuration?.contentType != .personalVideos,
            catalog: accessor
        )
        self.playbackSource = SharePlaybackSourceService(
            store: libraryStore,
            streamProber: streamProber,
            accountID: accountID,
            credentialRevision: credentialRevision
        )
        self.streamProber = streamProber
    }

    // MARK: Library browsing

    /// App-owned catalog for this share (SQLite index built by a background
    /// `ShareScanner`), resolved through the injected read capability so the
    /// concrete store never leaks into the facade.
    private var catalog: any ShareCatalogReading {
        get async { await catalogAccessor() }
    }

    /// Force a fresh scan + enrichment of this share now (Settings "Scan now").
    /// Touches `catalog` first so the store/scanner/enricher are registered even if
    /// Home never queried this share yet, then forces a scan bypassing the throttle.
    public func rescan() async {
        _ = await catalog
        await catalogCoordinator.rescan(accountKey: localMediaContext.accountID)
    }

    public func libraries() async throws -> [MediaLibrary] {
        // Home aggregation calls this at launch, so it must be instant — SQLite
        // reads only (no network) plus a fire-and-forget scan kick. Indexed
        // Legacy automatic categories appear once scanning finds content. An
        // explicitly configured movie/TV root appears immediately under its
        // stable synthetic id, while the distinct raw file-tree entry is always
        // available for unmatched content and live navigation.
        let catalog = await self.catalog
        let counts = await catalog.libraryCounts()
        var result: [MediaLibrary] = []
        switch libraryConfiguration?.contentType {
        case .movies:
            result.append(MediaLibrary(
                id: ShareCatalogID.moviesLibrary,
                title: libraryConfiguration?.name ?? session.server.name,
                kind: .movie
            ))
        case .tvShows:
            result.append(MediaLibrary(
                id: libraryConfiguration?.isAnime == true
                    ? ShareCatalogID.animeLibrary
                    : ShareCatalogID.tvLibrary,
                title: libraryConfiguration?.name ?? session.server.name,
                kind: .series
            ))
        case .automatic, nil:
            if counts.movies > 0 {
                result.append(MediaLibrary(id: ShareCatalogID.moviesLibrary, title: "Movies", kind: .movie,
                                           synthesizedName: .movies))
            }
            if counts.tvSeries > 0 {
                result.append(MediaLibrary(id: ShareCatalogID.tvLibrary, title: "TV Shows", kind: .series,
                                           synthesizedName: .tvShows))
            }
            if counts.animeSeries > 0 {
                result.append(MediaLibrary(id: ShareCatalogID.animeLibrary, title: "Anime", kind: .series,
                                           synthesizedName: .anime))
            }
            // Legacy/automatic shares historically exposed this stable root as a
            // library. Keep it in the inventory so saved visibility remains valid.
            result.append(contentsOf: await store.libraries())
        case .personalVideos:
            result.append(contentsOf: await store.libraries())
        }
        // Explicit movie/TV roots expose raw navigation through
        // `MediaFileBrowsing`, not as a second library tile.
        return result
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        // Canonicalize ALL stored state before filtering/limiting so several legacy
        // file-version records collapse to one movie without pushing distinct
        // titles off the row.
        let isPersonalVideos = libraryConfiguration?.contentType == .personalVideos
        let byCanonical = await watchState.allCanonicalRecords()
        let resumable = byCanonical.filter {
            !$0.value.played
                && $0.value.position > 1
                && (isPersonalVideos
                    || !ShareExtraDiscoveryPolicy.isRecognizedExtraItemID($0.key))
                // Taken off the row deliberately. The position is deliberately still
                // here, so playing it again resumes rather than restarts.
                && !$0.value.isDismissedFromContinueWatching
        }
        let ranked = resumable
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(limit)

        var items: [MediaItem] = []
        for (itemID, record) in ranked {
            // Resolve through the CATALOG first (indexed → carries series/season
            // linkage, including the `seasonID` the player's neighbour resolver
            // needs to offer Up Next / auto-advance), falling back to the raw
            // file-tree build only for un-indexed items. Personal Videos never
            // consult stale catalog rows from an earlier library classification.
            let base: MediaItem
            if isPersonalVideos,
               let rawItem = await store.item(id: itemID) {
                base = rawItem
            } else if isPersonalVideos {
                continue
            } else if let indexed = await catalog.item(id: itemID) {
                base = indexed
            } else if let rawItem = await store.item(id: itemID) {
                base = rawItem
            } else {
                continue
            }
            items.append(ShareWatchStateService.stamped(base, with: record))
        }
        // Device-observable (in-app log ring) so a missing Continue Watching row
        // can be traced to "no resumable state on disk" vs "rebuild dropped it".
        PlozzLog.playback.info("share.continueWatching account=\(localMediaContext.accountID) resumable=\(resumable.count) folded=\(byCanonical.count) rebuilt=\(items.count)")
        return items
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        // Recently Added, served from the catalog by first-discovery date — no
        // network, safe on the Home hot path. Empty until the first scan populates.
        let items = await catalog.latest(limit: limit)
        return await watchState.stamp(items)
    }

    /// Titles on this share featuring a person, answered entirely from the local
    /// catalog.
    ///
    /// A share has no person records of its own — its cast is resolved at scan
    /// time and persisted with the item — so both lookups run against that stored
    /// cast. The id path serves a person opened from this share (whose id is a
    /// TMDb one); the name path serves a person opened from a Jellyfin or Plex
    /// item, whose id means nothing here.
    /// Like `PlexProvider`, this deliberately implements only the two credit
    /// lookups and not `person(id:)`/`person(named:)`, taking the protocol
    /// defaults that answer `nil` without any work.
    ///
    /// A share is a filesystem: the catalog knows which people appear in which
    /// title (from the `<actor>` elements in an NFO), but an NFO's actor block
    /// carries only name, role, order and thumb — no biography. Kodi and
    /// Jellyfin both define standalone `person` NFO files that DO carry an
    /// `<Overview>`, so this could one day answer; nothing writes them here yet.
    public func items(withPerson personID: String, limit: Int) async throws -> [MediaItem] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        return await catalog.itemsWithPerson(id: personID, name: "", limit: limit)
    }

    public func items(withPersonNamed name: String, limit: Int) async throws -> [MediaItem] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        return await catalog.itemsWithPerson(id: nil, name: name, limit: limit)
    }

    public func item(id: String) async throws -> MediaItem {
        if let containerID = ShareCatalogID.containerID(forFileBrowserID: id) {
            guard let folder = await store.item(id: containerID) else {
                throw AppError.unknown("Folder not found on share: \(containerID)")
            }
            return ShareCatalogID.fileBrowserEntry(folder)
        }
        if libraryConfiguration?.contentType == .personalVideos {
            guard let item = await store.item(id: id) else {
                throw AppError.unknown("Item not found on share: \(id)")
            }
            return await watchState.stamp(item)
        }
        // Indexed items (movies/series/seasons/episodes) resolve from the catalog;
        // raw file-tree ids (`share:root`, `d:`) fall back to the live browser.
        if let extra = await catalog.extra(fileID: id) {
            var stamped = extra
            stamped.item = extra.supportsResume
                ? await watchState.stamp(extra.item)
                : extra.playbackItem
            return stamped.item
        }
        if let indexed = await catalog.item(id: id) {
            // A user just opened this — fast-track its enrichment ahead of the
            // background backlog so its hero/poster/overview persist promptly. Fire-
            // and-forget (no added latency); a no-op once the item is enriched.
            await catalogCoordinator.enrichItem(
                accountKey: localMediaContext.accountID,
                itemID: id
            )
            playbackSource.measureStreamProbeIfEnabled(itemID: id)
            return await watchState.stamp(indexed)
        }
        guard let item = await store.item(id: id) else {
            throw AppError.unknown("Item not found on share: \(id)")
        }
        return await watchState.stamp(item)
    }

    public func trailers(for itemID: String) async throws -> [MediaItem] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        return try await extras(for: itemID)
            .filter { $0.kind == .trailer }
            .map(\.playbackItem)
    }

    public func extras(for itemID: String) async throws -> [MediaExtra] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        let catalog = await self.catalog
        let ownerID = await catalog.canonicalItemID(itemID)
        let stored = await catalog.extras(ownerID: ownerID)
        var result: [MediaExtra] = []
        result.reserveCapacity(stored.count)
        for extra in stored {
            var copy = extra
            copy.item = extra.supportsResume
                ? await watchState.stamp(extra.item)
                : extra.playbackItem
            result.append(copy)
        }
        return MediaExtra.ordered(result)
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        if libraryConfiguration?.contentType == .personalVideos,
           ShareCatalogID.isSeries(itemID) || ShareCatalogID.isSeason(itemID) {
            return []
        }
        // Series → seasons, season → episodes (from the catalog); a raw folder's
        // children are that directory's live listing.
        if ShareCatalogID.isSeries(itemID), let key = ShareCatalogID.seriesKey(forSeriesID: itemID) {
            // Seasons need the rollup, not `stamp` — they are synthetic containers
            // with no record of their own, so `stamp` deliberately skips them.
            return await watchState.stampSeasons(
                await catalog.seasons(seriesKey: key),
                seriesKey: key
            )
        }
        if let (key, season) = ShareCatalogID.seasonComponents(forSeasonID: itemID) {
            return await watchState.stamp(await catalog.episodes(seriesKey: key, season: season))
        }
        let rawContainerID = ShareCatalogID.containerID(forFileBrowserID: itemID)
        let entries = try await store.entries(forContainerID: rawContainerID ?? itemID)
        if rawContainerID != nil {
            return await watchState.stamp(entries.map(ShareCatalogID.fileBrowserEntry))
        }
        let projected = libraryConfiguration?.contentType == .personalVideos
            ? entries
            : await catalog.browseItems(entries)
        return await watchState.stamp(projected)
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if libraryConfiguration?.contentType == .personalVideos,
           ShareCatalogID.catalogLibrary(forID: containerID) != nil
               || ShareCatalogID.isSeries(containerID)
               || ShareCatalogID.isSeason(containerID) {
            // An already-open route can outlive a library configuration change.
            // Retained catalog rows exist only to recover file watch aliases.
            return MediaPage(items: [], startIndex: 0, totalCount: 0)
        }
        // Indexed library grids page from the catalog; series/season containers are
        // small (delegate to `children`); the raw file tree lists the directory.
        if let library = ShareCatalogID.catalogLibrary(forID: containerID) {
            let t0 = Date()
            let catalog = await self.catalog
            let items: [MediaItem]
            let total: Int
            switch library {
            case .movies:
                items = await catalog.movies(
                    offset: page.startIndex,
                    limit: page.limit,
                    sort: page.sort
                )
                total = await catalog.movieCount()
            case .tv, .anime:
                items = await catalog.series(
                    in: library,
                    offset: page.startIndex,
                    limit: page.limit,
                    sort: page.sort
                )
                total = await catalog.seriesCount(in: library)
            }
            let stamped = await watchState.stamp(items)
            if ProcessInfo.processInfo.environment["PLZXPAGE"] == "1" {
                HandoffDiagnostics.emit("SMBPAGE lib=\(library.rawValue) start=\(page.startIndex) limit=\(page.limit) count=\(stamped.count) total=\(total) took=\(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            // Report the EXACT catalog count (not an open-ended estimate) so the grid
            // sizes its sparse store once and can jump/random-access any page — the
            // same experience as Plex (totalSize) / Jellyfin (TotalRecordCount).
            // Guard against a page landing beyond a stale/mid-scan count so the grid
            // still sees at least what we returned.
            let reportedTotal = max(total, page.startIndex + stamped.count)
            return MediaPage(items: stamped, startIndex: page.startIndex, totalCount: reportedTotal)
        }
        if ShareCatalogID.isSeries(containerID) || ShareCatalogID.isSeason(containerID) {
            let all = try await children(of: containerID)
            let ordered = Self.sortedBrowseItems(all, by: page.sort)
            let start = min(page.startIndex, ordered.count)
            let end = min(start + page.limit, ordered.count)
            return MediaPage(
                items: Array(ordered[start..<end]),
                startIndex: start,
                totalCount: ordered.count
            )
        }
        // Browsing the raw file tree lists exactly that directory.
        let rawContainerID = ShareCatalogID.containerID(forFileBrowserID: containerID)
        let entries = try await store.entries(
            forContainerID: rawContainerID ?? containerID,
            sort: page.sort,
            foldersFirst: rawContainerID != nil || libraryConfiguration?.contentType == .personalVideos
        )
        let all = rawContainerID != nil
            ? entries.map(ShareCatalogID.fileBrowserEntry)
            : libraryConfiguration?.contentType == .personalVideos
            ? entries
            : await catalog.browseItems(entries)
        // Filesystem creation/modified time is available only while the store maps
        // RemoteFileEntry values, so it has already ordered Date Added above.
        // Every other field is applied after catalog projection so promoted
        // movie/series entries can contribute runtime, year, and ratings.
        let containsCatalogTitles = all.contains {
            ShareCatalogID.isMovie($0.id)
                || ShareCatalogID.isSeries($0.id)
                || ShareCatalogID.isSeason($0.id)
        }
        let ordered = page.sort.field == .dateAdded
            ? all
            : Self.sortedBrowseItems(all, by: page.sort, foldersFirst: !containsCatalogTitles)
        let start = min(page.startIndex, ordered.count)
        let end = min(start + page.limit, ordered.count)
        let slice = await watchState.stamp(Array(ordered[start..<end]))
        return MediaPage(items: slice, startIndex: start, totalCount: ordered.count)
    }

    private static func sortedBrowseItems(
        _ items: [MediaItem],
        by sort: CoreModels.SortDescriptor,
        foldersFirst: Bool = true
    ) -> [MediaItem] {
        items.sorted { lhs, rhs in
            // Pure file browsing keeps folders first. A media-aware library grid
            // must not bury recognized titles behind all the unresolved folders.
            if foldersFirst, (lhs.kind == .folder) != (rhs.kind == .folder) {
                return lhs.kind == .folder
            }

            let ordered: Bool?
            switch sort.field {
            case .name:
                let lhsBefore = MediaItemSortOrder.isOrderedBefore(lhs, rhs, sort: sort)
                let rhsBefore = MediaItemSortOrder.isOrderedBefore(rhs, lhs, sort: sort)
                ordered = lhsBefore == rhsBefore ? nil : lhsBefore
            case .releaseDate:
                ordered = compare(
                    releaseSortDate(lhs),
                    releaseSortDate(rhs),
                    direction: sort.direction
                )
            case .communityRating:
                ordered = compare(
                    communityScore(lhs),
                    communityScore(rhs),
                    direction: sort.direction
                )
            case .runtime:
                ordered = compare(lhs.runtime, rhs.runtime, direction: sort.direction)
            case .random:
                ordered = compare(
                    randomRank(lhs.id),
                    randomRank(rhs.id),
                    direction: sort.direction
                )
            case .dateAdded:
                // The store applies filesystem timestamps before projection.
                ordered = nil
            }
            if let ordered { return ordered }

            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    private static func communityScore(_ item: MediaItem) -> Double? {
        item.ratings.first {
            $0.cohort == .community || $0.cohort == .audience
        }?.normalized
    }

    private static func releaseSortDate(_ item: MediaItem) -> Date? {
        if let date = item.releaseDate { return date }
        guard let year = item.productionYear else { return nil }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: 1,
            day: 1
        ).date
    }

    private static func compare<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        direction: SortDirection
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return direction == .ascending ? left < right : left > right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            return nil
        }
    }

    /// Stable pseudo-random ordering keeps independently fetched pages coherent.
    /// Swift's process-randomized `hashValue` cannot be persisted across reloads,
    /// so use a small deterministic FNV-1a rank over the unchanged provider id.
    private static func randomRank(_ id: String) -> UInt64 {
        id.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        guard libraryConfiguration?.contentType != .personalVideos else { return [] }
        // Indexed search over the catalog; empty until the first scan populates.
        return await watchState.stamp(await catalog.search(query: query, limit: limit))
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: false)
    }

    public func playbackInfo(for itemID: String, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID, mediaSourceID: nil, forceTranscode: forceTranscode)
    }

    /// Resolve the file to stream. The version picker threads the chosen version's
    /// id (which, for a share, IS the file's rel-path) as `mediaSourceID`; a logical
    /// `movie:<key>` with no chosen version plays its best default file; a bare
    /// `f:<rel>` (raw browser / episode) plays directly.
    public func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        let isPersonalVideos = libraryConfiguration?.contentType == .personalVideos
        let catalog: (any ShareCatalogReading)?
        if isPersonalVideos {
            catalog = nil
        } else {
            catalog = await self.catalog
        }
        let storedExtra = await catalog?.extra(fileID: itemID)
        let isExtra = !isPersonalVideos && (
            storedExtra != nil || ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(itemID)
        )
        let canonicalItemID: String
        if isExtra {
            canonicalItemID = itemID
        } else {
            canonicalItemID = await catalog?.canonicalItemID(itemID) ?? itemID
        }
        let isLiveRawFile: Bool
        if isPersonalVideos {
            isLiveRawFile = true
        } else {
            isLiveRawFile = await catalog?.containsFileAsset(id: itemID) == true
        }
        let relPath: String
        if let ms = mediaSourceID, !ms.isEmpty {
            relPath = ms
        } else if isExtra, let path = await store.path(forItemID: itemID) {
            // Extras deliberately retain their ordinary `f:` address even if an old
            // pre-migration movie alias exists for that path.
            relPath = path
        } else if ShareCatalogID.relPath(forFileID: itemID) != nil,
                  isLiveRawFile,
                  let path = await store.path(forItemID: itemID) {
            // A live raw-file id means the user selected that exact file in Files.
            relPath = path
        } else if let key = ShareCatalogID.movieKey(forMovieID: canonicalItemID),
                  let catalog {
            guard let def = await catalog.defaultMovieRelPath(forKey: key) else {
                throw AppError.unknown("No playable version for \(canonicalItemID)")
            }
            relPath = def
        } else if let p = await store.path(forItemID: itemID) {
            relPath = p
        } else {
            throw AppError.unknown("Item is not directly playable: \(itemID)")
        }
        let locator = try await playbackSource.networkFileLocator(for: relPath)
        let item = try await item(id: canonicalItemID)
        // Resume from the newest canonical/legacy member-file state so a movie
        // watched before version grouping still resumes after the upgrade.
        let records = await watchState.records(for: [canonicalItemID])
        let record = records[canonicalItemID]
        let storedExtraResume = await catalog?.extraResumeBehavior(fileID: canonicalItemID)
        let extraResume = isPersonalVideos
            ? nil
            : storedExtraResume
                ?? ShareExtraDiscoveryPolicy.resumeBehavior(forItemID: canonicalItemID)
        let startPosition = extraResume == false || record?.played == true
            ? 0
            : (record?.position ?? 0)
        var playItem = (mediaSourceID != nil) ? item.selectingVersion(mediaSourceID) : item
        let probedFacts = await streamProbeCache.completedFacts(for: locator)
        let selectedFileSize = item.versions.first(where: { $0.id == relPath })?.sizeBytes
        var sourceMetadata: MediaSourceMetadata? = {
            let metadata = MediaSourceMetadata(
                container: locator.formatHint.container,
                fileSizeBytes: selectedFileSize
            )
            return metadata.isEmpty ? nil : metadata
        }()
        var audioTracks: [MediaTrack] = []
        if let probedFacts {
            playItem = playItem.applyingSupplementalStreamFacts(probedFacts)
            var metadata = probedFacts.applying()
            metadata.container = locator.formatHint.container
            metadata.fileSizeBytes = selectedFileSize
            sourceMetadata = metadata
            if let trackID = probedFacts.audioTrackID {
                audioTracks = [
                    MediaTrack(
                        id: trackID,
                        kind: .audio,
                        displayTitle: "Track \(trackID)",
                        codec: probedFacts.audioCodec,
                        isDefault: true,
                        channels: probedFacts.audioChannels,
                        isAtmos: probedFacts.audioIsAtmos
                    )
                ]
            }
        }
        // Surface any text sidecar subtitles sitting next to the video (and in a
        // sibling Subs/Subtitles folder) as selectable tracks. Best-effort: a
        // listing/read failure just yields no sidecars rather than blocking play.
        let subtitleTracks = (try? await playbackSource.discoverSidecarSubtitles(
            forVideoRelPath: relPath,
            exactStemOnly: isExtra
        )) ?? []
        return PlaybackRequest(
            item: playItem,
            playbackSource: .networkFile(locator),
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            startPosition: startPosition,
            sourceMetadata: sourceMetadata,
            sourceProvider: .mediaShare,
            serverName: session.server.name,
            sourceFileName: (relPath as NSString).lastPathComponent
        )
    }

    /// Thin forwarder retained for direct tests of the representation-identity
    /// policy; the logic lives in `SharePlaybackSourceService`.
    func networkFileLocator(for relativePath: String) async throws -> NetworkFileLocator {
        try await playbackSource.networkFileLocator(for: relativePath)
    }

    /// Forwarder retained for the sidecar-matching unit tests; the logic lives in
    /// `SharePlaybackSourceService`.
    static func sidecarMatchesVideo(sidecarStem: String, videoStem: String, dedicatedFolder: Bool) -> Bool {
        SharePlaybackSourceService.sidecarMatchesVideo(
            sidecarStem: sidecarStem,
            videoStem: videoStem,
            dedicatedFolder: dedicatedFolder
        )
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        // No server to report to, but persist live progress locally so a hard app
        // kill still leaves a usable resume point.
        await watchState.recordPlayback(progress, event: event)
    }

    // MARK: Images

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        // Artwork via MetadataKit (TMDb) lands in Phase 2c. No poster for now.
        nil
    }

    /// URLComponents produces `nil` for a bare IPv6 literal host (e.g. `fe80::1`)
    /// — it must be bracketed. IPv4 and hostnames never contain a colon, so this
    /// only wraps genuine IPv6 literals (and leaves already-bracketed ones alone).
    public static func bracketedHostIfIPv6(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    /// The inverse: `URLComponents.host` returns an IPv6 literal *bracketed*
    /// (`"[fe80::1]"`) on Apple Foundation, but the SMB layer (`NWEndpoint.Host`)
    /// needs the bare literal — a bracketed string is treated as an unresolvable
    /// DNS name. Strip a matching surrounding `[...]` so the transport gets
    /// `fe80::1`.
    public static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }

    // MARK: - Parse baseURL

    private static func parse(
        _ baseURL: URL
    ) -> (host: String, port: Int?, share: String, rootPathComponents: [String]) {
        let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let host = unbracketedHost(comps?.host ?? "")
        let port = comps?.port
        let pathComponents = (comps?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return (
            host,
            port,
            pathComponents.first ?? "",
            Array(pathComponents.dropFirst())
        )
    }
}

extension ShareProvider: ProviderTeardown {
    /// Release the SMB session when the account is removed / the token refreshes
    /// and the registry evicts this provider.
    public func teardown() async {
        await store.close()
    }
}

extension ShareProvider: CapabilityReporting {
    /// A media share is video-only: no music library, no server-backed remote
    /// subtitle search. Advertised explicitly so capability-gated UI is correct.
    public var capabilities: ProviderCapability { .video }
}

extension ShareProvider: InteractiveBrowseActivityReporting {
    public func noteInteractiveBrowseActivity() async {
        await catalogCoordinator.noteInteractiveActivity(
            accountKey: localMediaContext.accountID
        )
    }
}

extension ShareProvider: SupplementalStreamFactsProviding {
    public func supplementalStreamFacts(for item: MediaItem) async -> ProbedStreamFacts? {
        guard !Task.isCancelled,
              item.kind == .movie || item.kind == .episode || item.kind == .video,
              let streamProber,
              let relativePath = await probeRelativePath(for: item),
              let locator = try? await networkFileLocator(for: relativePath) else {
            return nil
        }
        let requirements = SupplementalStreamProbeRequirements.missingNetworkFileFacts(in: item.mediaInfo)
        return await streamProbeCache.facts(for: locator, requirements: requirements) { missing in
            await streamProber.probe(locator: locator, requirements: missing)
        }
    }

    private func probeRelativePath(for item: MediaItem) async -> String? {
        if let selectedVersionID = item.selectedVersionID, !selectedVersionID.isEmpty {
            return selectedVersionID
        }
        if libraryConfiguration?.contentType == .personalVideos {
            if let versionID = item.versions.first?.id,
               !versionID.hasPrefix("synth:") {
                return versionID
            }
            return await store.path(forItemID: item.id)
        }
        let catalog = await self.catalog
        let canonicalItemID = await catalog.canonicalItemID(item.id)
        if let key = ShareCatalogID.movieKey(forMovieID: canonicalItemID),
           let path = await catalog.defaultMovieRelPath(forKey: key) {
            return path
        }
        if let versionID = item.versions.first?.id,
           !versionID.hasPrefix("synth:") {
            return versionID
        }
        return await store.path(forItemID: item.id)
    }
}

extension ShareProvider: WatchStateProviding {
    /// Live UI toggle (mark watched / unwatched): the action happens *now*, so
    /// stamp with the current time. The outbox-drained path uses the timestamped
    /// ``PlayedStateWriting`` overload below with the play's real capture time.
    public func setPlayed(_ played: Bool, itemID: String) async throws {
        await watchState.setPlayed(played, itemID: itemID, capturedAt: Date())
    }
}

extension ShareProvider: PlayedStateWriting {
    /// Outbox-drained played write: use the play's real `capturedAt` (not the
    /// drain time) so a stale played write that drains after a newer re-watch
    /// can't overwrite the newer resume state — the local store orders writes by
    /// `capturedAt`.
    public func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws {
        await watchState.setPlayed(played, itemID: itemID, capturedAt: capturedAt)
    }
}

extension ShareProvider: ContinueWatchingRemovable {
    /// Hides the title from Continue Watching **without** discarding where the
    /// viewer got to. A share's watch state is ours alone, so unlike a managed
    /// server there is no need to trade one for the other.
    public func removeFromContinueWatching(itemID: String) async throws {
        await watchState.dismissFromContinueWatching(itemID: itemID)
    }
}

extension ShareProvider: ResumeStateWriting {
    /// Persist a resume position locally. `capturedAt` orders writes so a late
    /// draining queued resume can't overwrite a newer state.
    public func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        await watchState.setResumePosition(seconds, itemID: itemID, capturedAt: capturedAt)
    }
}

actor ShareStreamProbeCache {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let cancelled: OSAllocatedUnfairLock<Bool>
    }

    private struct Flight {
        let id: UUID
        let requirements: SupplementalStreamProbeRequirements
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }

    private var completed: [NetworkFileLocator: SupplementalStreamProbeRequirements] = [:]
    private var results: [NetworkFileLocator: ProbedStreamFacts] = [:]
    private var inFlight: [NetworkFileLocator: Flight] = [:]

    var pendingWaiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    func pendingTask(for locator: NetworkFileLocator) -> Task<Void, Never>? {
        inFlight[locator]?.task
    }

    func facts(
        for locator: NetworkFileLocator,
        requirements: SupplementalStreamProbeRequirements,
        loader: @escaping @Sendable (SupplementalStreamProbeRequirements) async -> ProbedStreamFacts?
    ) async -> ProbedStreamFacts? {
        while !Task.isCancelled {
            let missing = requirements.subtracting(completed[locator, default: []])
            guard !missing.isEmpty else { return results[locator] }
            let waiterID = UUID()
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            let finished = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: false)
                        return
                    }
                    let waiter = Waiter(continuation: continuation, cancelled: cancelled)
                    if inFlight[locator] != nil {
                        inFlight[locator]?.waiters[waiterID] = waiter
                    } else {
                        let flightID = UUID()
                        let task = Task(priority: .utility) {
                            let facts = await loader(missing)
                            self.finish(
                                locator: locator, flightID: flightID,
                                facts: facts, cancelled: Task.isCancelled
                            )
                        }
                        inFlight[locator] = Flight(
                            id: flightID, requirements: missing, task: task,
                            waiters: [waiterID: waiter]
                        )
                    }
                }
            } onCancel: {
                // Record synchronously so a finishing loader cannot cache a
                // result while this cancellation is queued on the actor.
                cancelled.withLock { $0 = true }
                Task { await self.cancelWaiter(waiterID, for: locator) }
            }
            guard finished else { return nil }
            // A coalesced request may need coverage beyond the running scan.
        }
        return nil
    }

    private func cancelWaiter(_ id: UUID, for locator: NetworkFileLocator) {
        guard let waiter = inFlight[locator]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
        if inFlight[locator]?.waiters.isEmpty == true {
            let flight = inFlight.removeValue(forKey: locator)
            flight?.task.cancel()
        }
    }

    private func finish(
        locator: NetworkFileLocator, flightID: UUID,
        facts: ProbedStreamFacts?, cancelled: Bool
    ) {
        guard let flight = inFlight[locator], flight.id == flightID else { return }
        inFlight[locator] = nil
        let active = flight.waiters.values.filter { !$0.cancelled.withLock { $0 } }
        let accepted = !cancelled && !active.isEmpty
        if accepted {
            completed[locator, default: []].formUnion(flight.requirements.union(.streamDetails))
            if let facts {
                results[locator] = results[locator]?.merging(facts) ?? facts
            }
        }
        for waiter in flight.waiters.values {
            waiter.continuation.resume(returning: accepted && !waiter.cancelled.withLock { $0 })
        }
    }

    func completedFacts(for locator: NetworkFileLocator) -> ProbedStreamFacts? {
        return results[locator]
    }
}
