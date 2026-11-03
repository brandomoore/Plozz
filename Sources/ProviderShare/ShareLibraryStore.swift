import Foundation
import CoreModels
import MediaTransportCore
import CoreNetworking

/// Lazy folder browser over an SMB share.
///
/// A general-purpose file share (unlike Plex/Jellyfin) has no notion of
/// "libraries", curated metadata, or a clean movie/episode split — the root
/// holds whatever the user put there (Movies, TV Shows, Downloads, Photos, …).
/// Trying to recursively scan-and-classify everything produced thousands of
/// bogus "movies" from non-media folders. So instead — exactly like Infuse's
/// Files mode, VLC, or Kodi's file view — we present the **real directory tree**
/// and let the user navigate it. Each directory is listed on demand (one network
/// round-trip per folder the user actually opens); nothing is walked eagerly.
///
/// Item id scheme (share-relative path, no leading slash):
///   * root container  → `Self.rootLibraryID`
///   * a sub-folder     → `"d:<relpath>"`   (kind `.folder`, navigable)
///   * a playable file  → `"f:<relpath>"`   (kind `.video`, playable)
actor ShareLibraryStore {
    /// The single synthetic "library" a share exposes: its root folder. Browsing
    /// it lists the real top-level folders/files, and the user drills in from
    /// there. Home aggregation can show this instantly (no network) — the listing
    /// only happens when the row is actually opened.
    static let rootLibraryID = "share:root"

    private let browser: ShareTransportBrowser
    private let serverName: String
    private let configuration: MediaShareLibraryConfiguration?

    init(
        browser: ShareTransportBrowser,
        serverName: String,
        configuration: MediaShareLibraryConfiguration? = nil
    ) {
        self.browser = browser
        self.serverName = serverName
        self.configuration = configuration
    }

    // MARK: - Libraries

    /// Best-effort release of the underlying SMB session when the provider is
    /// evicted from the registry (account removed / token refreshed).
    func close() async {
        await browser.close()
    }

    /// Raw directory listing (share-relative), for sidecar discovery at playback
    /// time. Unlike `entries(forContainerID:)` this returns every entry (incl.
    /// subtitle files), not just folders + videos.
    func rawEntries(inDirectory relPath: String) async throws -> [RemoteFileEntry] {
        try await browser.listDirectory(relPath)
    }

    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try await browser.stat(relativePath)
    }

    func statForOpening(relativePath: String) async throws -> RemoteFileEntry {
        try await browser.statForOpening(relativePath)
    }

    /// Read a file's bytes off the share (share-relative path). Used to pull small
    /// sidecar subtitles into a local temp for the overlay.
    func readFile(_ relPath: String, maximumBytes: Int = 16 * 1_024 * 1_024) async throws -> Data {
        try await browser.readFile(relPath, maximumBytes: maximumBytes)
    }

    /// A share presents exactly one browsable "library": its root folder. Kept as
    /// `.folder` so the browse UI treats every entry as navigable/​playable by its
    /// own kind rather than forcing a movie/series split.
    func libraries() -> [MediaLibrary] {
        [Self.rootLibrary(serverName: serverName, configuration: configuration)]
    }

    static func rootLibrary(
        serverName: String,
        configuration: MediaShareLibraryConfiguration?
    ) -> MediaLibrary {
        let name = configuration?.name ?? serverName
        let title = configuration?.contentType == .personalVideos
            ? name
            : "Browse Files — \(name)"
        return MediaLibrary(
            id: Self.rootLibraryID,
            title: title,
            kind: .folder,
            synthesizedName: configuration?.contentType == .personalVideos
                ? nil
                : .browseFiles
        )
    }

    // MARK: - Directory listing (lazy, one folder per call)

    /// List a container (root or a `"d:<relpath>"` folder) as MediaItems:
    /// sub-folders become navigable `.folder` items, playable files become
    /// `.video` items, everything else (photos, docs, `.DS_Store`, …) is hidden.
    /// Folders sort first, then files, both case-insensitively by name.
    func entries(forContainerID id: String) async throws -> [MediaItem] {
        try await loadEntries(forContainerID: id, sort: nil)
    }

    /// Paged file browsing needs filesystem-backed "Date Added" ordering before
    /// entries are projected into catalog items (MediaItem intentionally carries
    /// no provider date-added value). Other fields are ordered after projection
    /// by ShareProvider, when enriched runtime/rating metadata is available.
    func entries(
        forContainerID id: String,
        sort: CoreModels.SortDescriptor,
        foldersFirst: Bool = true
    ) async throws -> [MediaItem] {
        try await loadEntries(forContainerID: id, sort: sort, foldersFirst: foldersFirst)
    }

    private func loadEntries(
        forContainerID id: String,
        sort: CoreModels.SortDescriptor?,
        foldersFirst: Bool = true
    ) async throws -> [MediaItem] {
        let relPath = Self.relativePath(forContainerID: id)
        guard let relPath else { return [] }
        let entries = try await browser.listDirectory(relPath)

        var folders: [(item: MediaItem, addedAt: Date?)] = []
        var videos: [(item: MediaItem, addedAt: Date?)] = []
        for entry in entries {
            let childPath = relPath.isEmpty ? entry.name : "\(relPath)/\(entry.name)"
            let row: (item: MediaItem, addedAt: Date?)
            if entry.kind == .directory {
                row = (
                    folderItem(relPath: childPath, name: entry.name),
                    entry.createdAt ?? entry.modifiedAt
                )
                folders.append(row)
            } else if ShareMediaParser.isLibraryMediaFile(entry.name) {
                row = (
                    videoItem(relPath: childPath, name: entry.name),
                    entry.createdAt ?? entry.modifiedAt
                )
                videos.append(row)
            }
        }
        if sort?.field == .dateAdded, let sort {
            if !foldersFirst {
                return (folders + videos)
                    .sorted { Self.dateOrder($0, $1, direction: sort.direction) }
                    .map(\.item)
            }
            folders.sort { Self.dateOrder($0, $1, direction: sort.direction) }
            videos.sort { Self.dateOrder($0, $1, direction: sort.direction) }
        } else {
            folders.sort {
                $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
            videos.sort { Self.videoOrder($0.item, $1.item) }
        }
        return (folders + videos).map(\.item)
    }

    private static func dateOrder(
        _ lhs: (item: MediaItem, addedAt: Date?),
        _ rhs: (item: MediaItem, addedAt: Date?),
        direction: SortDirection
    ) -> Bool {
        switch (lhs.addedAt, rhs.addedAt) {
        case let (left?, right?) where left != right:
            return direction == .ascending ? left < right : left > right
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        default:
            let order = lhs.item.title.localizedStandardCompare(rhs.item.title)
            return order == .orderedSame
                ? lhs.item.id < rhs.item.id
                : order == .orderedAscending
        }
    }

    /// Total ordering for a folder's playable files. Episodes (those the parser
    /// resolved a season + episode number for) sort by `(season, episode)` so
    /// "Episode 2" precedes "Episode 10" regardless of title text; everything
    /// without episode numbers (movies, unparsed files) sorts after episodes and
    /// among itself by natural, number-aware title order. Using explicit sort keys
    /// (rather than a branchy comparator) keeps the order strict and total even
    /// when a folder mixes episodes and non-episodes.
    private static func videoOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let ls = lhs.seasonNumber ?? Int.max
        let rs = rhs.seasonNumber ?? Int.max
        if ls != rs { return ls < rs }
        let le = lhs.episodeNumber ?? Int.max
        let re = rhs.episodeNumber ?? Int.max
        if le != re { return le < re }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    // MARK: - Item / path lookup (derived from the id — no network)

    /// Reconstruct a MediaItem straight from its id. Folder/root/video ids all
    /// encode their share-relative path, so this needs no scan and no cache — the
    /// title is just the last path component (or the share name for the root).
    func item(id: String) -> MediaItem? {
        if id == Self.rootLibraryID {
            return folderItem(relPath: "", name: configuration?.name ?? serverName)
        }
        if id.hasPrefix("d:") {
            let relPath = String(id.dropFirst(2))
            return folderItem(relPath: relPath, name: Self.lastComponent(relPath))
        }
        if id.hasPrefix("f:") {
            let relPath = String(id.dropFirst(2))
            return videoItem(relPath: relPath, name: Self.lastComponent(relPath))
        }
        return nil
    }

    /// The share-relative path backing a playable item id, or nil for containers.
    func path(forItemID id: String) -> String? {
        id.hasPrefix("f:") ? String(id.dropFirst(2)) : nil
    }

    // MARK: - Search (best-effort shallow walk)

    /// A file share has no index, so a true search would mean walking the whole
    /// tree on every query. Slice (a) keeps browsing snappy and skips search; a
    /// cached index-backed search arrives with the metadata phase.
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        []
    }

    // MARK: - Model → MediaItem

    private func folderItem(relPath: String, name: String) -> MediaItem {
        let id = relPath.isEmpty ? Self.rootLibraryID : "d:\(relPath)"
        return MediaItem(
            id: id,
            title: name,
            kind: .folder,
            allowsTitleBasedMetadataMatching: false
        )
    }

    private func videoItem(relPath: String, name: String) -> MediaItem {
        var item = classifiedVideoItem(relPath: relPath, name: name)
        if ShareMediaParser.isExternalLinkFile(name) {
            item.versions = [MediaVersion(id: relPath, fileName: name, isDefault: true, container: "strmlnk")]
        }
        return item
    }

    private func classifiedVideoItem(relPath: String, name: String) -> MediaItem {
        // Enrich the bare file into a movie/episode so the generic MetadataKit
        // artwork pipeline (ArtworkRouter → TMDb/TVmaze/AniList) can resolve a
        // poster/backdrop and the detail page can look up an overview. Nothing
        // here is a *match* yet — it's a best-effort parse of the filename (and
        // its folder) into a clean title + year + season/episode; a wrong guess
        // just falls back to the clean title on a neutral card.
        let id = "f:\(relPath)"
        guard let classification = ShareMediaParser.classify(
            relPath: relPath,
            configuration: configuration
        ) else {
            return MediaItem(
                id: id,
                title: Self.displayTitle(forFileName: name),
                kind: .video,
                allowsTitleBasedMetadataMatching: false
            )
        }
        switch classification {
        case .movie(let movie):
            return MediaItem(
                id: id,
                title: movie.title.isEmpty ? Self.displayTitle(forFileName: name) : movie.title,
                kind: .movie,
                productionYear: movie.year
            )
        case .episode(let episode):
            let fallbackTitle = "S\(episode.season)·E\(String(format: "%02d", episode.episode))"
            return MediaItem(
                id: id,
                title: episode.title ?? fallbackTitle,
                kind: .episode,
                parentTitle: episode.series,
                seasonNumber: episode.season,
                episodeNumber: episode.episode
            )
        }
    }

    // MARK: - Helpers

    /// Map a container id to its share-relative path (root → "").
    private static func relativePath(forContainerID id: String) -> String? {
        if id == rootLibraryID { return "" }
        if id.hasPrefix("d:") { return String(id.dropFirst(2)) }
        return nil
    }

    private static func lastComponent(_ relPath: String) -> String {
        relPath.split(separator: "/").last.map(String.init) ?? relPath
    }

    /// Drop the file extension for a cleaner on-screen title while still showing
    /// the real file name (no aggressive "movie parser" rewriting — the user
    /// asked to see their actual files).
    private static func displayTitle(forFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}
