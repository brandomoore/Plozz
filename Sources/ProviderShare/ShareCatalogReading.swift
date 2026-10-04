import Foundation
import CoreModels

/// The read-only catalog surface `ShareProvider` needs from its app-owned SQLite
/// index. It returns only public/core models (`MediaItem`, counts, ids) and never
/// exposes the concrete `ShareCatalogStore` actor, so the provider — and its
/// tests — depend on a narrow capability rather than the 3k-line store.
///
/// Every requirement is `async`: the production witness is the actor-isolated
/// `ShareCatalogStore`, and fakes can answer synchronously.
public protocol ShareCatalogReading: Sendable {
    /// Per-kind indexed counts used to decide which synthetic libraries appear.
    func libraryCounts() async -> (movies: Int, tvSeries: Int, animeSeries: Int)

    /// Recently-added items (by first-discovery date) for the Home hot path.
    func latest(limit: Int) async -> [MediaItem]

    /// Indexed search over catalog titles.
    func search(query: String, limit: Int) async -> [MediaItem]

    /// One page of movies for the Movies grid.
    func movies(offset: Int, limit: Int) async -> [MediaItem]

    /// One page of movies using the caller's advertised library sort.
    func movies(
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) async -> [MediaItem]

    /// One page of series for a TV/Anime grid.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) async -> [MediaItem]

    /// One page of series using the caller's advertised library sort.
    func series(
        in library: CatalogLibrary,
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) async -> [MediaItem]

    /// Exact indexed movie count (for stable grid sizing).
    func movieCount() async -> Int

    /// Exact indexed series count for a library.
    func seriesCount(in library: CatalogLibrary) async -> Int

    /// Seasons under a series.
    func seasons(seriesKey: String) async -> [MediaItem]

    /// Episodes under a season.
    func episodes(seriesKey: String, season: Int) async -> [MediaItem]

    /// Every episode file in a series, keyed for watch-state lookup and grouped by
    /// season and *logical* episode, so a season container's played state can be
    /// rolled up from its episodes in one pass instead of a query per season.
    func episodeWatchIdentities(seriesKey: String) async -> [(season: Int, logicalKey: String, fileID: String)]
    func libraryQueryFacets(in library: CatalogLibrary) async throws -> LibraryQueryFacets
    func libraryQueryEpisodes(in library: CatalogLibrary, offset: Int, limit: Int) async throws -> MediaPage

    /// A single indexed item, or nil for un-indexed raw file ids.
    func item(id: String) async -> MediaItem?

    /// Items whose persisted cast includes this person, by TMDb id or by name.
    /// Fully local — a share resolves its cast at scan time, so a person page
    /// works offline and needs no third party at read time.
    ///
    /// Defaulted, so a conformer with no cast to search (test doubles, readers
    /// built before this existed) reports none rather than failing to compile.
    func itemsWithPerson(id personID: String?, name: String, limit: Int) async -> [MediaItem]

    /// The default playable file rel-path for a logical movie key.
    func defaultMovieRelPath(forKey key: String) async -> String?

    /// Collapses a legacy/member-file id onto its canonical logical id.
    func canonicalItemID(_ id: String) async -> String

    /// Maps requested ids to the stored watch-state alias ids the watch store
    /// keys on (so several version records fold onto one canonical id).
    func watchStateAliases(for itemIDs: [String]) async -> [String: String]

    /// Whether a raw file id is a known indexed file asset.
    func containsFileAsset(id: String) async -> Bool

    /// Bonus videos attached to one proven catalog or explicit folder owner.
    func extras(ownerID: String) async -> [MediaExtra]

    /// One separately inventoried bonus video addressed by its ordinary `f:` id.
    func extra(fileID: String) async -> MediaExtra?

    /// `nil` for a normal asset, otherwise the extra's resume policy.
    func extraResumeBehavior(fileID: String) async -> Bool?

    /// Projects one live directory listing through the local catalog.
    ///
    /// Raw entries remain the source of truth for hierarchy and unindexed files.
    /// The catalog may resolve files or add a logical movie/series/season beside
    /// a physical folder only when persisted path/membership evidence proves the
    /// identity. Promoted folders carry a separate raw file-browser route so
    /// content added since the last inventory remains reachable from details.
    func browseItems(_ items: [MediaItem]) async -> [MediaItem]
}

/// The concrete SQLite-backed store is the production witness. Its async reads
/// can wait for lifecycle admission without touching SQLite while suspended.
extension ShareCatalogStore: ShareCatalogReading {}

public extension ShareCatalogReading {
    func libraryQueryFacets(in library: CatalogLibrary) async throws -> LibraryQueryFacets { throw AppError.notFound }
    func libraryQueryEpisodes(in library: CatalogLibrary, offset: Int, limit: Int) async throws -> MediaPage { throw AppError.notFound }
    func movies(
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) async -> [MediaItem] {
        await movies(offset: offset, limit: limit)
    }

    func series(
        in library: CatalogLibrary,
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) async -> [MediaItem] {
        await series(in: library, offset: offset, limit: limit)
    }

    /// Default: no searchable cast.
    func itemsWithPerson(id personID: String?, name: String, limit: Int) async -> [MediaItem] { [] }

    func extras(ownerID: String) async -> [MediaExtra] { [] }
    func extra(fileID: String) async -> MediaExtra? { nil }
    func extraResumeBehavior(fileID: String) async -> Bool? { nil }
    func browseItems(_ items: [MediaItem]) async -> [MediaItem] { items }
}
