import Foundation
import SQLite3
import CoreModels
import CoreNetworking
import MetadataKit

/// Reference box for the store's "does this catalog have ANY local (NFO/filename)
/// metadata at all" memo. It lets the read-query helper share — and lazily populate —
/// the *exact same* cached flag that `ShareCatalogStore`'s write paths invalidate, so
/// the "no real query on every read-path call for the common no-NFO catalog"
/// optimization is preserved without the store re-implementing the read cluster.
/// Only ever touched under the store actor's isolation (all reads are serialized), so
/// the shared mutable flag races nothing.
final class LocalMetadataPresence {
    var cached: Bool?
    init(_ cached: Bool? = nil) { self.cached = cached }
}

/// Pure, synchronous, transaction-free **read-query composition** for one share
/// catalog, running over the store-owned, actor-confined `CatalogConnection`. It owns
/// the catalog *read path* — the `MediaItem`-building queries the Home grid, search,
/// detail, seasons/episodes, and watch-state stamping issue — plus the persisted
/// enrichment/local-metadata overlay that decorates those items, the movie-grouping
/// resolution reads, and the small assets-count intents. It depends only on the
/// connection plus module-level pure types (`ShareCatalogReadProjection`,
/// `ShareCatalogID`, `ShareMediaParser`, `EnrichmentRepository`, and the enrichment
/// DTOs), never on `ShareCatalogStore`.
///
/// A cheap value type constructed on demand by the store; it holds no independent
/// mutable lifecycle state, actor, queue, or SQLite connection, and never opens a
/// transaction. `normalizedMetadataReady` is a value snapshot supplied by the store
/// (reads are serialized on the store actor, so it equals the live value for the
/// duration of one read), and the "has any local metadata" memo is shared via the
/// store-owned `LocalMetadataPresence` box. The store's public read methods forward
/// here after `ensureOpen()`, so these bodies assume an already-open connection.
struct CatalogReadQueries {
    /// Keeps every dynamic `IN`/`VALUES` statement comfortably below SQLite's
    /// variable limit, including older catalog runtimes with the 999-variable
    /// default. Physical-folder browsing can hand this type thousands of ids.
    private static let browseHydrationBatchSize = 200

    let connection: CatalogConnection
    /// Value snapshot of the store's `normalizedMetadataReady` — whether the local
    /// metadata materialization has completed and normalized winners may be overlaid.
    let normalizedMetadataReady: Bool
    /// Snapshot of household provider + artwork precedence for this read.
    let metadataConfig: MetadataEnrichmentConfig
    /// Shared, store-owned memo for `hasAnyLocalMetadata()` (invalidated by store writes).
    let localMetadataPresence: LocalMetadataPresence

    /// Bridge so the moved raw `sqlite3_*` call sites read the connection's handle
    /// unchanged; the connection owns its lifetime (open/close), which the store's
    /// forwarders guarantee before delegating here.
    private var db: OpaquePointer? { connection.db }

    /// The `cast_json` column expression for an enrichment SELECT, or a literal
    /// `NULL` when the column isn't there.
    ///
    /// A catalog whose schema migration failed — the "keep reading a legacy catalog
    /// rather than lose it" path — never gains the column, and naming it directly
    /// would fail the *whole* statement, so a single new field would take every
    /// other enrichment value down with it. Degrading to NULL keeps such a catalog
    /// fully readable minus the one thing it genuinely doesn't have.
    private var castColumn: String {
        connection.hasColumn(table: "enrichment", column: "cast_json") ? "cast_json" : "NULL"
    }

    /// The same expression qualified for a joined `enrichment e`.
    private var joinedCastColumn: String {
        castColumn == "cast_json" ? "e.cast_json" : "NULL"
    }

    /// Leaf enrichment persistence over the same actor-confined connection — used only
    /// for the `hasUsableEnrichment` fast-path check inside `pendingEnrichment`.
    private var enrichmentRepo: EnrichmentRepository { EnrichmentRepository(connection: connection) }

    // MARK: - Read path (build MediaItems)

    /// Whether the catalog has any indexed content yet (false on a fresh share
    /// before the first scan populates it).
    func isEmpty() -> Bool { count(where: nil) == 0 }

    /// Per-library counts so `libraries()` can hide an indexed library that has no
    /// content yet (movies = files; tv/anime = distinct series).
    func libraryCounts() -> (movies: Int, tvSeries: Int, animeSeries: Int) {
        let movies = count(where: "library='movies' AND kind='movie'")
        let tv = distinctSeriesCount(library: .tv)
        let anime = distinctSeriesCount(library: .anime)
        return (movies, tv, anime)
    }

    /// A one-line summary of what the scan actually indexed, for on-device
    /// diagnosis of "my show isn't in the TV Shows library". Answers the three
    /// questions that distinguish the possible causes: is the file in `assets` at
    /// all, what `kind`/`library` did the scan give it, and did it get a
    /// `series_key` (the column the TV/Anime library queries require).
    func catalogSummary() -> String {  // l10n:content — developer-facing diagnostic, never shown in UI
        guard db != nil else { return "catalog unavailable" }
        var parts: [String] = []
        parts.append("assets=" + String(count(where: nil)))
        for kind in ["movie", "episode"] {
            parts.append("\(kind)=" + String(count(where: "kind='\(kind)'")))
        }
        for library in ["movies", "tv", "anime"] {
            parts.append("lib.\(library)=" + String(count(where: "library='\(library)'")))
        }
        parts.append("episodeNoSeriesKey="
            + String(count(where: "kind='episode' AND series_key IS NULL")))
        parts.append("tvSeries=" + String(distinctSeriesCount(library: .tv)))
        parts.append("animeSeries=" + String(distinctSeriesCount(library: .anime)))
        return parts.joined(separator: " ")
    }

    /// Every distinct series key the scan grouped, with its library and episode
    /// count. Bounded so a large share can't flood the log.
    func seriesKeySummary(limit: Int = 400) -> [String] {
        guard db != nil else { return [] }
        var rows: [String] = []
        query("""
        SELECT series_key, library, COUNT(*), MIN(series_title)
        FROM assets WHERE kind='episode'
        GROUP BY series_key, library ORDER BY series_key LIMIT ?;
        """, bind: { sqlite3_bind_int($0, 1, Int32(limit)) }) { stmt in
            let key = CatalogConnection.columnText(stmt, 0) ?? "<null>"
            let library = CatalogConnection.columnText(stmt, 1) ?? "?"
            let count = Int(sqlite3_column_int64(stmt, 2))
            let title = CatalogConnection.columnText(stmt, 3) ?? "?"
            rows.append("\(library)/\(key) n=\(count) title=\(title)")
        }
        return rows
    }

    /// Rows whose `rel_path` contains one of `needles`, so "my show isn't in the
    /// library" can be answered directly: either the file is absent from `assets`
    /// (the scan never recorded it) or it is present and the row says why it was
    /// filed elsewhere.
    func pathProbe(_ needles: [String], limit: Int = 12) -> [String] {
        guard db != nil else { return [] }
        var rows: [String] = []
        for needle in needles {
            var found = 0
            query("""
            SELECT rel_path, kind, library, series_key, season, episode
            FROM assets WHERE rel_path LIKE ? LIMIT ?;
            """, bind: { stmt in
                self.bindText(stmt, 1, "%\(needle)%")
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }) { stmt in
                found += 1
                let path = CatalogConnection.columnText(stmt, 0) ?? "?"
                let kind = CatalogConnection.columnText(stmt, 1) ?? "?"
                let library = CatalogConnection.columnText(stmt, 2) ?? "?"
                let key = CatalogConnection.columnText(stmt, 3) ?? "<null>"
                let season = CatalogConnection.columnOptInt(stmt, 4).map(String.init) ?? "nil"
                let episode = CatalogConnection.columnOptInt(stmt, 5).map(String.init) ?? "nil"
                rows.append("probe<\(needle)> kind=\(kind) lib=\(library) key=\(key) s=\(season) e=\(episode) path=\(path)")
            }
            if found == 0 { rows.append("probe<\(needle)> NO ROWS in assets") }
        }
        return rows
    }

    /// Discovery times are bucketed to five minutes before ordering.
    ///
    /// Sized to a scan, not to a day. It has to be long enough to swallow one
    /// walk, so that a rebuild's per-row jitter — which encodes directory order,
    /// not recency — collapses instead of masquerading as a ranking. And it has to
    /// stay short enough to preserve discoveries that are genuinely apart: two
    /// files found minutes from each other really were added in that order, and an
    /// hour-wide bucket threw that away.
    static let discoveryBucketSeconds = 300

    /// Recently added: movies + one entry per series (stamped with the series'
    /// newest episode discovery time), newest first. Non-network — Home hot path safe.
    ///
    /// Ordered by *discovery hour*, then by the file's own modification time.
    ///
    /// `first_seen_at` alone is not enough, for two reasons that compound. It is
    /// stamped per row as the walk reaches it, so everything a single scan finds
    /// differs only by milliseconds — and those milliseconds encode **directory
    /// walk order**, which looks like a meaningful ordering and is not. And it
    /// resets wholesale whenever rows are re-inserted (a share re-added, a catalog
    /// rebuilt), which leaves the entire library claiming to have arrived at once.
    /// Measured on a real device mid-development: 8,195 of 8,195 assets had been
    /// first seen within the hour, so Recently Added was sorting eight thousand
    /// items by walk order and burying that day's genuinely new arrivals.
    ///
    /// Bucketing discovery to the hour collapses that jitter, and the file's own
    /// mtime then orders within it. Both cases come out right:
    ///
    ///  * a file that arrives now lands in the newest bucket alone, so it sorts
    ///    first whatever its mtime says — a decade-old film added today is still
    ///    "recently added";
    ///  * after a rebuild everything shares one bucket, so mtime decides, which is
    ///    the only true recency signal left once discovery time has been erased.
    ///
    /// The id is the final tiebreaker, so the sequence can never depend on the
    /// order SQLite happens to return rows in.
    func latest(limit: Int) -> [MediaItem] {
        guard db != nil, limit > 0 else { return [] }
        var out: [(bucket: Int64, mtime: Double, item: MediaItem)] = []

        // Movies — grouped by movie_key so a multi-file film is one Recently Added
        // card, dated by the FIRST version discovered (when the movie appeared).
        query("""
        SELECT
          CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
               THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year),
          CAST(MIN(first_seen_at) / \(Self.discoveryBucketSeconds) AS INTEGER) AS bucket,
          MAX(modified_at) AS mtime
        FROM assets WHERE library='movies' AND kind='movie'
        GROUP BY COALESCE(movie_group_key, movie_key, rel_path)
        ORDER BY bucket DESC, mtime DESC, logical_id ASC LIMIT ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            let item = MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            )
            out.append((sqlite3_column_int64(stmt, 3), self.columnDouble(stmt, 4), item))
        }

        // Series (tv + anime), represented by the series card, dated by newest episode.
        query("""
        SELECT series_key, series_title, library,
          CAST(MAX(first_seen_at) / \(Self.discoveryBucketSeconds) AS INTEGER) AS bucket,
          MAX(year), MAX(modified_at) AS mtime
        FROM assets WHERE kind='episode' AND series_key IS NOT NULL
        GROUP BY series_key, library
        ORDER BY bucket DESC, mtime DESC, series_key ASC LIMIT ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let lib = CatalogLibrary(rawValue: self.columnText(stmt, 2) ?? "tv") ?? .tv
            out.append((
                sqlite3_column_int64(stmt, 3),
                self.columnDouble(stmt, 5),
                ShareCatalogReadProjection.seriesItem(
                    key: key,
                    title: self.columnText(stmt, 1) ?? key,
                    library: lib,
                    year: self.columnOptInt(stmt, 4)
                )
            ))
        }

        // The same ordering as the queries, since this merges two already-sorted
        // sets and `sorted(by:)` is not guaranteed stable — equal keys would
        // otherwise re-order here even though the SQL is deterministic.
        return withEnrichment(
            out.sorted { lhs, rhs in
                if lhs.bucket != rhs.bucket { return lhs.bucket > rhs.bucket }
                if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
                return lhs.item.id < rhs.item.id
            }.prefix(limit).map(\.item)
        )
    }

    /// Free-text search across movie/episode titles and series titles. `LIKE` is
    /// fine at share scale (a few thousand rows) and stays index-light; FTS is a
    /// later refinement. Returns movie + series items.
    func search(query q: String, limit: Int) -> [MediaItem] {
        guard db != nil, limit > 0 else { return [] }
        let needle = "%\(q.lowercased())%"
        var out: [MediaItem] = []

        query("""
        SELECT
          CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
               THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
               ELSE 'f:' || MIN(rel_path) END AS logical_id,
          MIN(title), MAX(year)
        FROM assets
        WHERE library='movies' AND kind='movie' AND LOWER(title) LIKE ?
        GROUP BY COALESCE(movie_group_key, movie_key, rel_path) LIMIT ?;
        """, bind: {
            self.bindText($0, 1, needle); sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            out.append(MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary
            ))
        }

        query("""
        SELECT series_key, series_title, library, MAX(year) FROM assets
        WHERE kind='episode' AND series_key IS NOT NULL AND LOWER(series_title) LIKE ?
        GROUP BY series_key, library LIMIT ?;
        """, bind: {
            self.bindText($0, 1, needle); sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            let lib = CatalogLibrary(rawValue: self.columnText(stmt, 2) ?? "tv") ?? .tv
            out.append(ShareCatalogReadProjection.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: lib, year: self.columnOptInt(stmt, 3)))
        }

        return withEnrichment(Array(out.prefix(limit)))
    }

    /// Movie items for the Movies library grid (paged). Movies are **grouped** by
    /// `movie_key` so several files of one film collapse to a single logical card
    /// (`movie:<key>`); a row with no key (pre-reparse) stands alone under its own
    /// `f:<rel_path>` id via `COALESCE`. Enrichment is read from the group's
    /// representative file id (`f:<MIN(rel_path)>`), which already carries art —
    /// so grouping never blanks a card.
    func movies(offset: Int, limit: Int) -> [MediaItem] {
        movies(offset: offset, limit: limit, sort: .default)
    }

    func movies(
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) -> [MediaItem] {
        guard db != nil else { return [] }
        var rows: [(item: MediaItem, enrichmentID: String, record: EnrichmentRecord?)] = []
        let order = catalogOrderClause(sort: sort)
        query("""
        SELECT g.logical_id, g.title, g.year, g.rep_id,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url, e.title, \(joinedCastColumn),
               COALESCE(
                 CASE WHEN json_valid(sv.value_json) THEN json_extract(sv.value_json, '$') END,
                 g.gsort
               ) AS catalog_sort_name,
               g.date_added AS catalog_date_added,
               CASE
                 WHEN json_valid(pd.value_json)
                   THEN json_extract(pd.value_json, '$')
                 WHEN json_valid(py.value_json)
                   THEN printf('%04d', CAST(json_extract(py.value_json, '$') AS INTEGER))
                 WHEN g.year IS NOT NULL
                   THEN printf('%04d', g.year)
               END AS catalog_release_date,
               (
                 SELECT
                   CAST(json_extract(j.value, '$.value') AS REAL)
                   / NULLIF(CAST(COALESCE(json_extract(j.value, '$.max'), 10) AS REAL), 0)
                 FROM json_each(
                   CASE WHEN json_valid(cr.value_json) THEN cr.value_json ELSE '[]' END
                 ) j
                 WHERE j.type='object'
                   AND json_type(j.value, '$.value') IN ('integer', 'real')
                   AND CAST(json_extract(j.value, '$.value') AS REAL) >= 0
                 ORDER BY COALESCE(json_extract(j.value, '$.isDefault'), 0) DESC, j.key
                 LIMIT 1
               ) AS catalog_community_rating,
               COALESCE(
                 CASE WHEN json_valid(rt.value_json)
                   THEN CAST(json_extract(rt.value_json, '$') AS REAL) END,
                 e.runtime
               ) AS catalog_runtime,
               \(stableRandomOrderExpression("g.logical_id")) AS catalog_random,
               g.title AS catalog_display_title,
               g.logical_id AS catalog_stable_id
        FROM (
          SELECT
            CASE WHEN MIN(COALESCE(movie_group_key, movie_key)) IS NOT NULL
                 THEN 'movie:' || MIN(COALESCE(movie_group_key, movie_key))
                 ELSE 'f:' || MIN(rel_path) END AS logical_id,
            'f:' || MIN(rel_path) AS rep_id,
            MIN(title) AS title, MAX(year) AS year, MIN(sort_title) AS gsort,
            MIN(first_seen_at) AS date_added
          FROM assets WHERE library='movies' AND kind='movie'
          GROUP BY COALESCE(movie_group_key, movie_key, rel_path)
        ) g
        LEFT JOIN enrichment e ON e.item_id = g.rep_id
        -- A winning NFO `sortTitle` candidate (see the Step 3 field table) sorts
        -- the grid AHEAD of the scan-owned `assets.sort_title` — computed here so
        -- pagination (LIMIT/OFFSET) already reflects it; `assets.sort_title` itself
        -- is never mutated (it stays the scanner's own fallback).
        LEFT JOIN metadata_values sv
          ON sv.item_id = g.rep_id AND sv.field = 'sortTitle' AND sv.source = 'localNFO'
        LEFT JOIN metadata_values pd
          ON pd.item_id = g.rep_id AND pd.field = 'premiereDate' AND pd.source = 'localNFO'
        LEFT JOIN metadata_values py
          ON py.item_id = g.rep_id AND py.field = 'productionYear' AND py.source = 'localNFO'
        LEFT JOIN metadata_values cr
          ON cr.item_id = g.rep_id AND cr.field = 'ratings' AND cr.source = 'localNFO'
        LEFT JOIN metadata_values rt
          ON rt.item_id = g.rep_id AND rt.field = 'runtime' AND rt.source = 'localNFO'
        ORDER BY \(order)
        LIMIT ? OFFSET ?;
        """, bind: { sqlite3_bind_int64($0, 1, Int64(limit)); sqlite3_bind_int64($0, 2, Int64(offset)) }) { stmt in
            let item = MediaItem(
                id: self.columnText(stmt, 0) ?? "",
                title: self.columnText(stmt, 1) ?? "",
                kind: .movie,
                productionYear: self.columnOptInt(stmt, 2),
                libraryID: ShareCatalogID.moviesLibrary,
                librarySortValues: LibrarySortValues(
                    sortName: self.columnText(stmt, 13),
                    dateAdded: sqlite3_column_type(stmt, 14) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
                )
            )
            rows.append((
                item,
                self.columnText(stmt, 3) ?? item.id,
                ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        // `rep_id` from the grouped query above IS the group-representative id the
        // overlay would otherwise re-derive per card with its own SQLite lookups.
        let artworkKeys = Dictionary(
            rows.map { ($0.item.id, $0.enrichmentID) },
            uniquingKeysWith: { first, _ in first }
        )
        return withLocalOverlay(
            rows.map { row in
                hydrated[row.enrichmentID].map { ShareCatalogReadProjection.applyEnrichment(row.item, $0) } ?? row.item
            },
            artworkKeys: artworkKeys
        )
    }

    /// Distinct series items for a TV/Anime library, alphabetical.
    func series(in library: CatalogLibrary, offset: Int, limit: Int) -> [MediaItem] {
        series(in: library, offset: offset, limit: limit, sort: .default)
    }

    func series(
        in library: CatalogLibrary,
        offset: Int,
        limit: Int,
        sort: CoreModels.SortDescriptor
    ) -> [MediaItem] {
        guard db != nil, library != .movies else { return [] }
        var rows: [(item: MediaItem, enrichmentID: String, record: EnrichmentRecord?)] = []
        let order = catalogOrderClause(sort: sort)
        query("""
        WITH grouped AS (
          SELECT series_key, MIN(series_title) AS title, MAX(year) AS year,
                 MIN(sort_title) AS sort_name, MIN(first_seen_at) AS date_added
          FROM assets
          WHERE library=? AND kind='episode' AND series_key IS NOT NULL
          GROUP BY series_key
        )
        SELECT g.series_key, g.title, g.year, g.sort_name,
               e.provider_ids_json, e.overview, e.genres_json, e.runtime,
               e.poster_url, e.backdrop_url, e.logo_url, e.title, \(joinedCastColumn),
               COALESCE(
                 CASE WHEN json_valid(sv.value_json) THEN json_extract(sv.value_json, '$') END,
                 g.sort_name
               ) AS catalog_sort_name,
               g.date_added AS catalog_date_added,
               CASE
                 WHEN json_valid(pd.value_json)
                   THEN json_extract(pd.value_json, '$')
                 WHEN json_valid(py.value_json)
                   THEN printf('%04d', CAST(json_extract(py.value_json, '$') AS INTEGER))
                 WHEN g.year IS NOT NULL
                   THEN printf('%04d', g.year)
               END AS catalog_release_date,
               (
                 SELECT
                   CAST(json_extract(j.value, '$.value') AS REAL)
                   / NULLIF(CAST(COALESCE(json_extract(j.value, '$.max'), 10) AS REAL), 0)
                 FROM json_each(
                   CASE WHEN json_valid(cr.value_json) THEN cr.value_json ELSE '[]' END
                 ) j
                 WHERE j.type='object'
                   AND json_type(j.value, '$.value') IN ('integer', 'real')
                   AND CAST(json_extract(j.value, '$.value') AS REAL) >= 0
                 ORDER BY COALESCE(json_extract(j.value, '$.isDefault'), 0) DESC, j.key
                 LIMIT 1
               ) AS catalog_community_rating,
               COALESCE(
                 CASE WHEN json_valid(rt.value_json)
                   THEN CAST(json_extract(rt.value_json, '$') AS REAL) END,
                 e.runtime
               ) AS catalog_runtime,
               \(stableRandomOrderExpression("g.series_key")) AS catalog_random,
               g.title AS catalog_display_title,
               'series:' || g.series_key AS catalog_stable_id
        FROM grouped g
        LEFT JOIN enrichment e ON e.item_id = 'series:' || g.series_key
        LEFT JOIN metadata_values sv
          ON sv.item_id = 'series:' || g.series_key AND sv.field = 'sortTitle' AND sv.source = 'localNFO'
        LEFT JOIN metadata_values pd
          ON pd.item_id = 'series:' || g.series_key AND pd.field = 'premiereDate' AND pd.source = 'localNFO'
        LEFT JOIN metadata_values py
          ON py.item_id = 'series:' || g.series_key AND py.field = 'productionYear' AND py.source = 'localNFO'
        LEFT JOIN metadata_values cr
          ON cr.item_id = 'series:' || g.series_key AND cr.field = 'ratings' AND cr.source = 'localNFO'
        LEFT JOIN metadata_values rt
          ON rt.item_id = 'series:' || g.series_key AND rt.field = 'runtime' AND rt.source = 'localNFO'
        ORDER BY \(order)
        LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit)); sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let key = self.columnText(stmt, 0) else { return }
            var item = ShareCatalogReadProjection.seriesItem(key: key, title: self.columnText(stmt, 1) ?? key, library: library, year: self.columnOptInt(stmt, 2))
            item.librarySortValues = LibrarySortValues(
                sortName: self.columnText(stmt, 13),
                dateAdded: sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))
            )
            rows.append((
                item,
                ShareCatalogID.series(key),
                ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 4)
            ))
        }
        let records = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.record.map { (row.enrichmentID, $0) }
        })
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(rows.map { row in
            hydrated[row.enrichmentID].map { ShareCatalogReadProjection.applyEnrichment(row.item, $0) } ?? row.item
        })
    }

    /// SQL order shared by movie and series grid queries. Unknown values always
    /// sink, independent of direction, and every order ends with deterministic
    /// name/id tie-breakers so LIMIT/OFFSET cannot duplicate or skip rows.
    private func catalogOrderClause(sort: CoreModels.SortDescriptor) -> String { // l10n:content - SQL syntax
        let direction = sort.direction == .ascending ? "ASC" : "DESC"
        switch sort.field {
        case .name:
            return "catalog_sort_name IS NULL, catalog_sort_name \(direction), catalog_display_title \(direction), catalog_stable_id ASC"
        case .dateAdded:
            return "catalog_date_added IS NULL, catalog_date_added \(direction), catalog_sort_name ASC, catalog_stable_id ASC"
        case .releaseDate:
            return "catalog_release_date IS NULL, catalog_release_date \(direction), catalog_sort_name ASC, catalog_stable_id ASC"
        case .communityRating:
            return "catalog_community_rating IS NULL, catalog_community_rating \(direction), catalog_sort_name ASC, catalog_stable_id ASC"
        case .runtime:
            return "catalog_runtime IS NULL, catalog_runtime \(direction), catalog_sort_name ASC, catalog_stable_id ASC"
        case .random:
            return "catalog_random \(direction), catalog_stable_id ASC"
        case .year, .criticRating, .userRating, .contentRating, .progress, .plays, .lastPlayed:
            // These are ordered from compact query facts, not this SQL page path.
            return "catalog_sort_name ASC, catalog_stable_id ASC"
        }
    }

    func libraryQueryFacets(in library: CatalogLibrary) -> LibraryQueryFacets {
        var genres = Set<String>()
        var years = Set<Int>()
        let includesLocal = normalizedMetadataReady && hasAnyLocalMetadata()
        let localColumns: [(MetadataField, Int32, Int32)] = [(.productionYear, 2, 3), (.genres, 4, 5)]
        query("""
        WITH catalog_items AS (
          SELECT 'f:' || MIN(rel_path) AS item_id, MAX(year) AS year
          FROM assets WHERE library=? AND library='movies' AND kind='movie'
          GROUP BY COALESCE(movie_group_key, movie_key, rel_path)
          UNION ALL
          SELECT 'series:' || series_key, MAX(year)
          FROM assets WHERE library=? AND library!='movies' AND kind='episode' AND series_key IS NOT NULL
          GROUP BY series_key
        )
        SELECT DISTINCT c.year, e.genres_json, yn.value_json, yf.value_json, gn.value_json, gf.value_json
        FROM catalog_items c
        LEFT JOIN enrichment e ON e.item_id=c.item_id
        LEFT JOIN metadata_values yn
          ON yn.item_id=c.item_id AND yn.field='productionYear' AND yn.source='localNFO'
        LEFT JOIN metadata_values yf
          ON yf.item_id=c.item_id AND yf.field='productionYear' AND yf.source='filename'
        LEFT JOIN metadata_values gn
          ON gn.item_id=c.item_id AND gn.field='genres' AND gn.source='localNFO'
        LEFT JOIN metadata_values gf
          ON gf.item_id=c.item_id AND gf.field='genres' AND gf.source='filename';
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            self.bindText($0, 2, library.rawValue)
        }) { stmt in
            var item = MediaItem(
                id: "", title: "", kind: library == .movies ? .movie : .series,
                productionYear: self.columnOptInt(stmt, 0),
                genres: CatalogJSON.decode([String].self, self.columnText(stmt, 1)) ?? []
            )
            if includesLocal {
                var fields: [MetadataField: ShareCatalogReadProjection.LocalFieldRow] = [:]
                for (field, nfoColumn, filenameColumn) in localColumns {
                    if let json = self.columnText(stmt, nfoColumn) {
                        fields[field] = .init(source: .localNFO, valueJSON: json)
                    } else if let json = self.columnText(stmt, filenameColumn) {
                        fields[field] = .init(source: .filename, valueJSON: json)
                    }
                }
                item = ShareCatalogReadProjection.applyLocalMetadata(item, fields)
            }
            if let year = item.productionYear { years.insert(year) }
            genres.formUnion(item.genres)
        }
        return LibraryQueryFacets(genres: Array(genres), years: Array(years))
    }

    func libraryQueryEpisodes(in library: CatalogLibrary, offset: Int, limit: Int) -> MediaPage {
        var total = 0
        query("SELECT COUNT(*) FROM assets WHERE library=? AND kind='episode';",
              bind: { self.bindText($0, 1, library.rawValue) }) { total = Int(sqlite3_column_int64($0, 0)) }
        var items: [MediaItem] = []
        query("""
        SELECT rel_path, title, kind, library, year, series_title, series_key, season, episode
        FROM assets WHERE library=? AND kind='episode'
        ORDER BY series_key, season, episode, rel_path LIMIT ? OFFSET ?;
        """, bind: {
            self.bindText($0, 1, library.rawValue)
            sqlite3_bind_int64($0, 2, Int64(limit))
            sqlite3_bind_int64($0, 3, Int64(offset))
        }) { stmt in
            guard let seriesKey = self.columnText(stmt, 6) else { return }
            items.append(ShareCatalogReadProjection.episodeItem(from: stmt, seriesKey: seriesKey))
        }
        return MediaPage(items: withEnrichment(items), startIndex: offset, totalCount: total)
    }

    /// Deterministic local shuffle key. SQLite's `random()` would reorder between
    /// page requests and make LIMIT/OFFSET skip or duplicate cards.
    private func stableRandomOrderExpression(_ id: String) -> String { // l10n:content - SQL syntax
        """
        printf(
          '%016x',
          abs(
            length(\(id)) * 1103515245
            + COALESCE(unicode(substr(\(id), -1, 1)), 0) * 12345
            + COALESCE(unicode(substr(\(id), (length(\(id)) + 1) / 2, 1)), 0) * 2654435761
          )
        )
        """
    }

    /// Exact number of movies in the Movies library, for the grid's `totalCount`
    /// so it can size its sparse backing store once and random-access any page
    /// (jump-to-bottom). Counts DISTINCT logical movies (grouped by `movie_key`,
    /// falling back to `rel_path` for un-keyed rows) to match `movies()`.
    func movieCount() -> Int {
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT COALESCE(movie_group_key, movie_key, rel_path)) FROM assets WHERE library='movies' AND kind='movie';", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Exact number of distinct series in a TV/Anime library, for the grid's
    /// `totalCount`. Zero for the movies library (which has no series).
    func seriesCount(in library: CatalogLibrary) -> Int {
        library == .movies ? 0 : distinctSeriesCount(library: library)
    }

    /// Every episode file in a series, addressed for watch-state lookup and
    /// grouped by season and *logical* episode.
    ///
    /// Season containers are synthetic — built by grouping the assets table — so
    /// they carry no watch state of their own. Rolling their episodes' state up
    /// needs one pass over the series rather than a query per season, which for a
    /// 20-season show would be 20 round trips to answer one question.
    ///
    /// The logical key matters because one episode can exist as several files
    /// (a 1080p and a 4K rip). `canonicalItemID` folds *movie* versions together
    /// but deliberately leaves episode files with their own ids, so counting raw
    /// files would report "12 of 20 watched" for a 10-episode season. Files that
    /// share a season+episode number are one logical episode; a file with no
    /// episode number can't be grouped, so it stands alone under its own path.
    func episodeWatchIdentities(seriesKey: String) -> [(season: Int, logicalKey: String, fileID: String)] {
        guard db != nil else { return [] }
        var out: [(season: Int, logicalKey: String, fileID: String)] = []
        query("""
        SELECT COALESCE(season, 1) AS s, episode, rel_path FROM assets
        WHERE series_key=? AND kind='episode';
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            let season = Int(sqlite3_column_int64(stmt, 0))
            let episode: Int? = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int64(stmt, 1))
            guard let rel = self.columnText(stmt, 2) else { return }
            let logicalKey = episode.map(String.init) ?? "path:\(rel)"
            out.append((season: season, logicalKey: logicalKey, fileID: ShareCatalogID.file(rel)))
        }
        return out
    }

    /// Season container items for a series (distinct season numbers; a `NULL`
    /// season is treated as season 1).
    func seasons(seriesKey: String) -> [MediaItem] {
        guard db != nil else { return [] }
        var seriesTitle = seriesKey
        var library: CatalogLibrary = .tv
        var seasons: [Int] = []
        query("""
        SELECT COALESCE(season,1) AS s,
               MIN(series_title) AS canonical_title,
               MAX(CASE WHEN library='anime' THEN 1 ELSE 0 END) AS has_anime
        FROM assets
        WHERE series_key=? AND kind='episode'
        GROUP BY COALESCE(season,1)
        ORDER BY s;
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            seasons.append(Int(sqlite3_column_int64(stmt, 0)))
            if let t = self.columnText(stmt, 1) { seriesTitle = t }
            if sqlite3_column_int64(stmt, 2) != 0 { library = .anime }
        }
        return withEnrichment(seasons.map { n in
            MediaItem(
                id: ShareCatalogID.season(seriesKey, n),
                title: "Season \(n)",
                kind: .season,
                parentTitle: seriesTitle,
                seasonNumber: n,
                seriesID: ShareCatalogID.series(seriesKey),
                libraryID: ShareCatalogID.library(library)
            )
        })
    }

    /// On-disk episode-title fingerprints for content-based series disambiguation.
    /// EXCLUDES the synthetic `S<n>·E<nn>` placeholder titles that bare-numbered
    /// files get (they carry no real title) — otherwise a show whose early seasons
    /// are bare-numbered (Outlander) would send only useless placeholders and match
    /// nothing, falling through to a wrong same-named show. Real titles from any
    /// season are used instead.
    func episodeTitleHints(seriesKey: String, limit: Int = 12) -> [(season: Int, episode: Int, title: String)] {
        guard db != nil, limit > 0 else { return [] }
        var out: [(season: Int, episode: Int, title: String)] = []
        query("""
        SELECT COALESCE(season,1) AS s, episode, title FROM assets
        WHERE series_key=? AND kind='episode' AND episode IS NOT NULL
          AND title IS NOT NULL AND title <> ''
          AND title NOT LIKE 'S%·E%'
        ORDER BY s, episode
        LIMIT ?;
        """, bind: {
            self.bindText($0, 1, seriesKey)
            sqlite3_bind_int64($0, 2, Int64(limit))
        }) { stmt in
            let s = Int(sqlite3_column_int64(stmt, 0))
            let e = Int(sqlite3_column_int64(stmt, 1))
            guard let t = self.columnText(stmt, 2) else { return }
            out.append((season: s, episode: e, title: t))
        }
        return out
    }

    /// Distinct FILENAME-derived series titles for a series that differ from its
    /// stored (folder-derived) title — extra TVDB search candidates for a show
    /// whose folder is generic. A generic "Avatar (2024)" folder stores title
    /// "Avatar", but the files say "Avatar The Last Airbender"; offering that as a
    /// search alternate lets enrichment find the right series. Returns candidates
    /// longest-first (most specific), capped, excluding the stored title.
    func seriesSearchTitleAlternates(seriesKey: String, storedTitle: String, sampleLimit: Int = 24) -> [String] {
        guard db != nil, sampleLimit > 0 else { return [] }
        var relPaths: [String] = []
        query("""
        SELECT rel_path FROM assets
        WHERE series_key=? AND kind='episode' AND rel_path IS NOT NULL AND rel_path <> ''
        ORDER BY COALESCE(season,1), COALESCE(episode, 999999)
        LIMIT ?;
        """, bind: {
            self.bindText($0, 1, seriesKey)
            sqlite3_bind_int64($0, 2, Int64(sampleLimit))
        }) { stmt in
            if let p = self.columnText(stmt, 0) { relPaths.append(p) }
        }
        let storedNorm = storedTitle.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        // Only a RICHER filename title is a useful alternate: it must have more words
        // than the stored folder title ("Avatar" → "Avatar The Last Airbender"). A
        // shorter filename abbreviation ("TP" for a "The Punisher" folder) must NOT
        // be searched — it fuzzy-matches unrelated shows ("The Syd + TP Show").
        let storedWordCount = storedNorm.split(separator: " ").count
        var seen = Set<String>()
        var alternates: [String] = []
        for path in relPaths {
            guard let title = ShareMediaParser.filenameSeriesTitle(relPath: path) else { continue }
            let norm = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
            guard !norm.isEmpty, norm != storedNorm, seen.insert(norm).inserted,
                  norm.split(separator: " ").count > storedWordCount else { continue }
            alternates.append(title)
        }
        // Most specific first: a longer filename title ("Avatar The Last
        // Airbender") is a stronger search than a short one.
        return alternates.sorted { $0.count > $1.count }
    }

    /// The explicit TheTVDB id a series' folder/filenames declared via a
    /// `[tvdb-####]` tag, or nil. Read from a sample rel_path — the enricher uses it
    /// to resolve metadata authoritatively by id instead of an ambiguous title search.
    func seriesEmbeddedTVDBID(seriesKey: String) -> String? {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        guard db != nil else { return nil }
        var relPath: String?
        query("""
        SELECT rel_path FROM assets
        WHERE series_key=? AND kind='episode' AND rel_path IS NOT NULL AND rel_path <> ''
        LIMIT 1;
        """, bind: { self.bindText($0, 1, seriesKey) }) { stmt in
            relPath = self.columnText(stmt, 0)
        }
        guard let relPath, let tag = ShareMediaParser.embeddedProviderTag(relPath: relPath),
              tag.hasPrefix("tvdb-") else { return nil }
        let id = String(tag.dropFirst("tvdb-".count))
        return id.isEmpty ? nil : id
    }

    func episodes(seriesKey: String, season: Int) -> [MediaItem] {
        guard db != nil else { return [] }
        var out: [MediaItem] = []
        query("""
        SELECT rel_path, title, series_title, season, episode, library, year FROM assets
        WHERE series_key=? AND kind='episode' AND COALESCE(season,1)=?
        ORDER BY COALESCE(episode, 999999), sort_title, rel_path;
        """, bind: { self.bindText($0, 1, seriesKey); sqlite3_bind_int64($0, 2, Int64(season)) }) { stmt in
            out.append(ShareCatalogReadProjection.episodeItem(from: stmt, seriesKey: seriesKey))
        }
        return withEnrichment(out)
    }

    /// Resolve any catalog id to a rich `MediaItem`, or `nil` if unknown here
    /// (caller falls back to the raw browser for `share:root` / `d:` ids).
    /// Items whose persisted cast includes `personID` or `name`, newest first.
    ///
    /// A share has only files, so its cast is resolved externally at scan time and
    /// stored as JSON on the enrichment row — there is no person table and nothing
    /// to join against. Matching therefore happens in two steps: SQL narrows by
    /// substring, which the index cannot help with but which is cheap enough
    /// against one text column, and the survivors are decoded and checked
    /// properly. The decode is what makes it correct — a raw `LIKE` would match
    /// "Chris Evans" inside "Chris Evanson", and a person id inside a longer id.
    ///
    /// Both keys are accepted because a share's `MediaPerson.id` is a TMDb id
    /// (`tmdb:person:1892`) while another server's is its own, so a person opened
    /// from Jellyfin or Plex can only be found here by name.
    /// A `LIKE` "contains" pattern for `value`, or one that can never match when
    /// there is nothing to look for.
    ///
    /// Both halves matter. An absent key must not degrade to `%%`, which matches
    /// every row and would send the whole catalog through JSON decoding — the
    /// id-only lookup passes no name, so that is the ordinary case, not an edge
    /// one. And `%` or `_` inside a name are `LIKE` wildcards: "Jean_Luc" would
    /// widen the prefilter rather than narrow it, so they are escaped. Neither
    /// affects correctness — every candidate is decoded and verified — but both
    /// decide how much work the verification is handed.
    private static func containsPattern(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return Self.neverMatchesPattern }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// A `LIKE` pattern on the longest stretch of `name` that survives diacritic
    /// folding unchanged, so an accented spelling can still be reached.
    ///
    /// "Penelope Cruz" folds to a stored "Penélope Cruz" only at the decode step;
    /// this gets that row *to* the decode by matching on "lope Cruz" — the longest
    /// run whose characters are identical either way. Deliberately loose: it only
    /// widens the candidate set, and every candidate is verified properly.
    private static func asciiFoldedProbe(_ name: String) -> String {
        guard !name.isEmpty else { return Self.neverMatchesPattern }
        var best = ""
        var current = ""
        for character in name {
            let folded = String(character).folding(
                options: .diacriticInsensitive, locale: nil
            )
            if folded == String(character) {
                current.append(character)
                if current.count > best.count { best = current }
            } else {
                current = ""
            }
        }
        let trimmed = best.trimmingCharacters(in: .whitespaces)
        // Too short a run matches most of the catalog and buys nothing.
        guard trimmed.count >= 4 else { return Self.neverMatchesPattern }
        return Self.containsPattern(trimmed)
    }

    /// No stored cast JSON can contain a NUL, so this matches nothing.
    private static let neverMatchesPattern = "\u{0}"

    func itemsWithPerson(id personID: String?, name: String, limit: Int) -> [MediaItem] {
        guard db != nil, limit > 0, castColumn == "cast_json" else { return [] }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || personID?.isEmpty == false else { return [] }

        var matches: [String] = []
        // Ordered by discovery so the newest work leads, matching Recently Added.
        query("""
        SELECT item_id, cast_json FROM enrichment
        WHERE cast_json IS NOT NULL
          AND (cast_json LIKE ?1 ESCAPE '\\' OR cast_json LIKE ?2 ESCAPE '\\'
               OR cast_json LIKE ?3 ESCAPE '\\')
        ORDER BY enriched_at DESC;
        """, bind: { stmt in
            self.bindText(stmt, 1, Self.containsPattern(trimmedName))
            self.bindText(stmt, 2, Self.containsPattern(personID))
            // SQLite's LIKE is not Unicode-aware, but the verification below folds
            // diacritics — so "Penelope Cruz" would never even look at a row
            // storing "Penélope Cruz". Widening on the longest accent-free run
            // gets such a row into the candidate set; the decode still decides.
            self.bindText(stmt, 3, Self.asciiFoldedProbe(trimmedName))
        }) { stmt in
            guard matches.count < limit,
                  let itemID = self.columnText(stmt, 0),
                  let json = self.columnText(stmt, 1),
                  let people = CatalogJSON.decode([MediaPerson].self, json)
            else { return }
            let hit = people.contains { person in
                if let personID, !personID.isEmpty, person.id == personID { return true }
                return !trimmedName.isEmpty
                    && person.name.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            if hit { matches.append(itemID) }
        }
        return matches.compactMap { item(id: $0) }
    }

    func item(id: String) -> MediaItem? {
        guard var item = browseItems(ids: [id])[id] else { return nil }
        item.fileBrowserContainerID = fileBrowserContainerID(for: item.id)
        return item
    }

    /// Resolve only when opening details, never once per card on the browse path.
    /// Lexical endpoints give the common physical directory of all versions.
    private func fileBrowserContainerID(for id: String) -> String? { // l10n:content - SQL and share-relative navigation IDs
        let parent = "substr(rel_path,1,length(rel_path)-length(basename)-1)"
        let directory: String
        let predicate: String
        let key: String
        var season: Int?
        if let movieKey = ShareCatalogID.movieKey(forMovieID: id) {
            directory = parent
            predicate = "COALESCE(movie_group_key,movie_key)=? AND kind='movie'"
            key = movieKey
        } else if let seriesKey = ShareCatalogID.seriesKey(forSeriesID: id) {
            directory = "COALESCE(metadata_root,\(parent))"
            predicate = "series_key=? AND kind='episode'"
            key = seriesKey
        } else if let components = ShareCatalogID.seasonComponents(forSeasonID: id) {
            directory = parent
            predicate = "series_key=? AND kind='episode' AND COALESCE(season,1)=?"
            key = components.seriesKey
            season = components.season
        } else if let path = ShareCatalogID.relPath(forFileID: id) {
            directory = parent
            predicate = "rel_path=?"
            key = path
        } else {
            return nil
        }
        var folder: String?
        query("""
        SELECT MIN(\(directory)),MAX(\(directory))
        FROM assets WHERE \(predicate);
        """, bind: { stmt in
            self.bindText(stmt, 1, key)
            if let season { sqlite3_bind_int64(stmt, 2, Int64(season)) }
        }) { stmt in
            guard let first = self.columnText(stmt, 0),
                  let last = self.columnText(stmt, 1) else { return }
            folder = zip(first.split(separator: "/"), last.split(separator: "/"))
                .prefix { $0.0 == $0.1 }
                .map { String($0.0) }
                .joined(separator: "/")
        }
        return folder.map {
            ShareCatalogID.fileBrowserID(for: $0.isEmpty ? "share:root" : "d:\($0)")
        }
    }

    /// Resolve and hydrate catalog ids in bounded batches.
    ///
    /// The returned dictionary is keyed by the requested id, even when a legacy
    /// alias resolves to a canonical logical movie whose `MediaItem.id` differs.
    /// Duplicate inputs are hydrated once; unknown ids are omitted.
    func browseItems(ids: [String]) -> [String: MediaItem] {
        guard db != nil, !ids.isEmpty else { return [:] }

        var seen = Set<String>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        var movieKeysByRequest: [String: String] = [:]
        var seriesKeysByRequest: [String: String] = [:]
        var seasonsByRequest: [String: (seriesKey: String, season: Int)] = [:]
        var filePathsByRequest: [String: String] = [:]

        for id in uniqueIDs {
            if let key = ShareCatalogID.movieKey(forMovieID: id) {
                movieKeysByRequest[id] = key
            } else if let key = ShareCatalogID.seriesKey(forSeriesID: id) {
                seriesKeysByRequest[id] = key
            } else if let components = ShareCatalogID.seasonComponents(forSeasonID: id) {
                seasonsByRequest[id] = components
            } else if let relPath = ShareCatalogID.relPath(forFileID: id) {
                filePathsByRequest[id] = relPath
            }
        }

        let resolvedGroupsByKey = resolvedMovieGroupKeys(
            Array(Set(movieKeysByRequest.values))
        )
        let directFilesByPath = baseFileItems(
            relPaths: Array(Set(filePathsByRequest.values))
        )
        let missingFileIDs = filePathsByRequest.compactMap { requestID, relPath in
            directFilesByPath[relPath] == nil ? requestID : nil
        }
        let aliasGroupsByID = movieAliasGroups(for: missingFileIDs)
        let resolvedAliasGroups = resolvedMovieGroupKeys(
            Array(Set(aliasGroupsByID.values))
        )
        let canonicalAliasGroupsByID = aliasGroupsByID.mapValues {
            resolvedAliasGroups[$0] ?? $0
        }

        let requiredGroups = Set(resolvedGroupsByKey.values)
            .union(canonicalAliasGroupsByID.values)
        let groupedMovies = baseMovieItems(groupKeys: Array(requiredGroups))
        let seriesItems = baseSeriesItems(
            keys: Array(Set(seriesKeysByRequest.values))
        )
        let seasonItems = baseSeasonItems(
            requests: Array(seasonsByRequest.values)
        )

        var baseByRequest: [String: MediaItem] = [:]
        var movieRepresentativeIDs: [String: String] = [:]

        for (requestID, key) in movieKeysByRequest {
            guard let group = resolvedGroupsByKey[key],
                  let base = groupedMovies[group] else { continue }
            baseByRequest[requestID] = base.item
            movieRepresentativeIDs[base.item.id] = base.representativeID
        }
        for (requestID, key) in seriesKeysByRequest {
            if let item = seriesItems[key] { baseByRequest[requestID] = item }
        }
        for (requestID, components) in seasonsByRequest {
            let canonicalID = ShareCatalogID.season(
                components.seriesKey,
                components.season
            )
            if let item = seasonItems[canonicalID] {
                baseByRequest[requestID] = item
            }
        }
        for (requestID, relPath) in filePathsByRequest {
            if let item = directFilesByPath[relPath] {
                baseByRequest[requestID] = item
            } else if let group = canonicalAliasGroupsByID[requestID],
                      let base = groupedMovies[group] {
                baseByRequest[requestID] = base.item
                movieRepresentativeIDs[base.item.id] = base.representativeID
            }
        }

        var uniqueBaseItems: [MediaItem] = []
        var baseItemIDs = Set<String>()
        for requestID in uniqueIDs {
            guard let item = baseByRequest[requestID],
                  baseItemIDs.insert(item.id).inserted else { continue }
            uniqueBaseItems.append(item)
        }

        var hydratedByItemID: [String: MediaItem] = [:]
        forEachQueryBatch(uniqueBaseItems) { batch in
            for item in withEnrichment(
                Array(batch),
                movieRepresentativeIDs: movieRepresentativeIDs
            ) {
                hydratedByItemID[item.id] = item
            }
        }

        return baseByRequest.reduce(into: [:]) { result, entry in
            if let hydrated = hydratedByItemID[entry.value.id] {
                result[entry.key] = hydrated
            }
        }
    }

    // MARK: - Item builders

    private struct GroupedMovieBase {
        var item: MediaItem
        var representativeID: String
    }

    private struct MovieFileRow {
        var relPath: String
        var basename: String
        var size: Int64
        var title: String // l10n:content - indexed movie title
        var year: Int?
    }

    private func resolvedMovieGroupKeys(_ keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        var resolved: [String: String] = [:]

        forEachQueryBatch(keys) { batch in
            let values = Array(repeating: "(?)", count: batch.count).joined(separator: ",")
            query("""
            WITH requested(key) AS (VALUES \(values))
            SELECT r.key, (
                SELECT COALESCE(a.movie_group_key, a.movie_key)
                FROM assets a
                WHERE a.movie_key=r.key
                LIMIT 1
            )
            FROM requested r;
            """, bind: { stmt in
                for (offset, key) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), key)
                }
            }) { stmt in
                guard let key = self.columnText(stmt, 0),
                      let group = self.columnText(stmt, 1) else { return }
                resolved[key] = group
            }
        }

        let unresolvedDirectGroups = keys.filter { resolved[$0] == nil }
        forEachQueryBatch(unresolvedDirectGroups) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT DISTINCT movie_group_key FROM assets
            WHERE library='movies' AND kind='movie'
              AND movie_group_key IN (\(placeholders));
            """, bind: { stmt in
                for (offset, key) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), key)
                }
            }) { stmt in
                guard let group = self.columnText(stmt, 0) else { return }
                resolved[group] = group
            }
        }

        let unresolvedAliases = keys.filter { resolved[$0] == nil }
        for (alias, group) in movieAliasGroups(for: unresolvedAliases) {
            resolved[alias] = group
        }
        return resolved
    }

    private func movieAliasGroups(for aliasIDs: [String]) -> [String: String] {
        guard !aliasIDs.isEmpty else { return [:] }
        var groups: [String: String] = [:]
        forEachQueryBatch(aliasIDs) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT alias_id, group_key FROM movie_alias
            WHERE alias_id IN (\(placeholders));
            """, bind: { stmt in
                for (offset, aliasID) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), aliasID)
                }
            }) { stmt in
                guard let aliasID = self.columnText(stmt, 0),
                      let group = self.columnText(stmt, 1) else { return }
                groups[aliasID] = group
            }
        }
        return groups
    }

    /// Build logical movies without decoration. All requested groups share the
    /// same bounded asset reads, then one bulk overlay pass decorates the result.
    private func baseMovieItems(groupKeys: [String]) -> [String: GroupedMovieBase] {
        guard !groupKeys.isEmpty else { return [:] }
        var filesByGroup: [String: [MovieFileRow]] = [:]

        forEachQueryBatch(groupKeys) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT COALESCE(movie_group_key, movie_key) AS resolved_group,
                   rel_path, basename, size, title, year
            FROM assets
            WHERE library='movies' AND kind='movie'
              AND COALESCE(movie_group_key, movie_key) IN (\(placeholders))
            ORDER BY resolved_group, rel_path;
            """, bind: { stmt in
                for (offset, group) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), group)
                }
            }) { stmt in
                guard let group = self.columnText(stmt, 0) else { return }
                let relPath = self.columnText(stmt, 1) ?? ""
                filesByGroup[group, default: []].append(MovieFileRow(
                    relPath: relPath,
                    basename: self.columnText(stmt, 2) ?? relPath,
                    size: sqlite3_column_int64(stmt, 3),
                    title: self.columnText(stmt, 4) ?? group,
                    year: self.columnOptInt(stmt, 5)
                ))
            }
        }

        return filesByGroup.reduce(into: [:]) { result, entry in
            let (group, files) = entry
            guard let representative = files.first else { return }
            var versions = files.map {
                Self.movieVersion(relPath: $0.relPath, basename: $0.basename, size: $0.size)
            }.sortedForPicker()
            if !versions.isEmpty { versions[0].isDefault = true }
            let year = files.compactMap(\.year).max()
            let item = MediaItem(
                id: ShareCatalogID.movie(group),
                title: representative.title,
                kind: .movie,
                productionYear: year,
                libraryID: ShareCatalogID.moviesLibrary,
                versions: versions
            )
            result[group] = GroupedMovieBase(
                item: item,
                representativeID: ShareCatalogID.file(representative.relPath)
            )
        }
    }

    private func baseSeriesItems(keys: [String]) -> [String: MediaItem] {
        guard !keys.isEmpty else { return [:] }
        var result: [String: MediaItem] = [:]

        forEachQueryBatch(keys) { batch in
            let values = Array(repeating: "(?)", count: batch.count).joined(separator: ",")
            query("""
            WITH requested(key) AS (VALUES \(values))
            SELECT r.key, a.series_title, a.library, (
                SELECT b.year FROM assets b
                WHERE b.series_key=r.key AND b.kind='episode' AND b.year IS NOT NULL
                GROUP BY b.year ORDER BY COUNT(*) DESC, b.year ASC LIMIT 1
            )
            FROM requested r
            LEFT JOIN assets a ON a.rowid = (
                SELECT candidate.rowid FROM assets candidate
                WHERE candidate.series_key=r.key AND candidate.kind='episode'
                LIMIT 1
            );
            """, bind: { stmt in
                for (offset, key) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), key)
                }
            }) { stmt in
                guard let key = self.columnText(stmt, 0),
                      let title = self.columnText(stmt, 1) else { return }
                let library = CatalogLibrary(
                    rawValue: self.columnText(stmt, 2) ?? "tv"
                ) ?? .tv
                result[key] = ShareCatalogReadProjection.seriesItem(
                    key: key,
                    title: title,
                    library: library,
                    year: self.columnOptInt(stmt, 3)
                )
            }
        }
        return result
    }

    private func baseSeasonItems(
        requests: [(seriesKey: String, season: Int)]
    ) -> [String: MediaItem] {
        guard !requests.isEmpty else { return [:] }
        let requestedBySeries = Dictionary(grouping: requests) { $0.seriesKey }
        var seriesRows: [String: (title: String, library: CatalogLibrary, seasons: Set<Int>)] = [:]

        forEachQueryBatch(Array(requestedBySeries.keys)) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT series_key, COALESCE(season,1) AS s,
                   MIN(series_title) AS canonical_title,
                   MAX(CASE WHEN library='anime' THEN 1 ELSE 0 END) AS has_anime
            FROM assets
            WHERE series_key IN (\(placeholders)) AND kind='episode'
            GROUP BY series_key, COALESCE(season,1)
            ORDER BY series_key, s;
            """, bind: { stmt in
                for (offset, key) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), key)
                }
            }) { stmt in
                guard let key = self.columnText(stmt, 0) else { return }
                var row = seriesRows[key] ?? (key, .tv, [])
                row.seasons.insert(Int(sqlite3_column_int64(stmt, 1)))
                if let title = self.columnText(stmt, 2) { row.title = title }
                if sqlite3_column_int64(stmt, 3) != 0 { row.library = .anime }
                seriesRows[key] = row
            }
        }

        var result: [String: MediaItem] = [:]
        for (key, requested) in requestedBySeries {
            guard let row = seriesRows[key] else { continue }
            for request in requested where row.seasons.contains(request.season) {
                let id = ShareCatalogID.season(key, request.season)
                result[id] = MediaItem(
                    id: id,
                    title: "Season \(request.season)",
                    kind: .season,
                    parentTitle: row.title,
                    seasonNumber: request.season,
                    seriesID: ShareCatalogID.series(key),
                    libraryID: ShareCatalogID.library(row.library)
                )
            }
        }
        return result
    }

    private func baseFileItems(relPaths: [String]) -> [String: MediaItem] {
        guard !relPaths.isEmpty else { return [:] }
        var result: [String: MediaItem] = [:]

        forEachQueryBatch(relPaths) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT rel_path, title, kind, library, year, series_title, series_key, season, episode,
                   basename, size
            FROM assets WHERE rel_path IN (\(placeholders));
            """, bind: { stmt in
                for (offset, relPath) in batch.enumerated() {
                    self.bindText(stmt, Int32(offset + 1), relPath)
                }
            }) { stmt in
                guard let relPath = self.columnText(stmt, 0) else { return }
                let kind = self.columnText(stmt, 2) ?? "movie"
                if kind == "episode" {
                    result[relPath] = ShareCatalogReadProjection.episodeItem(
                        from: stmt,
                        seriesKey: self.columnText(stmt, 6) ?? ""
                    )
                } else {
                    result[relPath] = MediaItem(
                        id: ShareCatalogID.file(relPath),
                        title: self.columnText(stmt, 1) ?? relPath,
                        kind: .movie,
                        productionYear: self.columnOptInt(stmt, 4),
                        libraryID: ShareCatalogID.moviesLibrary,
                        versions: [Self.movieVersion(
                            relPath: relPath,
                            basename: self.columnText(stmt, 9) ?? relPath,
                            size: sqlite3_column_int64(stmt, 10)
                        )]
                    )
                }
            }
        }
        return result
    }

    /// The best default file to play for a logical movie when the caller named no
    /// specific version (play-from-card, before the detail's version picker set
    /// one): the highest parsed resolution, then the largest file.
    func defaultMovieRelPath(forKey key: String) -> String? {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        guard db != nil else { return nil }
        let groupKey = resolvedMovieGroupKey(key)
        var best: (rel: String, height: Int, size: Int64)?
        query("""
        SELECT rel_path, basename, size FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=?
          AND library='movies' AND kind='movie';
        """,
              bind: { self.bindText($0, 1, groupKey) }) { stmt in
            let rel = self.columnText(stmt, 0) ?? ""
            let h = Self.resolutionHeight(fromName: self.columnText(stmt, 1) ?? "") ?? 0
            let sz = sqlite3_column_int64(stmt, 2)
            if best == nil || h > best!.height || (h == best!.height && sz > best!.size) {
                best = (rel, h, sz)
            }
        }
        return best?.rel
    }

    /// Canonical watch-state id for a leaf id: a movie file (`f:<rel>`) folds into
    /// its logical `movie:<key>` so resume/played is unified across versions; an
    /// episode file or an un-keyed movie keeps its own id.
    func canonicalItemID(_ id: String) -> String {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        guard db != nil else { return id }
        if let key = ShareCatalogID.movieKey(forMovieID: id) {
            return ShareCatalogID.movie(resolvedMovieGroupKey(key))
        }
        guard let rel = ShareCatalogID.relPath(forFileID: id) else { return id }
        var key: String?
        query("SELECT COALESCE(movie_group_key, movie_key) FROM assets WHERE rel_path=? AND kind='movie';",
              bind: { self.bindText($0, 1, rel) }) { stmt in key = self.columnText(stmt, 0) }
        if let key { return ShareCatalogID.movie(key) }
        if let group = movieAliasGroup(for: id) { return ShareCatalogID.movie(group) }
        return id
    }

    /// Stored watch-state ids relevant to the requested current items, mapped to
    /// their canonical ids. Normal grid/detail/search stamping uses this bounded
    /// alias set instead of canonicalizing the entire watch history.
    func watchStateAliases(for itemIDs: [String]) -> [String: String] {
        guard db != nil, !itemIDs.isEmpty else { return [:] }

        var aliases: [String: String] = [:]
        var canonicalByGroup: [String: String] = [:]
        for id in itemIDs {
            let canonical = canonicalItemID(id)
            aliases[id] = canonical
            aliases[canonical] = canonical
            if let group = ShareCatalogID.movieKey(forMovieID: canonical) {
                canonicalByGroup[group] = canonical
            }
        }

        let groups = Array(canonicalByGroup.keys)
        guard !groups.isEmpty else { return aliases }
        let placeholders = Array(repeating: "?", count: groups.count).joined(separator: ",")
        query("SELECT alias_id, group_key FROM movie_alias WHERE group_key IN (\(placeholders));",
              bind: { stmt in
                  for (offset, group) in groups.enumerated() {
                      self.bindText(stmt, Int32(offset + 1), group)
                  }
              }) { stmt in
            guard let alias = self.columnText(stmt, 0),
                  let group = self.columnText(stmt, 1),
                  let canonical = canonicalByGroup[group] else { return }
            let storedID = alias.hasPrefix("f:") ? alias : ShareCatalogID.movie(alias)
            aliases[storedID] = canonical
        }
        return aliases
    }

    /// Whether a legacy/raw `f:` id still has a live catalog row. Playback uses
    /// this to preserve exact-file selection for existing files while routing a
    /// deleted legacy file alias to the surviving logical movie.
    func containsFileAsset(id: String) -> Bool {
        guard db != nil, let relPath = ShareCatalogID.relPath(forFileID: id) else { return false }
        var found = false
        query("SELECT 1 FROM assets WHERE rel_path=? LIMIT 1;",
              bind: { self.bindText($0, 1, relPath) }) { _ in found = true }
        return found
    }

    /// Resolve a pre-grouping `movie:<movie_key>` id to its persisted logical
    /// group. Keeps v3 Continue Watching records, deep links, and queued watch
    /// writes working after v4 combines adjacent-year variants.
    func resolvedMovieGroupKey(_ key: String) -> String {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        guard db != nil else { return key }
        var resolved: String?
        query("""
        SELECT COALESCE(movie_group_key, movie_key) FROM assets
        WHERE library='movies' AND kind='movie' AND movie_key=? LIMIT 1;
        """, bind: { self.bindText($0, 1, key) }) { stmt in
            resolved = self.columnText(stmt, 0)
        }
        if let resolved { return resolved }
        query("""
        SELECT movie_group_key FROM assets
        WHERE library='movies' AND kind='movie' AND movie_group_key=? LIMIT 1;
        """, bind: { self.bindText($0, 1, key) }) { stmt in
            resolved = self.columnText(stmt, 0)
        }
        if let resolved { return resolved }
        return movieAliasGroup(for: key) ?? key
    }

    private func movieAliasGroup(for aliasID: String) -> String? {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        var group: String?
        query("SELECT group_key FROM movie_alias WHERE alias_id=? LIMIT 1;",
              bind: { self.bindText($0, 1, aliasID) }) { stmt in
            group = self.columnText(stmt, 0)
        }
        return group
    }

    /// A share file → provider-agnostic ``MediaVersion``. The share has no server
    /// stream metadata, so the resolution is parsed from the filename and the
    /// basename is passed as `name` for the shared `EditionParser` to recover the
    /// edition (Director's Cut, …) and source quality (Remux/BluRay/WEB-DL). The
    /// version `id` is the file's rel-path, threaded back as the `mediaSourceID`.
    private static func movieVersion(relPath: String, basename: String, size: Int64) -> MediaVersion {
        MediaVersion(
            id: relPath,
            name: (basename as NSString).deletingPathExtension,
            height: resolutionHeight(fromName: basename),
            sizeBytes: size > 0 ? size : nil,
            videoRange: videoRange(fromName: basename),
            container: (basename as NSString).pathExtension.lowercased()
        )
    }

    /// Best-effort resolution height parsed from a filename token (`2160p`, `1080p`,
    /// `4K`, …). `nil` when the name states none.
    private static func resolutionHeight(fromName name: String) -> Int? {
        let l = name.lowercased()
        if l.contains("2160p") || l.contains("4k") || l.contains("uhd") { return 2160 }
        if l.contains("1440p") { return 1440 }
        if l.contains("1080p") || l.contains("1080i") { return 1080 }
        if l.contains("720p") { return 720 }
        if l.contains("576p") { return 576 }
        if l.contains("480p") { return 480 }
        return nil
    }

    /// Best-effort HDR range parsed from common release-name tokens. This makes
    /// SMB version rows distinguish a Dolby Vision file from its SDR sibling
    /// before the optional header probe has populated full stream metadata.
    private static func videoRange(fromName name: String) -> String? {
        let lower = name.lowercased()
        let compact = lower
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if compact.contains("dolbyvision") || tokens.contains("dovi") || tokens.contains("dv") {
            return HDRRange.dolbyVision.rawValue
        }
        if compact.contains("hdr10+") || compact.contains("hdr10plus") || compact.contains("hdr10") {
            return HDRRange.hdr10.rawValue
        }
        if compact.contains("hlg") { return HDRRange.hlg.rawValue }
        return nil
    }

    // MARK: - Enrichment read overlay

    /// The pending enrichment for a catalog id — the urgent fast-track path when a
    /// grid/detail opens an item. A logical movie enriches its REPRESENTATIVE file
    /// (where movies() reads art); a series enriches its `series:<key>` row.
    func pendingEnrichment(forItemID id: String, version: Int) -> PendingEnrichment? {
        guard db != nil else { return nil }

        // Logical movie → enrich its REPRESENTATIVE file (where movies() reads art),
        // so opening a movie fast-tracks the id the grid/detail actually display.
        if let mkey = ShareCatalogID.movieKey(forMovieID: id) {
            let groupKey = resolvedMovieGroupKey(mkey)
            var rep: String?
            query("""
            SELECT MIN(rel_path) FROM assets
            WHERE COALESCE(movie_group_key, movie_key)=?
              AND library='movies' AND kind='movie';
            """,
                  bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
            guard let rep else { return nil }
            return pendingEnrichment(forItemID: ShareCatalogID.file(rep), version: version)
        }

        // Series → the enrichment row is keyed by `series:<key>`.
        if ShareCatalogID.isSeries(id), let key = ShareCatalogID.seriesKey(forSeriesID: id) {
            let itemID = ShareCatalogID.series(key)
            if enrichmentRepo.hasUsableEnrichment(itemID: itemID, version: version) { return nil }
            var out: PendingEnrichment?
            query("""
            SELECT series_title, library, (
                SELECT b.year FROM assets b
                WHERE b.series_key = ?1 AND b.kind='episode' AND b.year IS NOT NULL
                GROUP BY b.year ORDER BY COUNT(*) DESC, b.year ASC LIMIT 1
            ), MIN(first_seen_at) FROM assets WHERE series_key=?1 AND kind='episode' LIMIT 1;
            """,
                  bind: { self.bindText($0, 1, key) }) { stmt in
                guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return }
                let lib = self.columnText(stmt, 1) ?? "tv"
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? key,
                    year: self.columnOptInt(stmt, 2),
                    isMovie: false, isAnime: lib == "anime",
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                )
            }
            return out
        }

        // Movie file → the enrichment row is keyed by `f:<relPath>`. Episodes enrich
        // through their series (above), so a bare episode file id is skipped here.
        if let relPath = ShareCatalogID.relPath(forFileID: id) {
            let itemID = ShareCatalogID.file(relPath)
            if enrichmentRepo.hasUsableEnrichment(itemID: itemID, version: version) { return nil }
            var out: PendingEnrichment?
            query("SELECT title, year, kind, first_seen_at FROM assets WHERE rel_path=?;",
                  bind: { self.bindText($0, 1, relPath) }) { stmt in
                guard (self.columnText(stmt, 2) ?? "movie") == "movie" else { return }
                out = PendingEnrichment(
                    itemID: itemID,
                    title: self.columnText(stmt, 0) ?? relPath,
                    year: self.columnOptInt(stmt, 1),
                    isMovie: true, isAnime: ShareScanner.isAnimePath(relPath),
                    discoveredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                )
            }
            return out
        }
        return nil
    }

    /// Load provenance for a page in one query. The flat row remains authoritative:
    /// malformed/stale normalized values are ignored and receive legacy attribution.
    private func hydratedEnrichmentRecords(
        _ records: [String: EnrichmentRecord]
    ) -> [String: EnrichmentRecord] {
        guard !records.isEmpty else { return [:] }
        guard normalizedMetadataReady else {
            return records.mapValues { record in
                var legacy = record
                legacy.inferLegacyProvenanceForMissingFields()
                return legacy
            }
        }
        var provenanceByItem: [String: MetadataProvenance] = [:]
        forEachQueryBatch(records.keys.sorted()) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = """
            SELECT item_id, field, source, value_json, source_url
            FROM metadata_values
            WHERE item_id IN (\(placeholders))
            ORDER BY item_id, field,
                     CASE WHEN source='legacyUnknown' THEN 1 ELSE 0 END,
                     COALESCE(refreshed_at, 0) DESC;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (offset, itemID) in batch.enumerated() {
                    bindText(stmt, Int32(offset + 1), itemID)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let itemID = columnText(stmt, 0),
                          let record = records[itemID],
                          let fieldRaw = columnText(stmt, 1),
                          let sourceRaw = columnText(stmt, 2),
                          !sourceRaw.isEmpty,
                          let valueJSON = columnText(stmt, 3) else { continue }
                    let field = MetadataField(rawValue: fieldRaw)
                    var provenance = provenanceByItem[itemID] ?? MetadataProvenance()
                    guard provenance[field] == nil,
                          ShareCatalogReadProjection.metadataValueMatches(
                              field: field,
                              valueJSON: valueJSON,
                              record: record
                          ) else { continue }
                    provenance[field] = MetadataAttribution(
                        source: MetadataSource(rawValue: sourceRaw),
                        sourceURL: columnText(stmt, 4).flatMap(URL.init(string:))
                    )
                    provenanceByItem[itemID] = provenance
                }
            }
            sqlite3_finalize(stmt)
        }

        return records.reduce(into: [:]) { result, entry in
            let (itemID, record) = entry
            var hydrated = record
            hydrated.provenance = provenanceByItem[itemID] ?? MetadataProvenance()
            hydrated.inferLegacyProvenanceForMissingFields()
            result[itemID] = hydrated
        }
    }

    /// Persisted enrichment for a catalog id (movie file id or `series:<key>`).
    func enrichmentRow(itemID: String) -> EnrichmentRecord? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT provider_ids_json, overview, genres_json, runtime, poster_url, backdrop_url, logo_url, title, \(castColumn)
        FROM enrichment WHERE item_id=?;
        """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, itemID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let record = ShareCatalogReadProjection.enrichmentRecord(fromColumns: stmt, startingAt: 0) else { return nil }
        return hydratedEnrichmentRecords([itemID: record])[itemID]
    }

    private func enrichmentKey(
        for item: MediaItem,
        movieRepresentativeIDs: [String: String]? = nil
    ) -> String? {
        switch item.kind {
        case .series:
            return item.id
        case .movie:
            // A grouped movie (`movie:<key>`) stores its enrichment under the
            // group's REPRESENTATIVE file id (`f:<MIN(rel_path)>`) — where the
            // per-file enrichment pass already wrote art/ids — so resolve to that.
            // A legacy un-grouped `f:` movie id is its own enrichment key.
            return movieRepresentativeIDs?[item.id] ?? movieEnrichmentKey(forID: item.id)
        case .season, .episode:
            return item.seriesID
        default:
            return nil
        }
    }

    private func withEnrichment(
        _ items: [MediaItem],
        movieRepresentativeIDs: [String: String]? = nil
    ) -> [MediaItem] {
        let keyed = items.map {
            ($0, enrichmentKey(for: $0, movieRepresentativeIDs: movieRepresentativeIDs))
        }
        let itemIDs = Array(Set(keyed.compactMap { $0.1 })).sorted()
        guard !itemIDs.isEmpty else { return withLocalOverlay(items) }
        var records: [String: EnrichmentRecord] = [:]
        forEachQueryBatch(itemIDs) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            SELECT item_id, provider_ids_json, overview, genres_json, runtime,
                   poster_url, backdrop_url, logo_url, title, \(castColumn)
            FROM enrichment WHERE item_id IN (\(placeholders));
            """, -1, &stmt, nil) == SQLITE_OK else { return }
            for (offset, itemID) in batch.enumerated() {
                bindText(stmt, Int32(offset + 1), itemID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let itemID = columnText(stmt, 0),
                      let record = ShareCatalogReadProjection.enrichmentRecord(
                          fromColumns: stmt,
                          startingAt: 1
                      ) else { continue }
                records[itemID] = record
            }
            sqlite3_finalize(stmt)
        }
        let hydrated = hydratedEnrichmentRecords(records)
        return withLocalOverlay(keyed.map { item, itemID in
            guard let itemID, let record = hydrated[itemID] else { return item }
            return ShareCatalogReadProjection.applyEnrichment(item, record)
        }, artworkKeys: movieRepresentativeIDs)
    }

    /// Overlays persisted LOCAL (`localNFO`/`filename`) metadata onto items —
    /// taking priority over any external/legacy value `applyEnrichment` already
    /// applied above (NFO wins over a conflicting filename/folder tag, which in
    /// turn wins over external — see the Step 3 source-priority table). Local
    /// candidates are looked up by the SAME logical key local writes use (see
    /// `ShareLocalMetadataEnricher`): a movie's group-representative file id, a
    /// series' `series:<key>` id, or an EPISODE'S OWN `f:<relPath>` id — an
    /// episode's local NFO is never superseded by its show's `tvshow.nfo` (which
    /// only ever targets the series-level id). `sourceURL` is always nil for
    /// these sources — the local-provenance-privacy invariant.
    /// - Parameter artworkKeys: optional `item.id → group-representative id` map a
    ///   caller has ALREADY resolved. For movies that mapping otherwise costs 1-2
    ///   SQLite round trips per card (`movieEnrichmentKey`), but the grid/search
    ///   queries compute the very same value as `rep_id` and used to discard it.
    ///   Passing it makes a page's overlay pure in-memory work.
    private func withLocalOverlay(
        _ items: [MediaItem],
        artworkKeys: [String: String]? = nil
    ) -> [MediaItem] {
        guard normalizedMetadataReady, hasAnyLocalMetadata() else {
            return withLocalArtwork(items, artworkKeys: artworkKeys)
        }
        let keyed = items.map { item in (item, localMetadataKey(for: item, precomputed: artworkKeys)) }
        let itemIDs = Array(Set(keyed.compactMap { $0.1 })).sorted()
        guard !itemIDs.isEmpty else { return withLocalArtwork(items, artworkKeys: artworkKeys) }
        let rows = localMetadataRows(itemIDs: itemIDs)
        guard !rows.isEmpty else { return withLocalArtwork(items, artworkKeys: artworkKeys) }
        return withLocalArtwork(keyed.map { item, key in
            guard let key, let fields = rows[key], !fields.isEmpty else { return item }
            return ShareCatalogReadProjection.applyLocalMetadata(item, fields)
        }, artworkKeys: artworkKeys)
    }

    private func withLocalArtwork(
        _ items: [MediaItem],
        artworkKeys: [String: String]? = nil
    ) -> [MediaItem] {
        guard normalizedMetadataReady, !items.isEmpty else { return items }
        // Resolve each item's artwork key ONCE. For a movie this is not a pure
        // function of the item — `localArtworkKey` runs 1-2 SQLite round trips to
        // map the card to its group's representative file — and it used to be
        // called a second time in the projection map below. That doubled the
        // lookups for every rendered card: measured on a 60-card page over a 15k
        // -file catalog, ~100ms each pass, i.e. the entire cost of the page.
        let keyed = items.map { (item: $0, key: localArtworkKey(for: $0, precomputed: artworkKeys)) }
        let keys = Array(Set(keyed.flatMap { entry -> [String] in
            var keys = entry.key.map { [$0] } ?? []
            if entry.item.kind == .episode, let seriesID = entry.item.seriesID {
                keys.append(seriesID)
            }
            return keys
        })).sorted()
        guard !keys.isEmpty else { return items }
        var selections: [String: [ArtworkSelection]] = [:]
        forEachQueryBatch(keys) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            query("""
            SELECT item_id,value_json FROM metadata_values
            WHERE source='localArtwork' AND field LIKE 'artwork.%' AND item_id IN (\(placeholders))
            ORDER BY item_id,field;
            """, bind: { statement in
                for (offset, key) in batch.enumerated() {
                    self.bindText(statement, Int32(offset + 1), key)
                }
            }) { statement in
                guard let itemID = self.columnText(statement, 0),
                      let json = self.columnText(statement, 1),
                      let selection = CatalogJSON.decode(ArtworkSelection.self, json) else { return }
                selections[itemID, default: []].append(selection)
            }
        }
        return keyed.map { item, key in
            var values = key.flatMap { selections[$0] } ?? []
            if item.kind == .episode,
               let seriesID = item.seriesID,
               let seriesPoster = selections[seriesID]?.first(where: { $0.placement == .poster }) {
                values.append(
                    ArtworkSelection(
                        placement: .seriesPoster,
                        references: seriesPoster.references
                    )
                )
            }
            return ShareCatalogReadProjection.applyLocalArtwork(
                item,
                values,
                metadataConfig: metadataConfig
            )
        }
    }

    private func localArtworkKey(
        for item: MediaItem,
        precomputed: [String: String]? = nil
    ) -> String? {
        guard item.kind == .movie else { return item.id }
        return precomputed?[item.id] ?? movieEnrichmentKey(forID: item.id)
    }

    /// Cheap, cached "does this catalog have ANY local metadata at all" check —
    /// see `LocalMetadataPresence`.
    private func hasAnyLocalMetadata() -> Bool {
        if let cached = localMetadataPresence.cached { return cached }
        guard db != nil else { return false }
        var found = false
        query("SELECT 1 FROM metadata_values WHERE source IN ('localNFO','filename') LIMIT 1;") { _ in found = true }
        localMetadataPresence.cached = found
        return found
    }

    private func localMetadataKey(
        for item: MediaItem,
        precomputed: [String: String]? = nil
    ) -> String? {
        switch item.kind {
        case .movie:
            // Same group-representative id as `localArtworkKey` — reuse a caller's
            // resolved value rather than paying the lookup again.
            return precomputed?[item.id] ?? movieEnrichmentKey(forID: item.id)
        case .series, .episode:
            return item.id
        case .season:
            return item.seriesID
        default:
            return nil
        }
    }

    private func localMetadataRows(itemIDs: [String]) -> [String: [MetadataField: ShareCatalogReadProjection.LocalFieldRow]] {
        guard !itemIDs.isEmpty, db != nil else { return [:] }
        var out: [String: [MetadataField: ShareCatalogReadProjection.LocalFieldRow]] = [:]
        forEachQueryBatch(itemIDs) { batch in
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            SELECT item_id, field, source, value_json FROM metadata_values
            WHERE item_id IN (\(placeholders)) AND source IN ('localNFO','filename')
            ORDER BY item_id, field, CASE WHEN source='localNFO' THEN 0 ELSE 1 END;
            """, -1, &stmt, nil) == SQLITE_OK else { return }
            for (offset, itemID) in batch.enumerated() {
                bindText(stmt, Int32(offset + 1), itemID)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let itemID = columnText(stmt, 0),
                      let fieldRaw = columnText(stmt, 1),
                      let sourceRaw = columnText(stmt, 2),
                      let valueJSON = columnText(stmt, 3) else { continue }
                let field = MetadataField(rawValue: fieldRaw)
                var perItem = out[itemID] ?? [:]
                guard perItem[field] == nil else { continue }
                perItem[field] = ShareCatalogReadProjection.LocalFieldRow(
                    source: MetadataSource(rawValue: sourceRaw),
                    valueJSON: valueJSON
                )
                out[itemID] = perItem
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    /// The enrichment row id for a movie item: the group's representative file id
    /// for a logical `movie:<key>`, else the id unchanged (a legacy `f:` movie).
    private func movieEnrichmentKey(forID id: String) -> String {  // l10n:content — SQL query text embedded in the function body, not user-facing prose
        guard let mkey = ShareCatalogID.movieKey(forMovieID: id) else { return id }
        let groupKey = resolvedMovieGroupKey(mkey)
        var rep: String?
        query("""
        SELECT 'f:' || MIN(rel_path) FROM assets
        WHERE COALESCE(movie_group_key, movie_key)=?
          AND library='movies' AND kind='movie';
        """,
              bind: { self.bindText($0, 1, groupKey) }) { stmt in rep = self.columnText(stmt, 0) }
        return rep ?? id
    }

    // MARK: - Assets-count query intents

    /// Per-source count of persisted provenance rows in `metadata_values`, keyed by
    /// ``MetadataSource`` (Step 6 diagnostics). One grouped scan — cheap relative to
    /// a full read — but callers should still invoke it **lazily / on demand** (and
    /// debounce) since `metadata_values` grows with the library. Empty on a fresh
    /// catalog. Internal (server/local) and external sources are both included; the
    /// caller decides what to surface.
    func metadataCountPerSource() -> [MetadataSource: Int] {
        guard db != nil else { return [:] }
        var result: [MetadataSource: Int] = [:]
        query("SELECT source, COUNT(*) FROM metadata_values GROUP BY source;") { stmt in
            guard let raw = self.columnText(stmt, 0) else { return }
            result[MetadataSource(rawValue: raw)] = Int(sqlite3_column_int64(stmt, 1))
        }
        return result
    }

    private func count(where clause: String?) -> Int {
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM assets" + (clause.map { " WHERE \($0)" } ?? "") + ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func distinctSeriesCount(library: CatalogLibrary) -> Int {
        guard db != nil else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT series_key) FROM assets WHERE library=? AND kind='episode' AND series_key IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, library.rawValue)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func forEachQueryBatch<Value>(
        _ values: [Value],
        _ body: (ArraySlice<Value>) -> Void
    ) {
        var start = values.startIndex
        while start < values.endIndex {
            let end = values.index(
                start,
                offsetBy: Self.browseHydrationBatchSize,
                limitedBy: values.endIndex
            ) ?? values.endIndex
            body(values[start..<end])
            start = end
        }
    }

    // MARK: - Small SQLite helpers
    //
    // Thin forwarders onto the actor-confined `CatalogConnection`, mirroring the
    // store's own primitive wrappers so the moved read-path bodies stay verbatim.

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        connection.query(sql, bind: bind, row: row)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        CatalogConnection.bindText(stmt, idx, value)
    }
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        CatalogConnection.columnText(stmt, idx)
    }
    private func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double {
        CatalogConnection.columnDouble(stmt, idx)
    }
    private func columnOptInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        CatalogConnection.columnOptInt(stmt, idx)
    }
}
